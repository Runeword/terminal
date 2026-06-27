---
paths:
  - "**/*.go"
---

# Global Claude Instructions

## Go Code Quality Rules

When writing, reviewing, or modifying Go code, enforce the following rules derived from ["100 Go Mistakes and How to Avoid Them"](https://100go.co/) (Harsanyi, 2022). Point out violations and suggest corrections.

---

### Code & Project Organization

- **Variable shadowing**: Use `=` not `:=` when updating outer-scope variables. Flag `:=` inside inner blocks that shadow outer variables.
- **Nesting**: Align the happy path to the left. Return early on errors. Never keep an `else` after a block that returns.
- **`init` functions**: Only for infallible, side-effect-free setup. Never open connections, mutate global state, or do anything that can fail in `init`.
- **Getters/setters**: Not idiomatic in Go. Only add them when encapsulation is genuinely needed. Name getter `Balance()`, not `GetBalance()`.
- **Interfaces**: Define on the consumer side, not the producer side. Keep them small. Only create an interface when you have ≥2 implementations or a concrete decoupling need. Never return interfaces from constructors — return concrete types. Accept `io.Reader`/`io.Writer` etc. as parameters.
- **`any`**: Avoid `any` as parameter/return type. Costs compile-time type safety with no benefit unless truly accepting any type.
- **Generics**: Use only when you would otherwise write boilerplate across types. Don't use when a plain interface suffices. Wait until duplication forces your hand.
- **Type embedding**: Don't embed to gain syntactic sugar. Don't embed types that promote methods/fields that should stay private (e.g., `sync.Mutex` in exported structs).
- **Functional options**: Use `WithXxx(...Option)` pattern for optional configuration. Avoid config structs with pointer fields for optional params.
- **Package naming**: No `utils`, `common`, `base`, `helpers`, `shared`. Name packages after what they provide. Use short, lowercase, single-word names.
- **Package collisions**: Never name a variable the same as an imported package. Never shadow builtins (`copy`, `len`, `make`).
- **Documentation**: Every exported element must have a godoc comment starting with the element's name. End with punctuation.
- **Linters**: Always recommend `go vet`, `errcheck`, `golangci-lint`. Format with `gofmt`/`goimports`.

---

### Data Types

- **Octal literals**: Use `0o644` not `0644` for octal. Use `_` separator for large numbers (`1_000_000`).
- **Integer overflow**: Go silently wraps. Explicitly check bounds with `math.MaxInt`, `math.MinInt` before risky operations.
- **Floats**: Never use `==` to compare floats — use epsilon/delta comparison. Group operations by magnitude for precision.
- **Slices — length vs capacity**: `len` = accessible elements, `cap` = backing array size. Accessing beyond `len` panics even if within `cap`. Slicing shares the backing array.
- **Slice initialization**: Use `make([]T, n)` or `make([]T, 0, n)` when size is known — avoids repeated allocations.
- **nil vs empty slice**: Prefer `var s []T` over `s := []T{}` for empty slices — nil is equivalent for `append`/`range`/`len` but avoids allocation. `json` marshals nil as `null`, empty as `[]`.
- **Empty check**: Always `len(s) == 0`, never `s == nil` — works for both nil and empty.
- **Slice copy**: `copy(dst, src)` requires `len(dst) >= 1`. Initialize with `make([]T, len(src))` first.
- **Append side effects**: Sub-slices share the backing array. Use full slice expr `s[low:high:max]` to cap capacity before passing to functions that append.
- **Slice memory leaks**: Sub-slicing a large slice keeps the full backing array alive. Copy into a new slice to allow GC. Nil pointer fields in unused elements.
- **Map initialization**: Use `make(map[K]V, n)` with a size hint when approximate count is known.
- **Map memory leaks**: Maps never shrink. For long-lived maps that grow large, periodically re-create them. Use pointer values to reduce bucket size.
- **Comparisons**: Use `reflect.DeepEqual` for slices/maps/structs with non-comparable fields. Use `errors.Is`/`errors.As` for errors. Note: `reflect.DeepEqual` distinguishes nil from empty slices.

---

### Control Structures

- **Range value copy**: The range value variable is a copy. Use index (`slice[i]`) to mutate elements.
- **Range expression evaluated once**: The range expression is copied before the loop. Classic `for i < len(s)` re-evaluates each iteration.
- **Range pointer loop variable**: Loop variable has a single address. Create a local copy (`v := v`) or use `&slice[i]` for stable pointers.
- **Map iteration**: Never assume sorted, insertion-order, or consistent order. Never assume entries added during iteration will be visited.
- **`break` in switch/select**: `break` exits the innermost statement. Use labeled `break loop` to break an outer `for` loop from inside `switch`/`select`.
- **`defer` in loops**: `defer` executes when the function returns, not at iteration end. Extract the loop body into a function if you need per-iteration cleanup.

---

### Strings

- **Runes vs bytes**: `len(s)` = byte count. `range` iterates runes. Use `utf8.RuneCountInString(s)` for character count.
- **String indexing**: `s[i]` gives the byte at offset `i`, not the i-th character. Convert to `[]rune` for indexed character access.
- **Trim functions**: `TrimRight`/`TrimLeft` remove a **set of runes**. `TrimSuffix`/`TrimPrefix` remove an exact string. Don't confuse them.
- **String concatenation**: Never use `+=` in a loop. Use `strings.Builder`.
- **Bytes package**: Use `bytes.Contains`, `bytes.Split`, etc. when working with `[]byte` to avoid round-trip string conversions.
- **Substring memory leaks**: `s[i:j]` keeps the full backing array alive. Use `strings.Clone(s[i:j])` (Go 1.20+) for an independent copy.

---

### Functions & Methods

- **Receiver type**: Pointer receiver when mutating or when receiver contains non-copyable fields (e.g., `sync.Mutex`). Value receiver for small, immutable types. Be consistent — if one method has a pointer receiver, use pointer receivers for all methods on that type. **When in doubt, use a pointer receiver.**
- **Named return parameters**: Use when multiple same-type returns benefit from clarity. Don't abuse for documentation alone.
- **Named return + defer**: Deferred functions can read and modify named return values — be explicit about intent.
- **Nil receiver on interface**: Never return a typed nil pointer as an interface value — it's non-nil at the interface level. Return explicit `nil`.
- **`io.Reader` over filename**: Accept `io.Reader` instead of a filename parameter for better reusability and testability.
- **`defer` argument evaluation**: Arguments to `defer` are evaluated immediately. Use a pointer or closure to capture the value at execution time.

---

### Error Management

- **Panic**: Only for programmer errors or unrecoverable dependency failures. Use `MustXxx` naming convention for panicking variants.
- **Error wrapping**: Use `%w` to wrap and preserve (callers can use `errors.Is`/`errors.As`). Use `%v` to transform and hide (prevents coupling).
- **Error type checks**: Use `errors.As(err, &target)`, never type assertion on wrapped errors.
- **Error value checks**: Use `errors.Is(err, target)`, never `==` on wrapped errors.
- **Handle once**: Either log an error OR return it — never both. Use `fmt.Errorf("%w", err)` to add context while returning.
- **Ignored errors**: Never silently ignore errors. If intentional, use `_ = f()` to signal intent.
- **Defer errors**: Handle the error from deferred `Close()`, `Flush()`, etc. Use named return + closure to propagate or log.

---

### Concurrency

- **Concurrency vs parallelism**: Concurrency is structural design; parallelism is runtime execution. Don't conflate them.
- **Concurrency isn't always faster**: Benchmark sequential vs concurrent. Goroutine overhead can outweigh gains for small workloads.
- **Channels vs mutexes**: Channels for goroutine coordination/orchestration. Mutexes for protecting shared state accessed by parallel goroutines.
- **Data races**: Use `-race` flag in all tests. Synchronize all shared memory with atomics, mutexes, or channels.
- **Workload type**: CPU-bound goroutines: limit to `GOMAXPROCS`. I/O-bound: can have more since they mostly wait.
- **Context**: Pass `ctx` as first function parameter. Check cancellation in long loops. Never store in struct fields. Use for request-scoped data only.
- **Context propagation**: Don't pass HTTP request context to goroutines that outlive the request. Use `context.Background()` or `context.WithoutCancel` (Go 1.21+).
- **Goroutine lifecycle**: Every goroutine must have a clear stop condition (cancellation, done channel, timeout). Never start fire-and-forget goroutines.
- **Loop variable capture**: Create a local copy (`v := v`) before launching goroutines in loops, or pass as argument.
- **`select` non-determinism**: Multiple ready cases are selected randomly. Never rely on `select` for priority.
- **Notification channels**: Use `chan struct{}` for signal-only channels (zero allocation).
- **Nil channels**: Sending/receiving on nil blocks forever — use this to disable `select` cases dynamically.
- **Channel sizing**: Default to unbuffered. Size 1 for single async events. Larger buffers only with documented justification.
- **String formatting in critical sections**: `fmt.Sprintf` may call `String()`/`Error()` methods which may acquire locks → deadlock risk.
- **Concurrent append**: Not safe. Protect with mutex or use per-goroutine slices.
- **Mutex with slice/map**: Shallow copy (`m2 := m`) shares underlying data. Either extend the critical section or deep-copy inside the lock.
- **`sync.WaitGroup`**: Call `wg.Add(n)` before launching goroutines, not inside them.
- **`sync.Cond`**: Use for broadcasting to multiple waiting goroutines.
- **`errgroup`**: Use `golang.org/x/sync/errgroup` for groups of goroutines that return errors.
- **Copying `sync` types**: Never copy `sync.Mutex`, `sync.WaitGroup`, `sync.Cond`, etc. Always pass/embed via pointer.

---

### Standard Library

- **`time.Duration`**: Always use time constants (`time.Second`, `time.Millisecond`). Never pass bare integers.
- **`time.After` in loops**: Creates a timer that leaks until it fires. Use `time.NewTimer` + `Stop()` or `context.WithTimeout`.
- **JSON**: Embedding types that implement `json.Marshaler` overrides marshaling. Use `json.Decoder.UseNumber()` to avoid float64 coercion of numbers. Use `time.Equal()` not `==` for time comparison.
- **SQL**: `sql.Open` doesn't connect — call `db.PingContext`. Configure pool (`SetMaxOpenConns`, `SetMaxIdleConns`, `SetConnMaxLifetime`). Use prepared statements. Use `sql.NullString` for nullable columns. Check `rows.Err()` after iteration.
- **Resource closing**: Defer `Close()` on all `io.Closer` resources. Close `http.Response.Body` even if unread. Handle errors from `Close()` on `os.File`.
- **HTTP handler**: `http.Error` does NOT stop execution — always `return` after it.
- **HTTP client/server**: Never use the default `http.Client` (no timeouts). Always configure timeouts: `Timeout`, `TLSHandshakeTimeout`, `ResponseHeaderTimeout`. Never use default `http.Server` — configure `ReadHeaderTimeout`, `ReadTimeout`.

---

### Testing

- **Test categorization**: Use build tags (`//go:build integration`) or `-short` to separate unit vs integration tests.
- **Race detection**: Always use `-race` for concurrent code tests.
- **Parallelism**: Use `t.Parallel()` for independent tests. Use `-shuffle=on` to expose ordering dependencies.
- **Table-driven tests**: Use `[]struct{...}` test cases with `t.Run(name, func)` subtests.
- **No sleeping**: Never `time.Sleep` in tests. Use channels or `sync.WaitGroup` to synchronize.
- **Time injection**: Inject time as a `func() time.Time` parameter for deterministic time-dependent tests.
- **`httptest`**: Use `httptest.NewRecorder` for handler tests. Use `httptest.NewServer` for client tests.
- **`iotest`**: Use `iotest.ErrReader`, `iotest.HalfReader` to test reader resilience.
- **Benchmarks**: Call `b.ResetTimer()` after setup. Use `b.StopTimer()`/`b.StartTimer()` per-iteration. Prevent compiler elimination with package-level result vars.
- **Coverage**: Use `-coverprofile`. Test from `package foo_test` to enforce testing public API only. Use `t.Cleanup` for teardown. Use `TestMain` for package-level setup.

---

### Optimizations (apply only in performance-critical contexts)

- **CPU caches**: Organize data for spatial locality. Prefer struct-of-slices over slice-of-structs for single-field loops. Avoid critical stride access patterns.
- **False sharing**: Pad variables modified by different goroutines to separate cache lines.
- **Struct alignment**: Order fields largest to smallest (`int64`, `int32`, `int16`, `int8`, `bool`) to minimize padding.
- **Escape analysis**: Use `go build -gcflags="-m"` to find heap escapes. Minimize allocations on hot paths.
- **Allocation reduction**: Design APIs to accept pre-allocated buffers. Use `sync.Pool` for frequently allocated objects.
- **Inlining**: Keep hot-path functions small. Use fast-path/slow-path pattern. Check with `-gcflags="-m"`.
- **Profiling**: Use `pprof` for CPU/memory profiles before optimizing. Use execution tracer for scheduling/GC issues.
- **GC tuning**: `GOGC` (default 100) controls GC frequency. `GOMEMLIMIT` (Go 1.19+) caps memory. Fewer allocations = less GC pressure.
- **Container awareness**: Use `go.uber.org/automaxprocs` in Docker/Kubernetes to set `GOMAXPROCS` from container CPU quota, not host CPUs.
