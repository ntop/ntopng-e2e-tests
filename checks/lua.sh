#!/bin/bash
#
# Static check of the ntopng Lua sources with luacheck, limited to the
# warnings that are bugs (no style):
#   011  syntax error
#   121  assignment to a read-only global (e.g. string = ...)
#   143  undefined field of a standard library (e.g. string.lenght, table.insrt)
#   314  key repeated in a table constructor (one of the values is lost)
#   511  unreachable code
#
# The functions ntopng adds to the standard libraries (e.g. string.split,
# table.empty in lua_utils) are found in the sources at every run.
#
# Requirements: luacheck (apt install lua-check).
#
# Usage: ./lua.sh
# Report: logs/lua-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
NTOPNG_ROOT="$(cd "${NTOPNG_ROOT:-../../..}" && pwd)"
REPORT="${PWD}/logs/lua-report.txt"
mkdir -p logs

if ! command -v luacheck > /dev/null; then
    echo "FAIL  setup: luacheck not found (apt install lua-check)" | tee "${REPORT}"
    exit 1
fi

cd "${NTOPNG_ROOT}" || exit 1
# scripts/lua/pro is a link to pro/scripts/lua
SOURCES="scripts/lua pro/scripts/lua scripts/locales"
EXCLUDE=("**/attic/**" "scripts/lua/pro/**")

# e.g. 'function string.split(' or 'table.merge = ...' -> string.split table.merge
STD_EXTENSIONS=$(grep -rhoE "^\s*(function\s+)?(string|table|os|math|io)\.[A-Za-z_]\w*\s*[(=]" ${SOURCES} --include=*.lua \
    | sed -E 's/^\s*(function\s+)?//; s/\s*[(=]$//' | sort -u)

luacheck --no-config --std lua54 --only 011 121 143 314 511 --globals ${STD_EXTENSIONS} \
    --exclude-files "${EXCLUDE[@]}" --formatter plain -- ${SOURCES} > "${REPORT}.tmp"

{
    sed 's/^/FAIL  /' "${REPORT}.tmp"
    echo "LUA CHECK   FAIL $(wc -l < "${REPORT}.tmp")"
} > "${REPORT}"
rm -f "${REPORT}.tmp"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
