# Go Security Patterns

## Framework Detection

| Indicator | Framework |
|-----------|-----------|
| `net/http`, `http.HandleFunc` | Standard library |
| `github.com/gin-gonic/gin` | Gin |
| `github.com/labstack/echo` | Echo |
| `github.com/gorilla/mux` | Gorilla Mux |
| `database/sql`, `sql.Open` | database/sql (any driver) |
| `google.golang.org/grpc` | gRPC |

---

## Goroutines and Race Conditions

### Safe Patterns (Do Not Flag)

```go
// SAFE: Mutex-protected shared state
var mu sync.Mutex
func increment() {
    mu.Lock()
    defer mu.Unlock()
    counter++
}

// SAFE: Channel-based coordination
results := make(chan int, len(jobs))
for _, job := range jobs {
    go func(j Job) { results <- process(j) }(job)
}

// SAFE: sync/atomic for simple counters
atomic.AddInt64(&counter, 1)
```

### Flag These

```go
// FLAG: Unsynchronized shared map/slice access across goroutines
var cache = map[string]string{}
func handler(w http.ResponseWriter, r *http.Request) {
    go func() { cache[r.URL.Query().Get("k")] = r.URL.Query().Get("v") }() // data race
}

// FLAG: Loop variable capture in pre-Go 1.22 code
for _, user := range users {
    go func() { process(user) }() // captures shared 'user' variable, not a per-iteration copy
}

// FLAG: Goroutine leak from unbounded spawning on attacker-controlled input
func handler(w http.ResponseWriter, r *http.Request) {
    n, _ := strconv.Atoi(r.URL.Query().Get("n"))
    for i := 0; i < n; i++ {
        go doExpensiveWork() // DoS: no bound on attacker-supplied n
    }
}
```

Run `go build -race` / `go test -race` findings should be treated as HIGH confidence if the racing code touches attacker-influenced state.

---

## SQL Injection

### Safe Patterns (Do Not Flag)

```go
// SAFE: Placeholder parameters
db.Query("SELECT * FROM users WHERE id = ?", userID)
db.QueryRow("SELECT * FROM users WHERE name = $1", name) // pgx/lib/pq

// SAFE: sqlx / gorm with bound params
db.Get(&user, "SELECT * FROM users WHERE id=$1", id)
gormDB.Where("id = ?", id).First(&user)
```

### Flag These

```go
// FLAG: String concatenation/fmt.Sprintf building SQL
query := fmt.Sprintf("SELECT * FROM users WHERE name = '%s'", userInput)
db.Query(query)

// FLAG: String concat with +
db.Query("SELECT * FROM users WHERE id = " + userID)

// FLAG: Raw() / Exec() with interpolated string in GORM
gormDB.Raw(fmt.Sprintf("SELECT * FROM users WHERE id = %s", id)).Scan(&user)
```

---

## Path Traversal

### Safe Patterns (Do Not Flag)

```go
// SAFE: Cleaned and validated against a base directory
cleaned := filepath.Clean(userPath)
full := filepath.Join(baseDir, cleaned)
if !strings.HasPrefix(full, baseDir+string(os.PathSeparator)) {
    http.Error(w, "invalid path", http.StatusBadRequest)
    return
}
```

### Flag These

```go
// FLAG: User input joined into a path with no containment check
path := filepath.Join(baseDir, r.URL.Query().Get("file"))
os.Open(path) // "../../etc/passwd" possible

// FLAG: Direct os.Open/os.ReadFile of user input
os.Open(r.URL.Query().Get("path"))
ioutil.ReadFile(userControlledPath)
http.ServeFile(w, r, r.URL.Query().Get("file")) // bypasses ServeMux path cleaning
```

---

## `unsafe` Package

### Flag These

```go
// FLAG: unsafe.Pointer conversions on attacker-influenced sizes/offsets
p := unsafe.Pointer(uintptr(unsafe.Pointer(&buf[0])) + offset) // offset from user input

// FLAG: Reinterpreting bytes without bounds checking
type Header struct{ Len uint32 }
h := (*Header)(unsafe.Pointer(&data[0])) // no length check on data first

// CHECK: unsafe used purely for performance (e.g., []byte<->string zero-copy)
// with no attacker-controlled offsets is usually low risk; still flag for review
// if it crosses a trust boundary (parsing untrusted wire formats).
```

`unsafe` bypasses Go's memory safety guarantees entirely — any use that touches attacker-controlled offsets, lengths, or type punning of untrusted data should be treated as high severity.

---

## TLS Configuration

### Flag These

```go
// FLAG: Disabling certificate verification
tr := &http.Transport{
    TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
}
client := &http.Client{Transport: tr}

// FLAG: Allowing weak TLS versions
&tls.Config{MinVersion: tls.VersionTLS10}
&tls.Config{MinVersion: tls.VersionSSL30}

// FLAG: Custom VerifyPeerCertificate that always returns nil
&tls.Config{
    InsecureSkipVerify: true,
    VerifyPeerCertificate: func(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
        return nil // always trusts
    },
}
```

### Safe Patterns

```go
// SAFE: Default verification, modern minimum version
&tls.Config{MinVersion: tls.VersionTLS12}
```

`InsecureSkipVerify: true` gated behind a test-only build tag or a local-dev-only config flag is lower severity — check whether the flag is reachable in production.

---

## Error-Shadowing Auth Bypasses

### Flag These

```go
// FLAG: Shadowed err silently discards an auth failure
func authenticate(r *http.Request) bool {
    user, err := lookupUser(r)
    if token, err := validateToken(r); err == nil { // shadows outer err
        return true
    }
    return user != nil // outer err from lookupUser never checked
}

// FLAG: Ignored error from a security-relevant call
token, _ := jwt.Parse(tokenString, keyFunc) // parse error ignored, token may be nil/invalid
if token.Valid { // panics or false-negatives depending on token state
    grantAccess()
}

// FLAG: err checked but not returned/handled before continuing
if err := checkPermission(user, resource); err != nil {
    log.Println(err) // logged but request proceeds anyway
}
proceedWithAction()
```

Go's `:=` inside an `if`/`for` initializer creates a new scope; a reused `err` name there shadows the outer one. This is a recurring source of "the check ran, but its result was thrown away" auth bugs — verify the return value of the *inner* check is what actually gates access.

---

## Command Injection

### Flag These

```go
// FLAG: shell interpretation of user input
exec.Command("sh", "-c", "ping "+userInput).Run()
exec.Command("bash", "-c", cmdString) // cmdString built from request data

// SAFE: exec.Command with separate argv entries, no shell
exec.Command("ping", "-c", "3", userInput).Run() // still validate userInput format
```

`exec.Command` without `sh -c` does not invoke a shell, so metacharacters like `;`, `|`, `` ` `` are inert as long as the binary itself doesn't reinterpret the argument (e.g., ping resolves hostnames — validate the format).

---

## General Go

### Check Context

```go
// SSRF - check if URL is user-controlled
http.Get(userURL)
client.Do(req) // req.URL built from request data

// Deserialization - gob/json into interface{} can be a DoS/type-confusion vector
var v interface{}
json.Unmarshal(userData, &v) // deeply nested/huge payloads: check for size limits

// Weak randomness for security tokens
math/rand.Intn(1000000) // FLAG if used for session tokens, password reset codes
// SAFE alternative
crypto/rand.Read(buf)
```

---

## Grep Patterns

```bash
# Race-prone patterns
grep -rn "go func" --include="*.go" | grep -v "_test.go"

# SQL string building
grep -rn "fmt.Sprintf.*SELECT\|fmt.Sprintf.*INSERT\|db.Query(.*+\|db.Exec(.*+" --include="*.go"

# unsafe usage
grep -rn "unsafe\.\(Pointer\|Sizeof\|Offsetof\)" --include="*.go"

# TLS verification disabled
grep -rn "InsecureSkipVerify" --include="*.go"

# Shell-based command execution
grep -rn "exec.Command(\"sh\"\|exec.Command(\"bash\"" --include="*.go"

# Ignored errors on security-relevant calls
grep -rn "jwt.Parse\|Verify(.*)\s*$" --include="*.go" | grep ", _ :="

# Weak randomness
grep -rn "\"math/rand\"" --include="*.go"
```
