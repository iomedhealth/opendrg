#!/bin/bash
# Compile and run the MS-DRG oracle harness end to end.
#
#   ./run.sh                 # full run: v44.0 fixtures + validation run (wrapper + API auto-version)
#   ./run.sh --version 430   # extra run with another bundled version (400..440), written as testdb_v430_*
#   ./run.sh --help
#
# Requirements: JDK 17+ (tested with OpenJDK 27 at /usr/bin/java), no Maven, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORACLE_DIR="$(cd "$HERE/.." && pwd)"
EXTRACT="${MSDRG_EXTRACT:-/Users/gabriel.maeztu/repos/open-grd/target/MS-DRG V44 FY2027 (CMS)/_extract}"
JAVA="${JAVA:-/usr/bin/java}"
JAVAC="${JAVAC:-/usr/bin/javac}"

MF_PKG="$EXTRACT/mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package"
FAT_JAR="$MF_PKG/CMSDRG440_MF_Java_jar/MSDRGMF440.jar"
TESTDB="${TESTDB:-$MF_PKG/CMSDRG440_MF_Java_Misc/TESTDB}"
OUT="${OUT:-$ORACLE_DIR/output}"
BUILD="$HERE/build"

# Official Java API jars first (gov.agency.msdrg.*), then CMS's mainframe fat jar which supplies the
# third-party dependencies (GFC foundation com.mmm.his.cer.*, protobuf, slf4j, farser) and the
# mainframe wrapper gov.cms.grouper.mainframe.Msdrg used for the validation run. The grouper's
# relocated copy inside the fat jar lives under msdrg.mf.v44003.* so it does not shadow the API jars.
CP="$EXTRACT/msdrg/msdrg-core-44.0.0.3.jar"
CP="$CP:$EXTRACT/msdrg/msdrg-model-v2-2.12.2.jar"
CP="$CP:$EXTRACT/msdrg/msdrg-binary-access-1.6.4.jar"
CP="$CP:$FAT_JAR"

for f in "$EXTRACT/msdrg/msdrg-core-44.0.0.3.jar" "$EXTRACT/msdrg/msdrg-model-v2-2.12.2.jar" \
         "$EXTRACT/msdrg/msdrg-binary-access-1.6.4.jar" "$FAT_JAR" "$TESTDB"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# protobuf 3.25 still uses sun.misc.Unsafe; JDK 23+ prints a warning unless allowed explicitly.
JVM_FLAGS=(-Xmx1g)
if "$JAVA" --sun-misc-unsafe-memory-access=allow -version >/dev/null 2>&1; then
  JVM_FLAGS+=(--sun-misc-unsafe-memory-access=allow)
fi

if [ "${1:-}" = "--help" ]; then
  echo "usage: run.sh [--version 440|auto] [--mode api|wrapper|both] [--prefix NAME] [--suffix S]"
  echo "              [--poa-status per-record|NON_EXEMPT|EXEMPT|UNKNOWN] [--skip-inputs] [--no-trace]"
  echo "              [--lenient-numeric] [--limit N]"
  echo "       run.sh dump [--version 440]      only the data-table dump (v440_*.csv)"
  echo "       with no arguments: v44.0 fixture run, POA-UNKNOWN sensitivity run, table dump, validation run"
  exit 0
fi

echo "== compiling"
rm -rf "$BUILD"
mkdir -p "$BUILD"
"$JAVAC" -Xlint:-options --release 17 -d "$BUILD" -cp "$CP" "$HERE"/src/oracle/*.java

mkdir -p "$OUT"
MISC="$MF_PKG/CMSDRG440_MF_Java_Misc"
run() {
  echo "== java oracle.OracleHarness $*"
  "$JAVA" "${JVM_FLAGS[@]}" -cp "$BUILD:$CP" oracle.OracleHarness --testdb "$TESTDB" "$@"
}
dump() {
  echo "== java oracle.DataDump $*"
  "$JAVA" "${JVM_FLAGS[@]}" -cp "$BUILD:$CP" oracle.DataDump --out "$OUT" \
    --prclstrs "$MISC/PRCLSTRS" --drglogic "$MISC/DRGLOGIC" "$@"
}

if [ "${1:-}" = "dump" ]; then
  shift
  dump "$@"
  exit 0
fi
if [ $# -gt 0 ]; then
  run --out "$OUT" "$@"
  exit 0
fi

# 1. The fixtures: every TESTDB claim grouped with v44.0 through the official API, hospital POA
#    status taken per record from TESTDB column 7, CLINICAL_SIGNIFICANCE + COMPUTE, trace on.
run --out "$OUT" --version 440 --mode api --prefix testdb_v440

# 2. Sensitivity run: same claims with poaReportingExempt = UNKNOWN for every claim.
run --out "$OUT" --version 440 --mode api --prefix testdb_v440 --poa-status UNKNOWN \
    --suffix _poa_unknown --skip-inputs --no-trace
echo "== java oracle.CompareExpected (per-record POA status vs UNKNOWN)"
"$JAVA" -cp "$BUILD:$CP" oracle.CompareExpected "$OUT/testdb_v440_expected.csv" \
    "$OUT/testdb_v440_expected_poa_unknown.csv" "$OUT/testdb_v440_poa_sensitivity.csv" \
    per_record unknown

# 3. Grouper data tables for v44.0 (formulas, descriptions, clusters) straight from the binary blob.
dump --version 440

# 4. Validation: CMS's own mainframe wrapper (version by discharge date) vs the expectations
#    embedded in TESTDB, and the API (auto version, 400..440) vs the wrapper.
run --out "$OUT/validation" --version auto --mode both --prefix testdb_vauto --no-trace

echo "== outputs in $OUT"
ls -la "$OUT" "$OUT/validation"
