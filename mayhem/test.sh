#!/usr/bin/env bash
#
# mayhem/test.sh — RUN kent's upstream lib test suite (src/lib/tests) and report CTRF.
#
# The suite is the project's own functional tests: each target compiles a small driver against
# the (already-built) jkweb.a/libhts.a, runs it, and `diff`s its output against a checked-in
# golden file in expected/ (or asserts an exit code / cmp). We run every group in the makefile's
# top-level `test:` target. Because upstream's makefile merges compile+run+assert into one recipe
# and uses bash-only redirections (`>&`), we invoke make with SHELL=/bin/bash; the heavy library
# build already happened in mayhem/build.sh, so this only relinks the tiny drivers and runs them.
#
# Behaviour is asserted via golden diffs, so a sabotage patch that makes the drivers exit(0)
# (producing empty/wrong output) fails the diffs -> non-zero -> repo flagged.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC"

export MACHTYPE=x86_64
export ASAN_OPTIONS=detect_leaks=0   # kent tools allocate-and-exit; only relevant if libs sanitized

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

TESTDIR="$SRC/src/lib/tests"
if [ ! -d "$TESTDIR" ] || [ ! -f "$SRC/src/lib/$MACHTYPE/jkweb.a" ]; then
  echo "test.sh: missing test dir or jkweb.a — build.sh did not run" >&2
  emit_ctrf "kent-lib-tests" 0 1 0
  exit 1
fi

# Top-level `test:` groups. fetchUrlTest is compile-only (the upstream `test:` target builds it but
# never runs/diffs it — no behavioural assertion) -> skipped. NB: do NOT name this GROUPS — that's a
# bash special variable (the caller's group IDs), so an assignment is silently overwritten.
TEST_GROUPS="errCatchTest htmlPageTest htmlExpandUrlTest pipelineTests dyStringTest mimeTests \
base64Tests quotedPTests safeTest hashTest gff3Test tabixTest vcfTest hacTreeTest mmHashTest \
testSumDoubles jsonQueryTest dnaCodonTest"

passed=0; failed=0; skipped=1   # fetchUrlTest
failed_groups=""
for g in $TEST_GROUPS; do
  if make -C "$TESTDIR" SHELL=/bin/bash CC="${CC:-clang}" COPT="${DEBUG_FLAGS:--g} -O2" STRIP=: "$g" \
        >"$SRC/.test_$g.log" 2>&1; then
    passed=$((passed+1))
  else
    failed=$((failed+1)); failed_groups="$failed_groups $g"
    echo "FAILED: $g" >&2; tail -20 "$SRC/.test_$g.log" >&2
  fi
done

[ -n "$failed_groups" ] && echo "test.sh: failing groups:$failed_groups" >&2
emit_ctrf "kent-lib-tests" "$passed" "$failed" "$skipped"
