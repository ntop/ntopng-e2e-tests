#!/bin/bash
#
# Smoke test of the web GUI pages on a test instance of ntopng.
#
# ntopng is started as in ../rest/smoke.sh (login enabled, default pcap, own
# slot); once the pcap has been processed it runs smoke.mjs, that opens every
# page of the menu in headless Chromium and checks the i18n keys: see there
# for the checks.
#
# Requirements: Node.js; 'npm install' in this folder (it also downloads Chromium).
#
# Usage: [GUI_SMOKE_ONLY=<regex>] [GUI_SMOKE_PASSES=admin,dark,mobile,user] ./smoke.sh
# Report: logs/gui-smoke-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
GUI_PATH="${PWD}"
# The ntopng helpers and the pcaps are the ones of the REST tests
export TESTS_PATH="$(cd ../rest && pwd)"
export NTOPNG_ROOT="${NTOPNG_ROOT:-../../..}"
source "${TESTS_PATH}/common.sh"

NTOPNG_LOG="${GUI_PATH}/logs/gui-smoke-ntopng.log"
OUTPUT="${GUI_PATH}/logs/gui-smoke-output.txt"
REPORT="${GUI_PATH}/logs/gui-smoke-report.txt"
mkdir -p "${GUI_PATH}/logs"
rm -f "${REPORT}" "${OUTPUT}" "${GUI_PATH}"/logs/*.png

# Every outcome ends in the report: run.sh sends it with the failure notification
if [ ! -d node_modules ]; then
    echo "FAIL  setup: run 'npm install' in ${GUI_PATH}" | tee "${REPORT}"
    exit 1
fi

# Own slot, different from the one of rest/smoke.sh (14): the two can run together
ntopng_slot_setup "${GUI_SMOKE_SLOT:-13}"
NTOPNG_TEST_LOGIN=true
# test_01.pcap plus traffic with XSS payloads in the fields shown by the GUI (make_xss_pcap.py)
PCAP=gui_smoke.pcap

# Script run by ntopng once the pcap has been processed, as the runtime script:
# before the interfaces are shut down, so the live pages still have the hosts
# and flows of the pcap (the post script runs after they are flushed)
POST="$(mktemp)"
cat > "${POST}" <<EOF
NTOPNG_URL=http://localhost:${NTOPNG_TEST_HTTP_PORT} \
NTOPNG_PASSWORD='${NTOPNG_TEST_ADMIN_PASSWORD}' \
NTOPNG_LOG='${NTOPNG_LOG}' \
GUI_SMOKE_REPORT='${REPORT}' \
GUI_SMOKE_ONLY='${GUI_SMOKE_ONLY}' \
GUI_SMOKE_PASSES='${GUI_SMOKE_PASSES}' \
NTOPNG_ROOT='$(cd "${NTOPNG_ROOT}" && pwd)' \
node '${GUI_PATH}/smoke.mjs'
EOF

# ClickHouse when available, as in production (the historical pages need it)
CLICKHOUSE=false
clickhouse-client -q "SELECT 1" > /dev/null 2>&1 && CLICKHOUSE=true

ntopng_cleanup
ntopng_init_conf
ntopng_run "${PCAP}" "" "${POST}" "" "${OUTPUT}" "${NTOPNG_LOG}" "192.168.0.0/16" "" "${CLICKHOUSE}"
ntopng_cleanup
rm -f "${POST}"

# No report: ntopng did not start, or smoke.mjs stopped (e.g. Chromium missing a system library)
if [ ! -s "${REPORT}" ]; then
    {
        echo "FAIL  no report: ntopng did not start or smoke.mjs stopped, see ${NTOPNG_LOG}"
        tail -20 "${OUTPUT}" 2> /dev/null | sed 's/^/      /'
    } > "${REPORT}"
fi

sanitizer_fails "${NTOPNG_LOG}" >> "${REPORT}"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
