// mayhem/lsan_off.cc
//
// Fleet policy: disable LeakSanitizer at build/link time for every ASan-built target, proactively —
// not just once a leak defect is found. Leaks aren't the bug class this fleet fuzzes for; ASan's own
// memory-corruption checks and UBSan stay fully active; only leak detection is affected.
//
// bcal specifically has a known, upstream-only leak (see
// mayhem/bcal/known-findings/infix2postfix-parse-error-leak/README.md: evaluate()'s parse-error path
// skips cleanqueue() and leaks any nodes infix2postfix() already enqueued) that would otherwise spam
// fuzzing with the same LeakSanitizer report over and over instead of surfacing new memory-corruption
// or UB defects.
extern "C" int __lsan_is_turned_off() {
    return 1;
}
