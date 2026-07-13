#!/usr/bin/env bash
#
# mayhem/build.sh — build the kent (UCSC Genome Browser) fuzz targets + the upstream test suite.
#
# Two Mayhem targets (historical names preserved):
#   * hextobyte  — in-process libFuzzer harness over lib/hex.c:hexToByte()
#   * bamtopsl   — in-process libFuzzer harness over the bamToPsl BAM->PSL code path
#                  (utils/bamToPsl/bamToPsl.c drives bamMustOpenLocal + bamToPslUnscored2).
#                  The upstream `bamToPsl` is a raw-file CLI; a subprocess file target gives
#                  essentially no coverage feedback, so it is driven in-process instead.
#
# The fuzz binaries are built with ASan+UBSan; the UBSan sub-checks `function`, `alignment`
# and `vptr` are disabled because htslib/kent (legacy C) trip them benignly on nearly every
# input (e.g. htslib calls hgetln through a mismatched function-pointer type), which would
# otherwise abort on every input and starve the fuzzer of coverage.
#
# The kent library links htslib statically, so htslib (+ its htscodecs submodule, materialised
# by mayhem/Dockerfile before this runs) is built here too. The fuzz binaries use a sanitized
# copy of the libraries; the upstream test suite is then (re)built + run by mayhem/test.sh with
# the project's normal flags (matching how upstream runs its own tests).
set -euo pipefail

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS:=}"
[ -n "${SOURCE_DATE_EPOCH:-}" ] || true

SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC"

export MACHTYPE=x86_64
HTS="$SRC/src/submodules/htslib"
LIBDIR="$SRC/src/lib/$MACHTYPE"
INCS="-I$SRC/src/inc -I$HTS"
# htslib.a must precede its deps (-lcurl -llzma ...) on the link line (see src/inc/common.mk).
LINK_TAIL="-lcurl -llzma -lssl -lcrypto -lpng -lz -lbz2 -lpthread -ldl -lm"

# htslib/kent are legacy C: htslib calls hgetln (and friends) through a mismatched function-pointer
# type, and touches misaligned/aliased data on ordinary inputs. Those trip UBSan's `function`,
# `alignment` and `vptr` sub-checks on nearly every input, which — with -fno-sanitize-recover — would
# abort before the target parses anything and starve the fuzzer of coverage. Disable ONLY those three
# sub-checks; ASan and the rest of UBSan stay on AND halting. Appended AFTER $SANITIZER_FLAGS so it
# applies whether the flags come from the base-image ENV or the default above.
UBSAN_RELAX="-fno-sanitize=function,alignment,vptr"
SAN="$SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS $COVERAGE_FLAGS -O1"
NORMAL="$DEBUG_FLAGS -O2"

clean_libs() {
  make -C "$HTS" clean >/dev/null 2>&1 || true
  ( cd "$SRC/src/lib" && rm -rf "$MACHTYPE" ./*.o font/*.o )
}

build_htslib() {   # $1 = CFLAGS
  ( cd "$HTS"
    make clean >/dev/null 2>&1 || true
    [ -x configure ] || autoreconf -i
    ./configure CC="$CC" CFLAGS="$1"
    make -j"$MAYHEM_JOBS" libhts.a )
}

build_jkweb() {    # $1 = COPT
  ( cd "$SRC/src/lib" && make -j"$MAYHEM_JOBS" CC="$CC" COPT="$1" )
}

# ----------------------------------------------------------------------------
# 1) Sanitized libraries + fuzz harnesses
# ----------------------------------------------------------------------------
clean_libs
build_htslib "$SAN"
build_jkweb  "$SAN"

ASANLIB="$SRC/mayhem/.asanlibs"
mkdir -p "$ASANLIB"
cp "$LIBDIR/jkweb.a"   "$ASANLIB/jkweb.a"
cp "$HTS/libhts.a"     "$ASANLIB/libhts.a"
ASAN_LINK="$ASANLIB/jkweb.a $ASANLIB/libhts.a $LINK_TAIL"

# libFuzzer targets (use $SAN — same sanitized flags as the libraries, incl. the UBSan relax)
$CXX $SAN $LIB_FUZZING_ENGINE $INCS \
    mayhem/fuzz_hexToByte.cpp $ASAN_LINK -o "$SRC/fuzz_hexToByte"
$CC  $SAN $LIB_FUZZING_ENGINE $INCS \
    mayhem/fuzz_bamToPsl.c   $ASAN_LINK -o "$SRC/bamToPsl"

# standalone reproducers (single input file, no libFuzzer runtime)
$CC  $SAN -c /opt/mayhem/StandaloneFuzzTargetMain.c -o "$SRC/mayhem/.sfmain.o"
$CXX $SAN $INCS "$SRC/mayhem/.sfmain.o" \
    mayhem/fuzz_hexToByte.cpp $ASAN_LINK -o "$SRC/fuzz_hexToByte-standalone"
$CC  $SAN $INCS "$SRC/mayhem/.sfmain.o" \
    mayhem/fuzz_bamToPsl.c   $ASAN_LINK -o "$SRC/bamToPsl-standalone"

# ----------------------------------------------------------------------------
# 2) Normal libraries + upstream test suite (behavioural, golden-diff)
#    Leaves normal jkweb.a / libhts.a in the tree for mayhem/test.sh to link against.
# ----------------------------------------------------------------------------
clean_libs
build_htslib "$NORMAL"
build_jkweb  "$NORMAL"

# Build (and validate) the upstream lib test suite so mayhem/test.sh only has to RUN it.
# kent's test makefile merges compile+run+assert, and uses bash-only redirections, so force bash.
( cd "$SRC/src/lib/tests" && rm -rf bin ./*.o output ./testSumDoubles ./fetchUrlTest ./fetchUrlViaUdcTest ./miniBlat )
ASAN_OPTIONS=detect_leaks=0 make -C "$SRC/src/lib/tests" \
    SHELL=/bin/bash CC="$CC" COPT="$NORMAL" STRIP=: \
    -j"$MAYHEM_JOBS" errCatchTest htmlPageTest htmlExpandUrlTest pipelineTests dyStringTest \
    mimeTests base64Tests quotedPTests safeTest hashTest gff3Test tabixTest vcfTest \
    hacTreeTest mmHashTest testSumDoubles jsonQueryTest dnaCodonTest

echo "build.sh: done — targets: fuzz_hexToByte, bamToPsl (+ standalones); upstream test suite built."
