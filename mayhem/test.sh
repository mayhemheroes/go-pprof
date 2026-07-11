#!/usr/bin/env bash
#
# go-pprof/mayhem/test.sh — RUN google/pprof's OWN Go test suite for the harnessed `profile`
# package and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: the `profile` package suite is a REAL known-answer / golden-output suite.
# proto_test.go round-trips profiles through Write/ParseData and asserts the decoded Profile equals
# the original (TestPackedEncoding, TestProto, parse/serialize round-trips); profile_test.go parses
# every testdata profile and diffs the result against a golden `.string` rendering (the `update`
# flag regenerates them — i.e. they are checked-in known answers); merge_test.go / prune_test.go /
# filter_test.go assert exact transformed output. They assert BEHAVIOUR, not "exits 0", so a no-op
# / `return nil` patch to ParseData (or the proto decoder) that breaks parsing FAILS this oracle —
# the round-trip and golden-string diffs will not match.
#
# Scope: the `profile` package only. That is the surface the fuzz target (FuzzParseData ->
# profile.ParseData) exercises, and its tests are hermetic (no binutils/symbolizer/browser/network
# dependencies that the driver & internal/* packages need). This keeps the oracle deterministic.
# This script only RUNS the suite (the project's own normal-flags suite — no sanitizer/fuzz build).
#
# Anti-reward-hacking (§6.3): Go test binaries are statically linked so LD_PRELOAD cannot neuter
# them. We add a behavioral probe using /mayhem/fuzz_parse_data, which IS dynamically linked (built
# with clang+ASan). Running it single-shot against a corpus entry and asserting libFuzzer's
# "Executed" marker confirms the fuzz target is alive. Under the sabotage LD_PRELOAD,
# fuzz_parse_data exits(0) silently (it is not under /usr/bin etc.), the grep fails, FAILED
# increments, and the oracle correctly reports a failure — not reward-hackable.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

mkdir -p "$SRC/mayhem-build"
echo "=== running: go test -json ./profile/... ==="
# -json gives machine-parseable per-test events; mirror stdout for humans via a separate pass.
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./profile/... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test ./profile/... 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_parse_data binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/fuzz_parse_data IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known corpus entry and assert that libFuzzer emits "Executed" — proving it actually processed
# the input. The sabotage LD_PRELOAD neuters fuzz_parse_data (not under /usr/bin etc.), causing it
# to exit silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/fuzz_parse_data/testsuite/corpus-gobench.cpu.pb"
if [ -x /mayhem/fuzz_parse_data ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzz_parse_data single-shot on corpus entry ==="
  PROBE_OUT=$(/mayhem/fuzz_parse_data "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzz_parse_data executed the corpus input (parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzz_parse_data produced no 'Executed' output (parser inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
