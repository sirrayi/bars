#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_SIZE="${BARS_TEST_GROUP_SIZE:-12}"
SUITE_TIMEOUT="${BARS_TEST_SUITE_TIMEOUT:-180}"
RETRY_NON_TIMEOUT_FAILURES="${BARS_TEST_RETRY_NON_TIMEOUT_FAILURES:-1}"

cd "${ROOT_DIR}"

source "${ROOT_DIR}/Scripts/test_environment.sh"

ARGS=(
  --group-size "${GROUP_SIZE}"
  --timeout "${SUITE_TIMEOUT}"
)

case "${RETRY_NON_TIMEOUT_FAILURES}" in
  0) ARGS+=(--no-retry-non-timeout-failures) ;;
  1) ;;
  *)
    echo "BARS_TEST_RETRY_NON_TIMEOUT_FAILURES must be 0 or 1" >&2
    exit 2
    ;;
esac

if [[ -n "${BARS_TEST_SHARD_INDEX:-}" || -n "${BARS_TEST_SHARD_COUNT:-}" ]]; then
  ARGS+=(
    --shard-index "${BARS_TEST_SHARD_INDEX:?BARS_TEST_SHARD_COUNT requires BARS_TEST_SHARD_INDEX}"
    --shard-count "${BARS_TEST_SHARD_COUNT:?BARS_TEST_SHARD_INDEX requires BARS_TEST_SHARD_COUNT}"
  )
fi

exec python3 "${ROOT_DIR}/Scripts/ci_swift_test_by_suite.py" "${ARGS[@]}" "$@"
