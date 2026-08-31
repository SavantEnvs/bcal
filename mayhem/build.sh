#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# bcal's own Makefile always builds its `bcal` CLI binary at the repo root ($SRC/bcal),
# and $SRC IS /mayhem -- the SAME absolute path the Mayhemfile's fuzz target must live
# at (/mayhem/<target>, target=bcal). So the clean oracle build MUST happen (and be
# moved out of the way) BEFORE the fuzz binary is written to /mayhem/bcal, or the two
# builds silently clobber each other at that one path (caught empirically: an earlier
# ordering left the *clean* CLI sitting at /mayhem/bcal, un-sanitized and with no
# LLVMFuzzerTestOneInput entry point, while still passing a naive "does it exist" check).
#
# ---------------------------------------------------------------------------
# 1) Clean test build (project NORMAL flags, upstream's own `make`) for
#    mayhem/test.sh to RUN. This is the REAL `bcal` CLI binary, built exactly as
#    upstream's own CI does it (readline-enabled, no sanitizers) so the pytest
#    suite (test.py) exercises the program the way its own authors test it.
#    Staged into build-tests/ (test.py only ever refers to a relative `./bcal`, so
#    mayhem/test.sh cd's there before invoking pytest).
# ---------------------------------------------------------------------------
make -C "$SRC" -j"$MAYHEM_JOBS" clean
make -C "$SRC" -j"$MAYHEM_JOBS"
test -x "$SRC/bcal" || { echo "ERROR: bcal CLI binary not built for tests" >&2; exit 1; }

rm -rf "$SRC/build-tests"
mkdir -p "$SRC/build-tests"
mv "$SRC/bcal" "$SRC/build-tests/bcal"

# bcal ships EVERYTHING (CLI, parser, evaluator) as `static` functions in a single
# translation unit, src/bcal.c -- there is no separate library to build+link. So the
# usual "build upstream with $SANITIZER_FLAGS" step and "compile the harness" step
# collapse into one: mayhem/fuzz_bcal.c #includes src/bcal.c directly (see that file's
# header comment), so compiling the harness WITH $SANITIZER_FLAGS $DEBUG_FLAGS
# instruments all of bcal's code, not just the wrapper -- there is no uninstrumented
# "library object" to worry about here.
#
# Built with -DNORL: the harness/standalone binaries never call into bcal's
# readline/history code path (interactive-only, touches $HOME/.config + history files),
# so this keeps the fuzz build filesystem-free and avoids a libreadline dependency for
# the sanitized binaries. -lm: bcal.c uses modfl()/long double math.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -DNORL -I$SRC/inc"

# __lsan_is_turned_off() hook (mayhem/lsan_off.cc) — disables LeakSanitizer at build/link time.
# It's a C++ TU (needs $CXX to compile) but its extern "C" symbol links fine into bcal's C binaries.
LSAN_OFF_O="/tmp/lsan_off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_O"

# 2) Fuzzer binary (Mayhem target `bcal`).
$CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_bcal.c" "$LSAN_OFF_O" \
    -o /mayhem/bcal -lm

# 3) Standalone run-once reproducer (no libFuzzer runtime) for local repro of any finding.
$CC $FUZZ_CFLAGS "$STANDALONE_FUZZ_MAIN" \
    "$SRC/mayhem/fuzz_bcal.c" "$LSAN_OFF_O" \
    -o /mayhem/bcal-standalone -lm

echo "build.sh: OK"
