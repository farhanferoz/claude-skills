# Rust Security Patterns

## Framework Detection

| Indicator | Framework |
|-----------|-----------|
| `actix-web`, `HttpServer::new` | Actix-web |
| `axum`, `Router::new` | Axum |
| `rocket`, `#[get(...)]` | Rocket |
| `diesel`, `#[derive(Queryable)]` | Diesel (ORM) |
| `sqlx`, `sqlx::query!` | sqlx |
| `tokio::spawn`, `#[tokio::main]` | Tokio (async runtime) |

---

## `unsafe` Blocks

Rust's safety guarantees (no data races, no null/dangling derefs, no buffer overflows) only hold in safe code. Every `unsafe` block is a place those guarantees must be re-established manually.

### Flag These

```rust
// FLAG: Raw pointer dereference with attacker-influenced offset/length
unsafe {
    let ptr = buffer.as_ptr().add(user_offset); // no bounds check on user_offset
    let val = *ptr;
}

// FLAG: Transmute changing size or reinterpreting untrusted bytes
unsafe {
    let n: u32 = std::mem::transmute(untrusted_bytes); // size/alignment assumptions
}

// FLAG: slice::from_raw_parts with an attacker-controlled length
unsafe {
    let s = std::slice::from_raw_parts(ptr, user_supplied_len); // OOB read if len is wrong
}

// FLAG: unsafe impl Send/Sync on a type with interior mutability that isn't actually thread-safe
unsafe impl Send for MyCache {} // silences the compiler, doesn't fix the race
```

### Lower Risk (Still Verify)

```rust
// CHECK: unsafe used only for FFI struct layout, no untrusted data involved
#[repr(C)]
struct Point { x: f64, y: f64 }

// CHECK: get_unchecked with a length invariant proven earlier in the same function
if idx < v.len() {
    unsafe { v.get_unchecked(idx) } // bounds already checked
}
```

Every `unsafe` block should be treated as MEDIUM confidence by default; escalate to HIGH when the pointer arithmetic, length, or offset involved is derived from network input, file contents, or any other attacker-controlled source.

---

## Integer Overflow in Release Mode

Rust panics on integer overflow in **debug** builds but silently **wraps** in **release** builds unless the arithmetic is explicit about intent. Code that "worked in dev" can wrap in production.

### Flag These

```rust
// FLAG: Unchecked arithmetic on attacker-controlled sizes feeding an allocation
let buf_size = header.declared_len + PADDING; // overflow wraps to a small number in release
let mut buf = Vec::with_capacity(buf_size);     // under-allocates, later write overflows it

// FLAG: Subtraction that can underflow on user input
let remaining = total - user_requested; // panics in debug, wraps to huge usize in release
```

### Safe Patterns

```rust
// SAFE: Explicit checked/saturating/wrapping arithmetic states intent
let buf_size = header.declared_len.checked_add(PADDING)
    .ok_or(Error::Overflow)?;

let remaining = total.saturating_sub(user_requested);

// SAFE: overflow-checks = true in Cargo.toml [profile.release] forces panic-on-overflow
```

Check `Cargo.toml` for `[profile.release] overflow-checks = true` — if absent, plain `+`/`-`/`*` on attacker-influenced values feeding a length, capacity, or offset is worth flagging even without a specific known overflow, since the failure mode (silent wrap into a buffer size) is exploitable.

---

## Panic as Denial of Service

A single unhandled panic in a request handler thread can take down that worker (Actix/Axum typically recover per-request, but panics in `spawn`-ed tasks, mutex-holding code, or `main` can be worse).

### Flag These

```rust
// FLAG: unwrap()/expect() on attacker-controlled input
let id: u32 = req.query("id").unwrap().parse().unwrap(); // malformed input panics
let body: MyRequest = serde_json::from_slice(&bytes).expect("valid json");

// FLAG: Array/slice indexing with an attacker-supplied index
let item = items[user_index]; // panics on out-of-range index instead of returning an error

// FLAG: Panicking while holding a lock — poisons the mutex for all future callers
let mut guard = shared.lock().unwrap();
guard.process(user_input); // if this panics, the Mutex is now poisoned
```

### Safe Patterns

```rust
// SAFE: Fallible parsing surfaces as a normal error response
let id: u32 = req.query("id")
    .and_then(|s| s.parse().ok())
    .ok_or(Error::BadRequest)?;

// SAFE: get() instead of indexing
let item = items.get(user_index).ok_or(Error::NotFound)?;
```

`unwrap`/`expect`/`panic!` on any value derived from a request, file, or network read is a DoS candidate — the fix is almost always converting it to a `Result` and an early return.

---

## Dependency and Unsafe-Crate Risk

### Check Context

```toml
# CHECK: Cargo.toml dependencies with known unsafe-heavy internals or CVE history
# Run `cargo audit` against Cargo.lock and treat any RUSTSEC advisory as a finding

[dependencies]
some-abandoned-crate = "0.1"  # CHECK: last published years ago, unmaintained
```

```bash
# Grep for direct unsafe crate usage indicators
cargo audit                       # RUSTSEC advisories against locked versions
cargo geiger                      # counts unsafe usage per dependency
```

Flag: dependencies pulled from git branches/forks rather than crates.io (`{ git = "..." }`), unpinned versions (`*`), and crates whose changelog shows a recent unsafe-related CVE.

---

## FFI Security

### Flag These

```rust
// FLAG: extern "C" function trusting a raw pointer + length pair from a caller
// without validating them before use
#[no_mangle]
pub extern "C" fn process(ptr: *const u8, len: usize) {
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) }; // len fully trusted
    // ...
}

// FLAG: Passing a Rust String/Vec across FFI without transferring ownership correctly
// (double-free / use-after-free at the C boundary)
let s = CString::new(data).unwrap();
some_c_function(s.as_ptr()); // s dropped at end of scope while C may still hold the pointer

// FLAG: No validation of C string is NUL-terminated / not adversarially long before CStr::from_ptr
unsafe { CStr::from_ptr(c_str_ptr) } // undefined behavior if not actually NUL-terminated
```

### Safe Patterns

```rust
// SAFE: Validate length against a maximum before constructing a slice
#[no_mangle]
pub extern "C" fn process(ptr: *const u8, len: usize) -> i32 {
    if len > MAX_LEN { return -1; }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    0
}
```

FFI boundaries are where Rust's guarantees end — treat every pointer/length pair arriving from C (or handed to C) as untrusted input requiring explicit validation before any `unsafe` use.

---

## SQL Injection

### Safe Patterns (Do Not Flag)

```rust
// SAFE: sqlx compile-time checked query with bind parameters
sqlx::query!("SELECT * FROM users WHERE id = $1", user_id).fetch_one(&pool).await?;

// SAFE: Diesel query builder
users::table.filter(users::id.eq(user_id)).first(&mut conn)?;
```

### Flag These

```rust
// FLAG: format!/string concatenation building SQL text
let query = format!("SELECT * FROM users WHERE name = '{}'", user_input);
sqlx::query(&query).fetch_all(&pool).await?;

// FLAG: Diesel sql_query with interpolated input
diesel::sql_query(format!("SELECT * FROM users WHERE id = {}", id)).execute(&mut conn)?;
```

---

## Grep Patterns

```bash
# unsafe blocks
grep -rn "unsafe " --include="*.rs" | grep -v "_test.rs"

# unwrap/expect on request-derived values
grep -rn "\.unwrap()\|\.expect(" --include="*.rs" | grep -i "req\.\|request\.\|body\."

# transmute / raw pointer construction
grep -rn "mem::transmute\|from_raw_parts\|as_ptr()\.add(" --include="*.rs"

# SQL string building
grep -rn "format!.*SELECT\|format!.*INSERT\|sql_query(format!" --include="*.rs"

# extern "C" FFI entry points
grep -rn "extern \"C\" fn\|#\[no_mangle\]" --include="*.rs"

# Unchecked arithmetic near allocation/capacity
grep -rn "with_capacity(\|Vec::with_capacity" --include="*.rs"
```
