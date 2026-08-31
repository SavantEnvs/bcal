#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# bcal's own functional suite is test.py: a pytest suite that runs the REAL, dynamically
# linked `bcal` CLI binary (built by mayhem/build.sh via upstream's own `make`, normal
# flags, no sanitizers) via subprocess and asserts EXACT stdout against golden values —
# 94 parametrized expression/conversion cases (test_output) plus several REPL-interaction
# cases that assert specific prompt/result substrings in the captured output. This is a
# real behavioral oracle: a neutered `bcal` (e.g. a PATCH that makes it exit(0) or print
# nothing) mismatches every golden string and fails every case.
#
# test.py only ever invokes a relative `./bcal` — and $SRC (/mayhem) is also the fuzz
# target's own absolute path (/mayhem/bcal is the SANITIZED libFuzzer binary), so
# build.sh stages the clean oracle binary in build-tests/ instead of $SRC to keep the
# two from colliding. Run pytest with that as cwd; point it at the test module by path.
TESTDIR="$SRC/build-tests"
[ -x "$TESTDIR/bcal" ] || { echo "ERROR: $TESTDIR/bcal missing — build.sh must build it first" >&2; emit_ctrf "pytest" 0 1 0; exit 1; }

JUNIT="$SRC/mayhem-pytest-junit.xml"
set +e
( cd "$TESTDIR" && python3 -m pytest "$SRC/test.py" -q --junitxml="$JUNIT" )
RC=$?
set -e

if [ ! -f "$JUNIT" ]; then
  echo "ERROR: pytest produced no JUnit report ($JUNIT missing)" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# Parse the single top-level <testsuite ... tests="T" failures="F" errors="E" skipped="S" .../>
# emitted by pytest's built-in --junitxml (no extra plugin needed).
LINE="$(grep -m1 '<testsuite ' "$JUNIT")"
getattr() { echo "$LINE" | grep -Eo "$1=\"[0-9]+\"" | head -1 | grep -Eo '[0-9]+'; }
TOTAL=$(getattr tests); FAILURES=$(getattr failures); ERRORS=$(getattr errors); SKIPPED=$(getattr skipped)
TOTAL=${TOTAL:-0}; FAILURES=${FAILURES:-0}; ERRORS=${ERRORS:-0}; SKIPPED=${SKIPPED:-0}

failed=$(( FAILURES + ERRORS ))
passed=$(( TOTAL - failed - SKIPPED ))
[ "$passed" -lt 0 ] && passed=0

# Belt-and-suspenders: a parse that silently yielded zero tests despite pytest actually
# running is worse than a loud failure (a `.dockerignore` or context problem could strip
# test.py out from under us — see docs/netnew-worker-prompt.md §4b).
if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: parsed 0 tests from JUnit report but pytest exit code was $RC — treating as failure" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$SKIPPED"
