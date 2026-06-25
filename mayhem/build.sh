#!/usr/bin/env bash
#
# mayhem/build.sh — build libqalculate's fuzz harness (+ standalone reproducer) AND its own test
# tooling (qalc, used as the behavioral test oracle by mayhem/test.sh).
#
# libqalculate is an autotools C++ project. We build it as a STATIC, INSTRUMENTED library
# (ASan+UBSan + SanitizerCoverage) so the fuzzed parser/evaluator code itself is instrumented, then
# link the harness against libqalculate.a.
#
# Air-gapped + idempotent: all apt deps are pre-baked in the Dockerfile; autogen.sh / configure /
# make all re-run OFFLINE on a previously-built tree. We disable libcurl (no network exchange-rate
# fetch), icu, gnuplot, and NLS to minimize the dependency surface and make the data definitions a
# plain copy of the bundled .xml.in files (no gettext/msgfmt translation step).
set -euo pipefail

# clang rejects an empty SOURCE_DATE_EPOCH — unset rather than pass "".
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
# SanitizerCoverage for the LIBRARY so libFuzzer is coverage-guided on the parser itself (ASan/UBSan
# alone add NO coverage). -fsanitize=fuzzer-no-link instruments without linking the libFuzzer main,
# so libqalculate.a links into both the fuzzer (with the engine) and the standalone reproducer.
: "${FUZZ_COV:=-fsanitize=fuzzer-no-link}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN FUZZ_COV MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

COMMON_CONF="--disable-shared --enable-static --without-libcurl --without-icu --without-gnuplot-call --disable-nls"

# autogen.sh generates configure + Makefile.in's from configure.ac. NOCONFIGURE keeps it from
# running ./configure itself (we drive configure per-tree below). Re-running offline is fine
# (autopoint/aclocal/automake/autoconf all use the in-image autotools install, no network).
if [ ! -x ./configure ]; then
    NOCONFIGURE=1 ./autogen.sh
fi

# ---------------------------------------------------------------------------------------------
# 1) INSTRUMENTED static build of libqalculate (the fuzzed code). Out-of-place build dir keeps the
#    source tree clean and the build idempotent (only configure if not yet configured).
# ---------------------------------------------------------------------------------------------
INST_FLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS"
mkdir -p build-fuzz
if [ ! -f build-fuzz/Makefile ]; then
    ( cd build-fuzz && \
      ../configure CXX="$CXX" CC="$CC" \
          CXXFLAGS="$INST_FLAGS" CFLAGS="$INST_FLAGS" \
          $COMMON_CONF )
fi
make -C build-fuzz -j"$MAYHEM_JOBS"

LIB="$SRC/build-fuzz/libqalculate/.libs/libqalculate.a"
[ -f "$LIB" ] || { echo "instrumented libqalculate.a not found at $LIB" >&2; exit 1; }

# Dependent libs libqalculate needs at link time (curl/icu disabled above).
DEPLIBS="-lmpfr -lgmp -lxml2 -lpthread -lm"

# ---------------------------------------------------------------------------------------------
# 2) Compile the harness TWICE: once with the libFuzzer engine, once with the standalone run-once
#    driver. The C++ harness's LLVMFuzzerTestOneInput has C linkage, so the standalone driver is
#    compiled as a C object first (clang++ would otherwise mangle the symbol reference).
# ---------------------------------------------------------------------------------------------
INCL="-I$SRC -I$SRC/libqalculate $(pkg-config --cflags libxml-2.0)"

$CXX $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS $INCL \
    "$SRC/mayhem/fuzz.cpp" $LIB_FUZZING_ENGINE \
    "$LIB" $DEPLIBS \
    -o /mayhem/libqalculate-fuzz

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS $INCL \
    "$SRC/mayhem/fuzz.cpp" /tmp/standalone_main.o \
    "$LIB" $DEPLIBS \
    -o /mayhem/libqalculate-fuzz-standalone

# ---------------------------------------------------------------------------------------------
# 3) Build the TEST oracle with NORMAL flags (clean, independent tree). qalc's `--test-file` mode is
#    a known-answer-test runner: it feeds each tests/*.batch expression through the real parser +
#    evaluator and compares the printed result to the expected value baked in the .batch file,
#    exiting non-zero on the first mismatch. Default autotools CXXFLAGS are -g -O2 (no NDEBUG → asserts
#    live). readline disabled (non-interactive). NLS disabled so data/*.xml are plain copies.
# ---------------------------------------------------------------------------------------------
mkdir -p build-tests
if [ ! -f build-tests/Makefile ]; then
    ( cd build-tests && \
      env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      ../configure CXX="$CXX" CC="$CC" \
          CXXFLAGS="$COVERAGE_FLAGS -g" CFLAGS="$COVERAGE_FLAGS -g" \
          $COMMON_CONF --with-readline=no --enable-unittests )
fi
make -C build-tests -j"$MAYHEM_JOBS"
[ -x "$SRC/build-tests/src/qalc" ] || { echo "test oracle qalc not built" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# 4) Stage the generated definitions data to a STABLE location for both runtime use (the fuzz binary
#    calls loadGlobalDefinitions) and the test oracle. data/*.xml are produced by `make` from the
#    bundled *.xml.in (plain copy, NLS off). Calculator::getGlobalDefinitionsDir() honours
#    $QALCULATE_DEFINITIONS_DIR (set as an ENV in the Dockerfile / Mayhemfile to this dir).
# ---------------------------------------------------------------------------------------------
DATADST="/mayhem/qalculate-data"
mkdir -p "$DATADST"
cp -f "$SRC"/build-tests/data/*.xml "$DATADST"/ 2>/dev/null || true
cp -f "$SRC"/build-tests/data/*.json "$DATADST"/ 2>/dev/null || true
# Fallback: if the build placed nothing (e.g. some files only as .in), copy from build-fuzz too.
cp -f "$SRC"/build-fuzz/data/*.xml "$DATADST"/ 2>/dev/null || true
[ -f "$DATADST/functions.xml" ] || { echo "definitions data not staged ($DATADST/functions.xml missing)" >&2; ls -la "$SRC"/build-tests/data/ >&2; exit 1; }

echo "build.sh OK: libqalculate-fuzz, libqalculate-fuzz-standalone, build-tests/src/qalc, data=$DATADST"
