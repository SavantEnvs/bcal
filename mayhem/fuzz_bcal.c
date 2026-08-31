/* libFuzzer harness for bcal: parse + evaluate an untrusted byte-unit/arithmetic
 * expression string in-process (no file I/O, no network).
 *
 * bcal ships as ONE translation unit (src/bcal.c) with every routine declared
 * `static` -- there is no library boundary to link against. So this harness
 * #includes the upstream source directly, which has two effects that matter:
 *   1. It gives us direct access to `evaluate()`, bcal's core entrypoint --
 *      the same function main() calls for both `bcal <expr>` one-shot
 *      invocations and each line typed at the REPL prompt (src/bcal.c, see
 *      the `evaluate(argv[optind], sectorsz)` / `evaluate(tmp, sectorsz)`
 *      call sites). It calls fixexpr() -> infix2postfix() -> eval(), i.e.
 *      exactly the arithmetic/byte-unit expression parser+evaluator.
 *   2. Because the harness and bcal.c compile as ONE TU, the sanitizer +
 *      coverage flags applied to this file automatically cover all of
 *      bcal.c's code too -- there is no separate "library object" that could
 *      accidentally ship uninstrumented.
 *
 * bcal.c's own main() would collide with libFuzzer's / the standalone
 * driver's main() at link time, so it is renamed out of the way with a
 * preprocessor macro below. This is a pure textual, compile-time rename of
 * the #include'd copy -- the committed upstream file on disk is untouched.
 *
 * Built with -DNORL (see mayhem/build.sh): the harness never calls into the
 * readline/history code path (interactive-only), so this avoids pulling in
 * libreadline for the fuzz binary and keeps the harness purely byte-in,
 * no filesystem/network I/O.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main bcal_unused_main
#include "../src/bcal.c"
#undef main

/* evaluate() prints its result (and the REPL/error strings it shares with the
 * CLI) to stdout on every call. Rather than freopen() a path here (the gate
 * requires harness writes stay relative/under /tmp, and there's no need to
 * special-case one), just make stdout fully block-buffered instead of the
 * line-buffered/unbuffered mode it gets when Mayhem runs the target with
 * stdout attached to something other than a plain regular file -- this keeps
 * the flood of printf()s from adding a write(2) per call without touching
 * the filesystem at all. Exit status / sanitizer reports (the oracle Mayhem
 * actually cares about) are unaffected either way. */
int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;

    static char stdout_buf[1 << 16];
    setvbuf(stdout, stdout_buf, _IOFBF, sizeof(stdout_buf));

    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    /* The real CLI never calls evaluate() with an empty string -- both call
     * sites (main()'s single-arg path and the REPL loop) skip it before
     * reaching evaluate(). Mirror that invariant here rather than feeding
     * evaluate() a state it can never see in practice. */
    if (size == 0)
        return 0;

    /* evaluate() (via fixexpr()) mutates its input in place (strstrip(),
     * removeinnerspaces()) and expects a NUL-terminated C string, so copy
     * the raw fuzzer bytes into an owned, writable buffer first. */
    char *expr = (char *)malloc(size + 1);
    if (!expr)
        return 0;

    memcpy(expr, data, size);
    expr[size] = '\0';

    evaluate(expr, SECTOR_SIZE);

    free(expr);
    return 0;
}
