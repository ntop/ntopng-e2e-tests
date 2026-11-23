#!/bin/bash
#
# Smoke test of every REST v2 endpoint (no expected output to maintain).
#
# ntopng is started with login enabled and the default pcap; once the pcap
# has been processed, smoke-check.sh calls every endpoint found under
# scripts/lua/rest/v2 and pro/scripts/lua/rest/v2 and checks:
#   - admin (read endpoints only): no Lua error or warning in the ntopng log
#     during the call, no HTTP 5xx, valid JSON, no INTERNAL_ERROR, no timeout
#   - unprivileged user and anonymous (all endpoints): the outcome (allowed or
#     denied) is the one recorded in smoke-baseline.txt
#
# Usage: [SMOKE_ONLY=<regex>] ./smoke.sh [-u]
#   SMOKE_ONLY: only the endpoints whose path matches (e.g. nedge/forwarder)
#   -u: rewrite smoke-baseline.txt with the outcomes of this run
# Report: logs/smoke-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
export TESTS_PATH="${PWD}"
export NTOPNG_ROOT="${NTOPNG_ROOT:-../../..}"
source ./common.sh

[ "${1}" = "-u" ] && export SMOKE_UPDATE_BASELINE=1

# Own slot: slot 0 would 'killall ntopng', including a development instance
ntopng_slot_setup "${SMOKE_SLOT:-14}"
NTOPNG_TEST_LOGIN=true

export SMOKE_PORT="${NTOPNG_TEST_HTTP_PORT}"
export SMOKE_LOG="${TESTS_PATH}/logs/smoke-ntopng.log"
export SMOKE_REPORT="${TESTS_PATH}/logs/smoke-report.txt"
export NTOPNG_ROOT_ABS="$(cd "${NTOPNG_ROOT}" && pwd)"
export SMOKE_PID_FILE="${NTOPNG_ROOT_ABS}/${NTOPNG_TEST_PID}"
POST="$(mktemp)"
echo "bash '${TESTS_PATH}/smoke-check.sh'" > "${POST}"
rm -f "${SMOKE_REPORT}"

# ClickHouse when available, as in production: without it the endpoints of
# the historical data only log "ClickHouse not enabled"
CLICKHOUSE=false
if command -v clickhouse-client > /dev/null && clickhouse-client -q "SELECT 1" > /dev/null 2>&1; then
    CLICKHOUSE=true
else
    echo "[i] No local ClickHouse server: the historical endpoints will fail"
fi

ntopng_cleanup
ntopng_init_conf
# The check is the runtime script: the live hosts and flows are still there (the
# post script runs after the interfaces are shut down)
ntopng_run "" "" "${POST}" "" /dev/null "${SMOKE_LOG}" "192.168.0.0/16" "" "${CLICKHOUSE}"

if [ ! -s "${SMOKE_REPORT}" ]; then
    echo "[!] No report produced: ntopng did not start or did not run the check, see ${SMOKE_LOG}"
    ntopng_cleanup
    exit 1
fi

# How ntopng was started, to reproduce a failure (the conf is removed below)
{
    echo "ntopng: $(cd "${NTOPNG_ROOT}" && ${NTOPNG_BIN} --version 2>&1 | head -3 | paste -sd' ' | tr -s '\t' ' ')"
    echo "Started as: ${NTOPNG_BIN} <conf> from ${NTOPNG_ROOT_ABS}, conf:"
    sed 's/^/      /' "${NTOPNG_TEST_CONF}"
    echo "ClickHouse flow dump: ${CLICKHOUSE}. Users: admin / ${NTOPNG_TEST_ADMIN_PASSWORD} (set in Redis DB ${NTOPNG_TEST_REDIS} by ntopng_init_conf), smoke / Smoke_user_pw_1 (unprivileged, no capabilities, added by smoke-check.sh)"
    echo "To reproduce: same conf without --shutdown-when-done and --test-script, then retry the URL with curl -u <user>:<password>"
    echo
    cat "${SMOKE_REPORT}"
} > "${SMOKE_REPORT}.tmp" && mv "${SMOKE_REPORT}.tmp" "${SMOKE_REPORT}"

ntopng_cleanup
rm -f "${POST}"

cat "${SMOKE_REPORT}"
grep -q '^FAIL' "${SMOKE_REPORT}" && exit 1
exit 0
