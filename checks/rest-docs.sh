#!/bin/bash
#
# Check of the REST documentation (httpdocs/misc/rest-api-v2.json, the spec
# read by the REST API page) against the sources:
#   - every documented path exists (a moved or removed endpoint leaves a
#     documentation that answers 404)
#   - a path documented as GET does not read only _POST (a GET request does
#     not fill _POST: the documented call cannot work). The opposite is fine:
#     ntopng also puts the params of a JSON POST in _GET
# The endpoints not documented are listed at the end, not failed: the internal
# ones (page contexts, wizard helpers) are left out on purpose.
#
# Requirements: jq.
#
# Usage: ./rest-docs.sh
# Report: logs/rest-docs-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
NTOPNG_ROOT="$(cd "${NTOPNG_ROOT:-../../..}" && pwd)"
REPORT="${PWD}/logs/rest-docs-report.txt"
SPEC="${NTOPNG_ROOT}/httpdocs/misc/rest-api-v2.json"
mkdir -p logs

# /lua/pro/rest/... -> pro/scripts/lua/rest/..., /lua/rest/... -> scripts/lua/rest/...
source_file() {
    case "${1}" in
        /lua/pro/*) echo "pro/scripts/lua/${1#/lua/pro/}" ;;
        *)          echo "scripts/lua/${1#/lua/}" ;;
    esac
}

cd "${NTOPNG_ROOT}" || exit 1
FAILS=""
fail() { FAILS+="FAIL  ${1}"$'\n'"      ${2}"$'\n'; }

DOCUMENTED=$(jq -r '.paths | keys[]' "${SPEC}")
DOCUMENTED_GET=$(jq -r '.paths | to_entries[] | select(.value | has("get")) | .key' "${SPEC}")
while read -r path; do
    file=$(source_file "${path}")
    if [ ! -f "${file}" ]; then
        fail "${path}" "documented, but ${file} does not exist (moved or removed?)"
        continue
    fi
    # Comments removed: an example in a comment is not a read
    code=$(sed 's/--.*$//' "${file}")
    if grep -qxF "${path}" <<< "${DOCUMENTED_GET}" && grep -q '_POST' <<< "${code}" && ! grep -q '_GET' <<< "${code}"; then
        fail "${path}" "documented as GET, but ${file} reads only _POST: document it as POST"
    fi
done <<< "${DOCUMENTED}"

UNDOCUMENTED=$(find scripts/lua/rest/v2 pro/scripts/lua/rest/v2 -name '*.lua' | sort |
    sed 's#^pro/scripts/lua/#/lua/pro/#; t; s#^scripts/lua/#/lua/#' | grep -vxF -f <(echo "${DOCUMENTED}"))

{
    printf '%s' "${FAILS}"
    echo "[i] Not documented ($(grep -c . <<< "${UNDOCUMENTED}"), fine for the internal ones: $(tr '\n' ' ' <<< "${UNDOCUMENTED}")"
    echo "REST DOCS   PATHS $(grep -c . <<< "${DOCUMENTED}")   FAIL $(grep -c '^FAIL' <<< "${FAILS}")"
} > "${REPORT}"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
