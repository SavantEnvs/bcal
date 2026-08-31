# Leak: `infix2postfix()` doesn't free its queue on a parse error

**Reproducer:** `repro` (2 bytes: `I-`) — replay with
`/mayhem/bcal-standalone mayhem/bcal/known-findings/infix2postfix-parse-error-leak/repro`.

**Cause:** `src/bcal.c`, `evaluate()` (~line 3212):

```c
ret = infix2postfix(expr, &front, &rear);
free(expr);
if (ret == -1)
        return -1;                 // <-- `front`/`rear` (any queue nodes already
                                    //     enqueue()'d before the parse error) leak here
```

`infix2postfix()` (`src/bcal.c` ~line 2403) can `enqueue()` one or more tokens onto
`front`/`rear` before hitting a later token it rejects and returning -1. `evaluate()`'s
error path returns immediately without calling `cleanqueue(&front)` (declared in
`inc/dslib.h`), so every node already queued is leaked.

**Impact:** a memory leak (72 bytes / node), invisible in real CLI use (the process exits
right after printing a result), but reproducible on a large fraction of malformed
expressions — confirmed by fork-mode fuzzing (`-fork=4 -ignore_crashes=1 -ignore_ooms=1
-ignore_timeouts=1 -max_total_time=150`, coverage climbed 238 -> 400+ edges while
repeatedly rediscovering this same leak alongside genuinely new findings — the "healthy"
pattern per this fleet's field notes, not a stuck target).

**One-line upstream fix:** `cleanqueue(&front);` before `return -1;` in `evaluate()`'s
`ret == -1` branch (and any other early-return path in `infix2postfix()`/`evaluate()`
that can leave nodes enqueued).

Not fixed here — upstream files are immutable on the `mayhem` branch (additive-only). Kept
out of `mayhem/bcal/testsuite/` per this fleet's rule (only crash-free seeds belong in the
replayed corpus); this reproducer is deliberately NOT wired into the corpus.
