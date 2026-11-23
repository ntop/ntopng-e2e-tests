#!/bin/bash
#
# Run by ntopng (--test-script-post) on behalf of smoke.sh: see there.
#
# It can also run on an ntopng already running, e.g. the development one with
# real traffic (SMOKE_URL set): then only the admin calls of the read endpoints
# are done (no permission check: the unprivileged and anonymous calls also reach
# the write endpoints) and the endpoints with side effects are skipped:
#   SMOKE_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> SMOKE_IFID=<ifid> ./smoke-check.sh
#   [SMOKE_LOG=<ntopng log, checked if set>] [SMOKE_ONLY=<regex>]
# Report: logs/smoke-live-report.txt (also printed).
#

LIVE="${SMOKE_URL}"
if [ -n "${LIVE}" ]; then
    cd "$(dirname "$0")" || exit 1
    TESTS_PATH="${PWD}"
    NTOPNG_ROOT_ABS="$(cd ../../.. && pwd)"
    SMOKE_REPORT="${SMOKE_REPORT:-${TESTS_PATH}/logs/smoke-live-report.txt}"
    mkdir -p "$(dirname "${SMOKE_REPORT}")"
fi
B="${SMOKE_URL:-http://localhost:${SMOKE_PORT}}"
ADMIN="${NTOPNG_USER:-admin}:${NTOPNG_PASSWORD:-${NTOPNG_TEST_ADMIN_PASSWORD}}"
USER_PW="Smoke_user_pw_1"
BASELINE="${TESTS_PATH}/smoke-baseline.txt"
# Read endpoints that change the instance: not called on a running ntopng
LIVE_SKIP="/get/system/reload_ndpi.lua|/get/ntopng/licenses_auth_token.lua"
TMP="$(mktemp -d)"
FAILS="${TMP}/fails"
OUTCOMES="${TMP}/outcomes"
touch "${FAILS}" "${OUTCOMES}"

# Params of the user without capabilities and of the anonymous caller: only
# ifid, so their outcome (allowed or denied) does not depend on the pcap
PARAMS="ifid=${SMOKE_IFID:-0}"

# Params of the admin: also a real host, MAC, ASN, flow and time range of the
# traffic, so the endpoints that need them run the code path with the data
# instead of stopping at INVALID_ARGUMENTS or NOT_FOUND; a value not found
# (e.g. no host on a view member interface) is left out
# shortcut: one value per param for every endpoint (e.g. no SNMP device or
# exporter); add per-endpoint params in EXTRA_PARAMS when needed
real_params() {
    local host flow host_data
    get() { curl -s -u "${ADMIN}" "${B}/lua/rest/v2/get/${1}?${PARAMS}&${2}"; }
    host=$(get host/active_list.lua "length=1&start=0" | jq -c '.rsp[0].host // empty' 2> /dev/null)
    flow=$(get flow/active.lua "perPage=1" | jq -c '.rsp.data[0] // empty' 2> /dev/null)
    [ -n "${host}" ] && host_data=$(get host/data.lua "host=$(jq -r .ip <<< "${host}")&vlan=$(jq -r '.vlan.id // 0' <<< "${host}")" | jq -c '.rsp')
    jq -rn --arg base "${PARAMS}" --argjson now "$(date +%s)" \
        --argjson host "${host:-null}" --argjson flow "${flow:-null}" --argjson data "${host_data:-null}" '
        [ $base,
          (if $host then "host=\($host.ip)", "vlan=\($host.vlan.id // 0)" else empty end),
          (if $host.mac.address then "mac=\($host.mac.address)" else empty end),
          (if ($data | type) == "object" and ($data.asn // 0) > 0 then "asn=\($data.asn)" else empty end),
          (if $flow then "flow_key=\($flow.key)", "flow_hash_id=\($flow.hash_id)" else empty end),
          # The pcap traffic is in the past: the time range of its flows
          (if $flow then "epoch_begin=\($flow.first_seen - 60)", "epoch_end=\($flow.last_seen + 60)"
           else "epoch_begin=\($now - 3600)", "epoch_end=\($now)" end)
        ] | join("&")'
}
ADMIN_PARAMS=$(real_params)

# Extra params of single endpoints, appended to PARAMS
declare -A EXTRA_PARAMS=(
    # The capture lasts 60 s by default, longer than the curl timeout
    [/lua/rest/v2/get/pcap/live_traffic.lua]="&duration=5"
)

# $1 = who (admin|user|anon), $2 = path: the URL called, as shown in the report
query() {
    local params="${PARAMS}"
    [ "${1}" = admin ] && params="${ADMIN_PARAMS}"
    echo "${2}?${params}${EXTRA_PARAMS[${2}]}"
}

# Unprivileged user, no capabilities, all interfaces (test instance only)
[ -z "${LIVE}" ] && curl -s -u "${ADMIN}" -d username=smoke -d full_name=smoke -d "password=${USER_PW}" -d "confirm_password=${USER_PW}" \
    -d user_role=unprivileged -d allowed_networks=0.0.0.0/0,::/0 -d allowed_interface= -d add_user_language=en \
    "${B}/lua/rest/v2/add/ntopng/user.lua" > /dev/null

# Seconds for an answer: the exports (download in the path) send every row
answer_timeout() { [[ "${1}" == *download* ]] && echo 300 || echo 20; }

# $1 = who (admin|user|anon), $2 = path. Sets HTTP, CTYPE, BODY_FILE and
# STOPPED (ntopng no longer answers); logs a FAIL for errors in the ntopng log
call() {
    local off auth="" new_log
    case "${1}" in
        admin) auth="-u ${ADMIN}" ;;
        user)  auth="-u smoke:${USER_PW}" ;;
    esac
    off=$(stat -c %s "${SMOKE_LOG}" 2> /dev/null || echo 0)
    BODY_FILE="${TMP}/body"
    IFS='|' read -r HTTP CTYPE REDIRECT CURL_RC < <(curl -s ${auth} --max-time "$(answer_timeout "${2}")" -o "${BODY_FILE}" -w '%{http_code}|%{content_type}|%{redirect_url}|' "${B}$(query "${1}" "${2}")"; echo $?)
    if [ "${HTTP}" = "000" ] && [ "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${B}/")" = "000" ]; then
        fail "$(query "${1}" "${2}")" "$(who "${1}"): ntopng stopped answering after this call (crash or exit), see the end of ${SMOKE_LOG}"
        STOPPED=1
    fi
    new_log=$([ -n "${SMOKE_LOG}" ] && tail -c +$((off + 1)) "${SMOKE_LOG}" | grep -E 'ERROR:|WARNING:' | head -1 | sed 's/^.*\(ERROR\|WARNING\): //')
    [ -n "${new_log}" ] && fail "$(query "${1}" "${2}")" "$(who "${1}"): ntopng log: ${new_log}"
}

who() {
    case "${1}" in
        user) echo "user without capabilities" ;;
        anon) echo "anonymous" ;;
        *)    echo "${1}" ;;
    esac
}

# rc_str of the JSON answer, empty if not JSON
rc_str() { jq -r '.rc_str // empty' "${BODY_FILE}" 2> /dev/null; }

# denied | allowed, for the unprivileged user and the anonymous caller
outcome() {
    case "${HTTP}" in
        401|403) echo denied; return ;;
        # A script error also redirects (to the error page): only the login is a denial
        302) [[ "${REDIRECT}" == *login* ]] && { echo denied; return; } ;;
    esac
    [ "$(rc_str)" = "NOT_GRANTED" ] && echo denied || echo allowed
}

fail() { printf 'FAIL  %s\n      %s\n' "${1}" "${2}" >> "${FAILS}"; }

TOTAL=0
cd "${NTOPNG_ROOT_ABS}" || exit 1
for f in $(find scripts/lua/rest/v2 pro/scripts/lua/rest/v2 -name '*.lua' 2> /dev/null | sort); do
    path="/lua/${f#scripts/lua/}"
    path="${path/#\/lua\/pro\/scripts\/lua\//\/lua\/pro\/}"
    [ -n "${SMOKE_ONLY}" ] && ! [[ "${path}" =~ ${SMOKE_ONLY} ]] && continue
    [ -n "${LIVE}" ] && [[ "${path}" =~ ${LIVE_SKIP} ]] && continue
    TOTAL=$((TOTAL + 1))

    # Admin: read endpoints only, write ones would change the instance under test
    case "${path}" in
        */rest/v2/get/*|*/rest/v2/export/*)
            call admin "${path}"
            [ -n "${STOPPED}" ] && break
            rc=$(rc_str)
            if [ "${HTTP}" = "000" ] || [ "${CURL_RC}" = "28" ]; then
                fail "$(query admin "${path}")" "admin: no complete answer within $(answer_timeout "${path}") s (HTTP ${HTTP})"
            elif [ "${HTTP}" -ge 500 ] && { [ -z "${rc}" ] || [ "${rc}" = "INTERNAL_ERROR" ]; }; then
                # A declared REST error (e.g. 503 IFACE_ENCRYPTION_NOT_PRESENT) is a valid answer
                fail "$(query admin "${path}")" "admin: HTTP ${HTTP}${rc:+ (${rc})}"
            elif grep -q 'HTTP/1\.[01] [0-9]' "${BODY_FILE}"; then
                fail "$(query admin "${path}")" "admin: two answers in one response (missing 'return' after rest_utils.answer?): $(head -c 120 "${BODY_FILE}" | tr -s "\r\n" " ")"
            elif [[ "${CTYPE}" == *json* ]] && ! jq -e . "${BODY_FILE}" > /dev/null 2>&1; then
                fail "$(query admin "${path}")" "admin: invalid JSON: $(head -c 120 "${BODY_FILE}" | tr -s "\r\n" " ")"
            elif [ "${rc}" = "INTERNAL_ERROR" ]; then
                fail "$(query admin "${path}")" "admin: rc_str=INTERNAL_ERROR"
            fi
            ;;
    esac

    [ -n "${LIVE}" ] && continue
    for role in user anon; do
        call "${role}" "${path}"
        [ -n "${STOPPED}" ] && break 2
        echo "${role} $(outcome) ${path}" >> "${OUTCOMES}"
    done
done

sort -k3,3 -k1,1 -o "${OUTCOMES}" "${OUTCOMES}"

# Permission changes against the baseline (skipped if ntopng stopped: the
# outcomes are partial)
if [ -z "${LIVE}" ] && [ -f "${BASELINE}" ] && [ -z "${STOPPED}" ]; then
    # Lines: role baseline_outcome current_outcome path
    join -j1 -a2 -e none -o 0,1.2,2.2 \
        <(awk '{print $3"|"$1, $2}' "${BASELINE}" | sort) \
        <(awk '{print $3"|"$1, $2}' "${OUTCOMES}" | sort) |
    while read -r key old new; do
        [ "${old}" = "${new}" ] && continue
        role="${key#*|}"; path="${key%|*}"
        if [ "${old}" = "none" ]; then
            fail "$(query "${role}" "${path}")" "$(who "${role}"): new endpoint, outcome '${new}' (check it, then ./smoke.sh -u)"
        else
            fail "$(query "${role}" "${path}")" "$(who "${role}"): was ${old}, now ${new}"
        fi
    done
fi
# Never save a partial run (ntopng stopped, or SMOKE_ONLY)
[ -z "${LIVE}" ] && [ -z "${STOPPED}" ] && [ -z "${SMOKE_ONLY}" ] && { [ ! -f "${BASELINE}" ] || [ "${SMOKE_UPDATE_BASELINE}" = "1" ]; } && cp "${OUTCOMES}" "${BASELINE}" && BASELINE_SAVED=1

{
    cat "${FAILS}"
    [ -n "${BASELINE_SAVED}" ] && echo "[i] Baseline saved to smoke-baseline.txt: review it and commit it"
    echo "[i] Admin params: ${ADMIN_PARAMS}"
    echo "ENDPOINTS ${TOTAL}   FAIL $(grep -c '^FAIL' "${FAILS}")"
} > "${SMOKE_REPORT}"

rm -rf "${TMP}"

if [ -n "${LIVE}" ]; then
    cat "${SMOKE_REPORT}"
    grep -q '^FAIL' "${SMOKE_REPORT}" && exit 1
    exit 0
fi

# ntopng shuts down once this script returns: a request still running (e.g.
# a never ending one) can hang it, the watchdog reports it and stops ntopng
# The pid is read now: the pid file is reused by the next run
pid=$(cat "${SMOKE_PID_FILE}" 2> /dev/null)
(
    for i in $(seq 60); do
        kill -0 "${pid}" 2> /dev/null || exit 0
        sleep 1
    done
    if [ -n "${pid}" ] && kill -0 "${pid}" 2> /dev/null; then
        printf 'FAIL  ntopng shutdown\n      ntopng did not stop within 60 s after the last call (a request still running?), killed\n' >> "${SMOKE_REPORT}"
        kill -9 "${pid}"
    fi
) > /dev/null 2>&1 &
