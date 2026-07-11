#!/usr/bin/env bash
#
# go-pprof/mayhem/build.sh — build google/pprof's OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer_v2.
#
# OSS-Fuzz target (projects/go-pprof/build.sh):
#   mv $SRC/fuzz_test.go $SRC/pprof/profile/
#   compile_native_go_fuzzer_v2 github.com/google/pprof/profile FuzzParseData FuzzParseData
# i.e. the MODERN native harness `func FuzzParseData(f *testing.F)` (fuzz_test.go), dropped into
# the `profile` package directory and built with build_native_go_fuzzer -> go-118-fuzz-build_v2
# under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE. The harness feeds the raw fuzz bytes
# straight into profile.ParseData(data) — the fuzzed surface is the pprof profile parser
# (proto.go / legacy_profile.go / legacy_java_profile.go: gzip-wrapped profile.proto AND the legacy
# text profile formats).
#
# We use the **v2** builder (compile_native_go_fuzzer_v2 == build_native_go_fuzzer with
# go-118-fuzz-build_v2): it loads the package WITH its test files (packages.Tests=true), matching
# OSS-Fuzz exactly. (FuzzParseData only calls the exported profile.ParseData, but v2 is what the
# OSS-Fuzz build.sh selects, so we replicate it faithfully.)
#
# We produce:
#   /mayhem/fuzz_parse_data — OSS-Fuzz target (profile.FuzzParseData, go-118-fuzz-build_v2, ASan+libFuzzer)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4+ and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain is pinned under /opt/toolchains (SPEC §6.2 item 8); GOMODCACHE is set in the
# Dockerfile ENV and survives the PATCH re-run under a different $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

# The go-118-fuzz-build_v2 tool lives on PATH via /opt/toolchains/go-path/bin (set in Dockerfile).
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# Drop the OSS-Fuzz fuzz harness into the profile package, exactly like projects/go-pprof/build.sh
# (`mv $SRC/fuzz_test.go $SRC/pprof/profile/`). Here $SRC is the repo root.
cp "$SRC/mayhem/fuzz_test.go" "$SRC/profile/fuzz_test.go"

# Resolve module deps. The v2 builder generates its own in-tree `testing` shim via a build overlay,
# so (unlike the legacy go-118-fuzz-build) it does NOT need the AdamKorcz testing module dep.
go mod tidy 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: profile.FuzzParseData via go-118-fuzz-build_v2 (func FuzzParseData(f *testing.F)) ─
#     Replicates compile_native_go_fuzzer_v2 -> build_native_go_fuzzer, which invokes
#     `go-118-fuzz-build_v2 -tags gofuzz -o $fuzzer.a -func FuzzParseData <abs_pkg_dir>`.
echo "=== building fuzz_parse_data (profile.FuzzParseData, go-118-fuzz-build_v2 -tags gofuzz) ==="
go-118-fuzz-build_v2 -tags gofuzz -o "$SRC/mayhem-build/fuzz_parse_data.a" -func FuzzParseData "$SRC/profile"
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_parse_data.a" -o /mayhem/fuzz_parse_data
echo "built /mayhem/fuzz_parse_data"

echo "build.sh complete:"
ls -la /mayhem/fuzz_parse_data 2>&1 || true
