#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/release_dsym_paths.sh"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bars-release-dsym-paths.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

make_dsym() {
  local dsym_path="$1"
  mkdir -p "$dsym_path/Contents/Resources/DWARF"
  touch "$dsym_path/Contents/Resources/DWARF/bars"
}

ARM_DSYM="$TEMP_DIR/bars arm64.dSYM"
UNIVERSAL_DSYM="$TEMP_DIR/bars universal.dSYM"
WRONG_ARCH_DSYM="$TEMP_DIR/bars stale.dSYM"
MISSING_DWARF_DSYM="$TEMP_DIR/bars missing.dSYM"
APP_BINARY="$TEMP_DIR/bars.app"
MATCHING_DWARF="$TEMP_DIR/bars matching"
MISMATCHED_DWARF="$TEMP_DIR/bars mismatched"
MISSING_UUID_DWARF="$TEMP_DIR/bars missing UUID"
make_dsym "$ARM_DSYM"
make_dsym "$UNIVERSAL_DSYM"
make_dsym "$WRONG_ARCH_DSYM"
mkdir -p "$MISSING_DWARF_DSYM/Contents/Resources/DWARF"
touch "$APP_BINARY" "$MATCHING_DWARF" "$MISMATCHED_DWARF" "$MISSING_UUID_DWARF"

lipo() {
  [[ "$1" == "-archs" ]]
  case "$2" in
    "$ARM_DSYM/Contents/Resources/DWARF/bars")
      printf '%s\n' "arm64"
      ;;
    "$UNIVERSAL_DSYM/Contents/Resources/DWARF/bars")
      printf '%s\n' "arm64 x86_64"
      ;;
    "$WRONG_ARCH_DSYM/Contents/Resources/DWARF/bars")
      printf '%s\n' "x86_64"
      ;;
    *)
      echo "unexpected lipo path: $2" >&2
      return 2
      ;;
  esac
}

dwarfdump() {
  [[ "$1" == "--uuid" ]]
  case "$2" in
    "$APP_BINARY" | "$MATCHING_DWARF")
      printf '%s\n' \
        "UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) $2" \
        "UUID: BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB (x86_64) $2"
      ;;
    "$MISMATCHED_DWARF")
      printf '%s\n' \
        "UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) $2" \
        "UUID: CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC (x86_64) $2"
      ;;
    "$MISSING_UUID_DWARF")
      printf '%s\n' "UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) $2"
      ;;
    *)
      echo "unexpected dwarfdump path: $2" >&2
      return 2
      ;;
  esac
}

arm_dwarf=$(bars_require_dsym_dwarf_for_arch "$ARM_DSYM" bars arm64)
[[ "$arm_dwarf" == "$ARM_DSYM/Contents/Resources/DWARF/bars" ]]

x86_dwarf=$(bars_require_dsym_dwarf_for_arch "$UNIVERSAL_DSYM" bars x86_64)
[[ "$x86_dwarf" == "$UNIVERSAL_DSYM/Contents/Resources/DWARF/bars" ]]

if bars_require_dsym_dwarf_for_arch "$MISSING_DWARF_DSYM" bars arm64 \
  2>"$TEMP_DIR/missing-dwarf.log"; then
  echo "ERROR: Missing dSYM DWARF file was accepted." >&2
  exit 1
fi
grep -Fq "$MISSING_DWARF_DSYM/Contents/Resources/DWARF/bars" "$TEMP_DIR/missing-dwarf.log"

if bars_require_dsym_dwarf_for_arch "$WRONG_ARCH_DSYM" bars arm64 \
  2>"$TEMP_DIR/wrong-arch.log"; then
  echo "ERROR: Wrong-architecture dSYM was accepted." >&2
  exit 1
fi
grep -Fq "required architecture: arm64" "$TEMP_DIR/wrong-arch.log"

bars_verify_dsym_matches_binary "$APP_BINARY" "$MATCHING_DWARF" arm64 x86_64

if bars_verify_dsym_matches_binary "$APP_BINARY" "$MISMATCHED_DWARF" arm64 x86_64 \
  2>"$TEMP_DIR/mismatched-uuid.log"; then
  echo "ERROR: Mismatched dSYM UUID was accepted." >&2
  exit 1
fi
grep -Fq "dSYM UUID mismatch for x86_64" "$TEMP_DIR/mismatched-uuid.log"

if bars_verify_dsym_matches_binary "$APP_BINARY" "$MISSING_UUID_DWARF" arm64 x86_64 \
  2>"$TEMP_DIR/missing-uuid.log"; then
  echo "ERROR: Missing dSYM UUID was accepted." >&2
  exit 1
fi
grep -Fq "Missing UUID for x86_64" "$TEMP_DIR/missing-uuid.log"

echo "Release dSYM path tests passed."
