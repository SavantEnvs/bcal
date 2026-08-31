# UBSan: unchecked `long double` -> `unsigned __int128` cast in `unitconv()`

**Reproducer:** `repro` (4 bytes: `0~0~`) — replay with
`/mayhem/bcal-standalone mayhem/bcal/known-findings/unitconv-float-to-int128-overflow/repro`.

**Observed:**
```
src/bcal.c:2331:10: runtime error: 3.40282e+38 is outside the range of
representable values of type 'unsigned __int128'
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior src/bcal.c:2331:10
```

**Cause:** `src/bcal.c`, `unitconv()` (~line 2328):

```c
byte_metric = strtold(numstr, &punit);
if (*numstr != '\0' && *punit == '\0')
        return (maxuint_t)byte_metric;   // <-- unchecked cast, line 2331
```

A numeric token with no unit suffix is parsed with `strtold()` and cast straight to
`maxuint_t` (`unsigned __int128`). `~` (bitwise NOT) on the prior result produces
`2^128-1` (`340282366920938463463374607431768211455`), whose *decimal string* — when it
flows back through `unitconv()` as a bare numeric token in the second `~` application —
parses via `strtold()` to a `long double` of ~3.402823669e38, which sits just outside
`unsigned __int128`'s representable range (max ~3.402823669e38, but the closest
representable `long double` rounds up past it). The cast is unchecked, so this is
undefined behavior (not just a wrong answer).

**Impact:** UBSan-detected UB on this specific value-boundary; not observed to corrupt
memory or crash without the sanitizer (the underlying `(maxuint_t)` cast is well-defined
on this platform's `long double`->`__int128` codegen even where the C standard leaves it
undefined) — but a real correctness/UB bug regardless.

**One-line upstream fix:** clamp/range-check `byte_metric` against
`(maxfloat_t)UINT128_MAX` (and `0`) before the cast, returning an "invalid value" error
(matching the `is_integral_result()` bounds-check style already used elsewhere in this
file for `long long`) instead of casting out-of-range.

Not fixed here — upstream files are immutable on the `mayhem` branch (additive-only). Kept
out of `mayhem/bcal/testsuite/` (not wired into the replayed corpus).
