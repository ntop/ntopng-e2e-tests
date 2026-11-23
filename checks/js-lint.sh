#!/bin/bash
#
# ESLint of the GUI sources (pro/http_src, Vue and JS), only the rules that find
# bugs, no style (pro/.eslintrc.errors.json): undefined variables (a
# ReferenceError when the code runs), Vue templates and v-for not valid, props
# changed by the child, refs used without .value, keys repeated in an object.
# The globals the pages define (i18n, http_prefix, ntopng_utility, $...) are
# listed in the config.
#
# Requirements: 'npm install' in pro (eslint and eslint-plugin-vue).
#
# Usage: ./js-lint.sh
# Report: logs/js-lint-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
NTOPNG_ROOT="$(cd "${NTOPNG_ROOT:-../../..}" && pwd)"
REPORT="${PWD}/logs/js-lint-report.txt"
mkdir -p logs

if [ ! -d "${NTOPNG_ROOT}/pro/node_modules/eslint-plugin-vue" ]; then
    echo "FAIL  setup: run 'npm install' in ${NTOPNG_ROOT}/pro" | tee "${REPORT}"
    exit 1
fi

cd "${NTOPNG_ROOT}/pro" || exit 1
# unix format: one "file:line:col: message [rule]" line per problem
npm run --silent lint:errors -- -f unix > "${REPORT}.tmp" 2>&1
{
    grep -E '^/' "${REPORT}.tmp" | sed "s#^${NTOPNG_ROOT}/##; s/^/FAIL  /"
    echo "JS LINT   FAIL $(grep -cE '^/' "${REPORT}.tmp")"
} > "${REPORT}"
rm -f "${REPORT}.tmp"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
