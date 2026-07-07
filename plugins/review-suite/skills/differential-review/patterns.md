# Common Vulnerability Patterns

Quick reference for detecting common security issues in code changes.

**Specialized contexts:** For a codebase in a specific domain (smart contracts, crypto protocols, embedded systems, etc.), consult language- and framework-specific vulnerability pattern references for that domain in addition to the generic patterns below — e.g. official security guidelines for the language/framework in use, or a language-specific static analyzer's rule set.

---

## Security Regressions

**Pattern:** Previously removed code is re-added

**Detection:**
```bash
# Code previously removed for security
git log -S "pattern" --all --grep="security\|fix\|CVE"
```

**Red flags:**
- Commit message contains "security", "fix", "CVE", "vulnerability"
- Code removed <6 months ago
- No explanation in current PR for re-addition

**Example (Python):**
```python
# Removed in commit abc123 "Fix SSRF via unvalidated redirect target CVE-2024-1234"
# Re-added in current PR by a well-meaning refactor that dropped the check
def fetch_webhook(url: str):
    # REGRESSION: allow-list check on `url`'s host was here before the refactor;
    # this now fetches attacker-supplied URLs unchecked.
    return requests.get(url)
```

---

## Double Decrease/Increase Bugs

**Pattern:** Same accounting or state-mutating operation applied twice for the same logical event

**Detection:** Look for two state updates in related functions for the same logical action

**Example (Python):**
```python
# Reserve inventory
def reserve_order(order):
    inventory[order.sku] -= order.qty  # First decrement

# Confirm/ship order
def ship_order(order):
    inventory[order.sku] -= order.qty  # Second decrement - BUG! Already reserved.
```

**Impact:** Inventory count decremented twice per order; stock appears to run out early or goes negative

---

## Missing Validation

**Pattern:** Removed an input-validation check (assertion, guard clause, schema check) without a replacement

**Detection:**
```bash
git diff <range> | grep -E "^-.*(assert|validate|if not|raise|throw new)"
```

**Questions to ask:**
- Was validation moved elsewhere (e.g., into a shared middleware or decorator)?
- Is it redundant (defensive programming), or the only check on this path?
- Does removal expose a vulnerability (injection, negative amounts, oversized input)?

**Example (TypeScript):**
```diff
function withdraw(userId: string, amount: number) {
-   if (amount <= 0) throw new Error("Amount must be positive");
-   if (amount > getBalance(userId)) throw new Error("Insufficient balance");
    setBalance(userId, getBalance(userId) - amount);
}
```

**Risk:** Zero/negative-amount withdrawals and balance underflow are now possible

---

## Overflow / Truncation

**Pattern:** Arithmetic on user-controlled values without overflow or range checks

**Detection:**
- Look for `+`, `-`, `*` on values that came from request input or a loop counter
- Check whether a language's checked-arithmetic helper (Go's `math/bits`, Python's arbitrary-precision ints, Rust's `checked_add`) was bypassed with a raw operator or an `unsafe`/`unchecked` block
- Look for narrowing casts (`int64` → `int32`, `long` → `int`) applied to user-controlled values

**Example (Go):**
```go
// VULNERABLE: no bounds check, and the cast silently truncates
func setQuota(userQuota int64) {
    quota := int32(userQuota) // truncates values > 2^31-1, can wrap negative
    db.SetQuota(quota)
}
```

**Risk:** Wrap-around or truncation produces an incorrect (often negative or tiny) quota/balance value

---

## Reentrancy (Solidity — domain-specific illustration)

Reentrancy is specific to smart-contract execution models (a callee can call back into the caller mid-transaction before state is finalized); it's included here as a worked example of a domain-specific pattern class, alongside the general-purpose patterns above and below. For other domains, consult language/framework-specific vulnerability references for the equivalent hazard class (e.g., callback re-entry in event-driven systems, signal handler reentrancy in C).

**Pattern:** External call before state update

**Detection:** Look for CEI (Checks-Effects-Interactions) pattern violations

**Example:**
```solidity
// VULNERABLE: External call before state update
function withdraw() {
    uint amount = balances[msg.sender];
    (bool success,) = msg.sender.call{value: amount}("");  // External call FIRST
    require(success);
    balances[msg.sender] = 0;  // State update AFTER
}

// SAFE: State update before external call
function withdraw() {
    uint amount = balances[msg.sender];
    balances[msg.sender] = 0;  // State update FIRST
    (bool success,) = msg.sender.call{value: amount}("");  // External call AFTER
    require(success);
}
```

**Impact:** Attacker can recursively call withdraw() before balance is zeroed

---

## Access Control Bypass

**Pattern:** Removed or relaxed permission checks

**Detection:**
```bash
git diff <range> | grep -E "^-.*(@login_required|@require_role|is_admin|checkPermission|requireAuth)"
```

**Questions:**
- Who can now call this endpoint/function?
- What's the new trust model?
- Was the check moved to a caller, or dropped entirely?

**Example (Python/Flask):**
```diff
- @login_required
- @require_role("admin")
  def update_config(request):
      config.update(request.json)
      return "OK"
```

**Risk:** Any authenticated (or unauthenticated) user can now modify critical configuration

---

## Race Conditions from Caching

**Pattern:** A cache is introduced (or its invalidation is changed) without accounting for concurrent readers/writers

**Detection:** Look for a cache-read/cache-write pair added around a mutable resource, and check whether invalidation happens before or after the underlying write completes

**Example (Python):**
```python
# VULNERABLE: cache is invalidated before the write commits,
# so a concurrent reader can repopulate the cache with stale data
# in the window between invalidation and commit.
def update_profile(user_id, data):
    cache.delete(f"profile:{user_id}")   # invalidate FIRST
    db.update_profile(user_id, data)     # write happens AFTER, not yet visible

# SAFE: invalidate only after the write is durably committed
def update_profile(user_id, data):
    db.update_profile(user_id, data)     # write commits FIRST
    cache.delete(f"profile:{user_id}")   # invalidate AFTER
```

**Risk:** A reader between the two steps can re-cache the pre-update value, serving stale data indefinitely until the next write

---

## Time-Based Logic Manipulation

**Pattern:** Security-relevant logic that trusts a timestamp the caller can influence

**Detection:**
```bash
git diff <range> | grep -E "(request\.(timestamp|time)|client_time|Date\.now\(\)|time\.time\(\))"
```

**Example (TypeScript):**
```typescript
// VULNERABLE: trusts a client-supplied timestamp for token expiry checks
function isTokenValid(token: Token, clientTimestamp: number) {
  return clientTimestamp < token.expiresAt; // attacker controls clientTimestamp
}

// SAFER: use the server's own clock, not caller-supplied input
function isTokenValid(token: Token) {
  return Date.now() < token.expiresAt;
}
```

**Risk:** An attacker who controls the timestamp input can bypass expiry, rate limits, or replay windows

---

## Unchecked Return Values / Errors

**Pattern:** A call that can fail is invoked without checking its result

**Detection:**
```bash
git diff <range> | grep -E "^\+.*(\.write\(|\.send\(|os\.system\(|exec\.Command\()"
```

**Example (Go):**
```go
// VULNERABLE: error from the write is discarded
func saveAuditLog(entry string) {
    f.WriteString(entry) // return value (n, err) ignored
}

// SAFE: check and handle the error
func saveAuditLog(entry string) error {
    if _, err := f.WriteString(entry); err != nil {
        return fmt.Errorf("audit log write failed: %w", err)
    }
    return nil
}
```

**Risk:** Silent failures lead to inconsistent state (e.g., an audit log entry silently dropped)

---

## Denial of Service

**Pattern:** Unbounded loops or recursion over user-controlled input, or a critical path that blocks on an unbounded external call

**Detection:**
- Collections that grow without a size limit
- Loops over a user-controlled array/list with no cap
- A request handler that depends on an external call with no timeout

**Example (Python):**
```python
# DOS: no cap on the number of recipients, no per-call timeout;
# a single slow/malicious recipient can block the whole batch.
def notify_all(user_ids):
    for uid in user_ids:              # attacker controls len(user_ids)
        send_webhook(get_url(uid))    # no timeout — one slow endpoint stalls all
```

**Risk:** Request handler becomes unusable or ties up worker threads/processes under attacker-controlled load

---

## Quick Detection Commands

**Find removed validation/auth checks:**
```bash
git diff <range> | grep "^-" | grep -E "assert|validate|require|@login_required|@require_role"
```

**Find new external/network calls:**
```bash
git diff <range> | grep "^+" | grep -E "requests\.|fetch\(|http\.(Get|Post)|axios\."
```

**Find changed access-control decorators/middleware:**
```bash
git diff <range> | grep -E "@login_required|@require_role|isAdmin|checkPermission|requireAuth"
```

**Find arithmetic/casting changes:**
```bash
git diff <range> | grep -E "\+|\-|\*|/|int32\(|int64\("
```

Adapt these greps to the actual language/framework in the codebase under review — the patterns above are illustrative, not exhaustive.

---

**For detailed analysis workflow, see [methodology.md](methodology.md)**
**For building exploit scenarios, see [adversarial.md](adversarial.md)**
