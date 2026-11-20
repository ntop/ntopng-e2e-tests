#!/bin/bash
#
# Unit tests of the GUI JavaScript utilities (Vitest): pro/tests/js/*.test.js,
# run with 'npm run test:js' in pro.
#
# Requirements: 'npm install' in pro (the GUI build dependencies, Vitest included).
#
# Usage: ./js.sh
# Report: logs/js-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
NTOPNG_ROOT="$(cd "${NTOPNG_ROOT:-../../..}" && pwd)"
REPORT="${PWD}/logs/js-report.txt"
mkdir -p logs

if [ ! -x "${NTOPNG_ROOT}/pro/node_modules/.bin/vitest" ]; then
    echo "FAIL  setup: run 'npm install' in ${NTOPNG_ROOT}/pro" | tee "${REPORT}"
    exit 1
fi

cd "${NTOPNG_ROOT}/pro" || exit 1
# --reporter=dot: the failed tests in full, a dot for the passed ones
if npm run --silent test:js -- --reporter=dot --no-color > "${REPORT}.tmp" 2>&1; then
    RESULT="JS TESTS   OK"
else
    RESULT="FAIL  JS TESTS: see the failed tests above"
fi
{
    cat "${REPORT}.tmp"
    echo "${RESULT}"
} > "${REPORT}"
rm -f "${REPORT}.tmp"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
