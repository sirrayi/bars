#!/usr/bin/env bash
# Measures provider fetch latency through a fresh `bars serve` instance.
#
# Each provider gets its own cold measurement (first request after start, cache empty) followed by
# warm repeats that only exercise the response cache. This is the closest analogue to opening the
# app's menu: a long-lived process asked for usage on demand.
#
#   ./Scripts/bench-fetch.sh                    # enabled providers, 3 warm runs each
#   PROVIDERS="claude" RUNS=5 ./Scripts/bench-fetch.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${BARS_CLI:-"$ROOT/bars.app/Contents/Helpers/BarsCLI"}
PORT=${PORT:-8797}
RUNS=${RUNS:-3}
PROVIDERS=${PROVIDERS:-claude opencodego}
STARTUP=${STARTUP:-6}

[[ -x "$BIN" ]] || {
  echo "ERROR: bars CLI not found at $BIN (run ./Scripts/package_app.sh first)" >&2
  exit 1
}

server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
}
trap cleanup EXIT

# Times one request; prints seconds with millisecond precision.
time_request() {
  curl -s -o /dev/null -m "${TIMEOUT:-120}" -w "%{time_total}" \
    "http://127.0.0.1:${PORT}/usage?provider=$1"
}

printf '%-14s %10s %10s %10s\n' provider cold warm_best status
for provider in $PROVIDERS; do
  "$BIN" serve --port "$PORT" --refresh-interval 3600 >/tmp/bars-bench-serve.log 2>&1 &
  server_pid=$!
  ready=""
  for _ in $(seq 1 "$((STARTUP * 4))"); do
    if curl -sf -m 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.25
  done
  if [[ -z "$ready" ]]; then
    printf '%-14s %10s %10s %10s\n' "$provider" "-" "-" "no-server"
    cleanup
    continue
  fi

  cold=$(time_request "$provider")
  best=""
  for _ in $(seq 1 "$RUNS"); do
    warm=$(time_request "$provider")
    if [[ -z "$best" ]] || awk -v a="$warm" -v b="$best" 'BEGIN{exit !(a<b)}'; then
      best=$warm
    fi
  done
  printf '%-14s %9sms %9sms %10s\n' "$provider" \
    "$(awk -v t="$cold" 'BEGIN{printf "%.0f", t*1000}')" \
    "$(awk -v t="$best" 'BEGIN{printf "%.1f", t*1000}')" \
    "ok"
  cleanup
done
