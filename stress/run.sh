#!/bin/bash
#
# Stress test of ntopng with live NetFlow traffic, meant for a build with the
# sanitizers (./configure --with-leak-sanitizer): memory errors, leaks,
# crashes and memory growth while hosts and flows are created and purged all
# the time and the REST endpoints and GUI pages read them.
#
#   sendPcap (NetFlow pcap in a loop) -> nProbe (-3 collector) -> ZMQ -> ntopng
#
# ntopng runs on its own slot with one ZMQ collector interface,
# --simulate-vlans (random VLAN per flow: the same pcap gives many more
# hosts and flows), short idle timeouts (more purges) and low host/flow
# limits (the "hash full" path, and less memory under ASan). For
# STRESS_MINUTES the REST smoke check (live mode, STRESS_REST_WORKERS copies
# in parallel) and the GUI smoke check (live mode) run in a loop and the RSS
# of ntopng is sampled. Then ntopng is stopped with SIGTERM.
#
# Fails on: a sanitizer report (AddressSanitizer, LeakSanitizer, UBSan), a
# crash, a shutdown not completed within STRESS_SHUTDOWN_TIMEOUT, a FAIL of
# the smoke checks, an RSS growth over STRESS_RSS_GROWTH % after the warm-up.
#
# Requirements: nProbe and sendPcap (nProbe/utils), a NetFlow pcap, Redis,
# jq, 'npm install' in ../gui (GUI check).
#
# Usage: STRESS_PCAP=<NetFlow pcap> [NPROBE=<nprobe>] [SENDPCAP=<sendPcap>]
#        [STRESS_MINUTES=60] [STRESS_PPS=200] [STRESS_REST_WORKERS=4]
#        [STRESS_RSS_GROWTH=20] [STRESS_SHUTDOWN_TIMEOUT=300]
#        [STRESS_LOG_IGNORE=<regex of the expected log lines>] ./run.sh
#   nProbe validates its license only as root: NPROBE="sudo /path/nprobe"
#   when the test does not run as root.
#   The ntopng tested is the one of NTOPNG_ROOT (default ../../..). For the
#   sanitizer reports with file and line:
#   ASAN_OPTIONS=detect_leaks=1 ASAN_SYMBOLIZER_PATH=<llvm-symbolizer>
# Report: logs/stress-report.txt (also printed). Exit code: 0 ok, 1 failures.
#

cd "$(dirname "$0")" || exit 1
STRESS_PATH="${PWD}"
export TESTS_PATH="$(cd ../rest && pwd)"
export NTOPNG_ROOT="$(cd "${NTOPNG_ROOT:-../../..}" && pwd)"
source "${TESTS_PATH}/common.sh"

NPROBE="${NPROBE:-nprobe}"
SENDPCAP="${SENDPCAP:-sendPcap}"
MINUTES="${STRESS_MINUTES:-60}"
PPS="${STRESS_PPS:-200}"
REST_WORKERS="${STRESS_REST_WORKERS:-4}"
RSS_GROWTH="${STRESS_RSS_GROWTH:-20}"
SHUTDOWN_TIMEOUT="${STRESS_SHUTDOWN_TIMEOUT:-300}"
# Own slot (Redis DB slot + 1, at most 15): 13 and 14 are the smoke tests, 1-N the parallel workers
SLOT="${STRESS_SLOT:-12}"
# Log lines expected under this traffic: a host taken from the instance at the start
# of a loop can be purged (10 s idle) before an endpoint asks for it
LOG_IGNORE="${STRESS_LOG_IGNORE:-Unable to locate host}"
# Seconds between two RSS samples, and samples left out at the start (warm-up)
RSS_PERIOD=30
RSS_WARMUP=10

LOGS="${STRESS_PATH}/logs"
REPORT="${LOGS}/stress-report.txt"
NTOPNG_LOG="${LOGS}/stress-ntopng.log"
RSS_LOG="${LOGS}/stress-rss.txt"
mkdir -p "${LOGS}"
rm -f "${LOGS}"/stress-* "${LOGS}"/rest-*.txt
FAILS=""
fail() { FAILS+="FAIL  ${1}"$'\n'; }

# NPROBE can have a prefix, e.g. "sudo /path/nprobe" (the license check needs root)
for tool in "${NPROBE##* }" "${SENDPCAP}" jq redis-cli; do
    command -v "${tool}" > /dev/null || fail "setup: ${tool} not found"
done
[ -f "${STRESS_PCAP}" ] || fail "setup: STRESS_PCAP is not a pcap file: '${STRESS_PCAP}'"
if [ -n "${FAILS}" ]; then
    printf '%s' "${FAILS}" | tee "${REPORT}"
    exit 1
fi

ntopng_slot_setup "${SLOT}"
NTOPNG_TEST_LOGIN=true
KEEP_RUNNING=1
UDP_PORT=$((2100 + SLOT))
ZMQ_PORT=$((10400 + SLOT))
BASE_URL="http://localhost:${NTOPNG_TEST_HTTP_PORT}"

ntopng_cleanup
# Another instance on the ports would answer in place of the one under test
if ss -ltn | grep -qE ":(${NTOPNG_TEST_HTTP_PORT}|${ZMQ_PORT}) "; then
    echo "FAIL  setup: port ${NTOPNG_TEST_HTTP_PORT} or ${ZMQ_PORT} already in use (another ntopng? see STRESS_SLOT)" | tee "${REPORT}"
    exit 1
fi
ntopng_init_conf
cat >> "${NTOPNG_TEST_CONF}" <<EOF
-i=tcp://*:${ZMQ_PORT}c
-m=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
-x=5000
-X=20000
--simulate-vlans
EOF
# ClickHouse when available, as in production: the historical endpoints and
# the flow dump thread under traffic (the database of the slot, dropped by ntopng_cleanup)
CLICKHOUSE=false
if command -v clickhouse-client > /dev/null && clickhouse-client -q "SELECT 1" > /dev/null 2>&1; then
    CLICKHOUSE=true
    echo "-F=clickhouse;127.0.0.1;${NTOPNG_TEST_DB};default;;${NTOPNG_TEST_DB}_ro;${NTOPNG_TEST_DB}_ro" >> "${NTOPNG_TEST_CONF}"
fi
redis-cli -n "${NTOPNG_TEST_REDIS}" mset ntopng.prefs.local_host_max_idle 10 \
    ntopng.prefs.non_local_host_max_idle 10 ntopng.prefs.flow_max_idle 10 > /dev/null

PIDS=()
stop_all() {
    for pid in "${PIDS[@]}"; do kill "${pid}" 2> /dev/null; done
}
trap stop_all EXIT

(cd "${NTOPNG_ROOT}" && exec ${NTOPNG_BIN} "${NTOPNG_TEST_CONF}") > "${NTOPNG_LOG}" 2>&1 &
NTOPNG_PID=$!
# Ready when the REST answers: while starting, ntopng serves an HTML "starting" page
IFID=""
for _ in $(seq 1 120); do
    IFID=$(curl -s -u "admin:${NTOPNG_TEST_ADMIN_PASSWORD}" "${BASE_URL}/lua/rest/v2/get/ntopng/interfaces.lua" 2> /dev/null |
        jq -r '.rsp[0].ifid // empty' 2> /dev/null)
    [ -n "${IFID}" ] && break
    kill -0 "${NTOPNG_PID}" 2> /dev/null || break
    sleep 2
done
if [ -z "${IFID}" ]; then
    kill -KILL "${NTOPNG_PID}" 2> /dev/null
    { echo "FAIL  ntopng did not start, end of ${NTOPNG_LOG}:"; tail -20 "${NTOPNG_LOG}" | sed 's/^/      /'; } | tee "${REPORT}"
    exit 1
fi

# From its own folder, as when started by hand (it looks for ./plugins)
NPROBE_DIR="$(dirname "$(command -v "${NPROBE##* }")")"
(cd "${NPROBE_DIR}" && exec ${NPROBE} -i none -3 "${UDP_PORT}" --zmq "tcp://localhost:${ZMQ_PORT}" --zmq-probe-mode -n none -t 10) \
    > "${LOGS}/stress-nprobe.log" 2>&1 &
PIDS+=($!)
"${SENDPCAP}" -i "${STRESS_PCAP}" -p "${UDP_PORT}" -l -t "${PPS}" > /dev/null 2>&1 &
PIDS+=($!)

# No flows within a minute (e.g. nProbe stopped on its license): the test would run on nothing
for _ in $(seq 1 30); do
    FLOWS=$(curl -s -u "admin:${NTOPNG_TEST_ADMIN_PASSWORD}" "${BASE_URL}/lua/rest/v2/get/interface/data.lua?ifid=${IFID}" |
        jq -r '.rsp.num_flows // 0' 2> /dev/null)
    [ "${FLOWS:-0}" -gt 0 ] && break
    sleep 2
done
if [ "${FLOWS:-0}" -eq 0 ]; then
    { echo "FAIL  setup: no flows from nProbe within 60 s, end of ${LOGS}/stress-nprobe.log:"; tail -5 "${LOGS}/stress-nprobe.log" | sed 's/^/      /'; } | tee "${REPORT}"
    kill -KILL "${NTOPNG_PID}"
    ntopng_cleanup
    exit 1
fi
END=$(( $(date +%s) + MINUTES * 60 ))
LOOPS=0
SMOKE_FAILS=""
while [ "$(date +%s)" -lt "${END}" ] && kill -0 "${NTOPNG_PID}" 2> /dev/null; do
    LOOPS=$((LOOPS + 1))
    # RSS sampler for this loop, in the background
    (while kill -0 "${NTOPNG_PID}" 2> /dev/null; do
        echo "$(date +%s) $(ps -o rss= -p "${NTOPNG_PID}")" >> "${RSS_LOG}"
        sleep "${RSS_PERIOD}"
     done) &
    SAMPLER=$!
    WORKERS=()
    for worker in $(seq 1 "${REST_WORKERS}"); do
        # No SMOKE_LOG/NTOPNG_LOG: with calls in parallel a log line cannot be tied
        # to one of them, the log is checked once at the end
        SMOKE_URL="${BASE_URL}" NTOPNG_PASSWORD="${NTOPNG_TEST_ADMIN_PASSWORD}" SMOKE_IFID="${IFID}" \
            SMOKE_REPORT="${LOGS}/rest-${LOOPS}-${worker}.txt" \
            bash "${TESTS_PATH}/smoke-check.sh" > /dev/null 2>&1 &
        WORKERS+=($!)
    done
    NTOPNG_URL="${BASE_URL}" NTOPNG_PASSWORD="${NTOPNG_TEST_ADMIN_PASSWORD}" \
        GUI_SMOKE_PASSES=admin GUI_SMOKE_REPORT="${LOGS}/stress-gui-${LOOPS}.txt" \
        node "${STRESS_PATH}/../gui/smoke.mjs" > /dev/null 2>&1
    wait "${WORKERS[@]}"
    kill "${SAMPLER}" 2> /dev/null
    # A FAIL line (URL without its params: host and flow change at every loop) with
    # its first detail line: the same problem found at every loop is reported once
    SMOKE_FAILS+=$(awk '/^FAIL/ { failure = $0; sub(/\?[^ ]*/, "", failure); getline detail; print failure " --" detail }' \
        "${LOGS}"/rest-${LOOPS}-*.txt "${LOGS}/stress-gui-${LOOPS}.txt" 2> /dev/null)$'\n'
done
while read -r line; do
    [ -n "${line}" ] && fail "${line#FAIL  }"
done < <(sort -u <<< "${SMOKE_FAILS}")

stop_all
if kill -0 "${NTOPNG_PID}" 2> /dev/null; then
    kill -TERM "${NTOPNG_PID}"
    for _ in $(seq 1 "${SHUTDOWN_TIMEOUT}"); do
        kill -0 "${NTOPNG_PID}" 2> /dev/null || break
        sleep 1
    done
    if kill -0 "${NTOPNG_PID}" 2> /dev/null; then
        fail "ntopng did not shut down within ${SHUTDOWN_TIMEOUT} s of SIGTERM (killed)"
        kill -KILL "${NTOPNG_PID}"
    fi
    wait "${NTOPNG_PID}"
else
    wait "${NTOPNG_PID}"
    fail "ntopng stopped during the test (exit code $?, crash?), see the end of ${NTOPNG_LOG}"
fi
ntopng_cleanup

# Sanitizer reports, the ones at exit included
while read -r line; do
    FAILS+="${line}"$'\n'
done < <(sanitizer_fails "${NTOPNG_LOG}")

# Errors and warnings of the ntopng log, once each with their count (the most
# frequent first); the REST smoke test (one call at a time) tells the endpoint
while read -r count line; do
    fail "ntopng log (${count} times): ${line}"
done < <(grep -E "(ERROR|WARNING): " "${NTOPNG_LOG}" | grep -vE "Sanitizer|runtime error:|${LOG_IGNORE}" |
    sed -E 's/^[0-9]+\/[A-Za-z]+\/[0-9]+ [0-9:]+ //' | cut -c1-200 | sort | uniq -c | sort -rn | head -30)

# RSS growth: median of the last third of the samples against the first third,
# after the warm-up (the hash tables fill up first)
median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
mapfile -t RSS < <(tail -n +$((RSS_WARMUP + 1)) "${RSS_LOG}" 2> /dev/null | awk '$2 > 0 { print $2 }')
THIRD=$(( ${#RSS[@]} / 3 ))
if [ "${THIRD}" -ge 2 ]; then
    RSS_FIRST=$(printf '%s\n' "${RSS[@]:0:THIRD}" | median)
    RSS_LAST=$(printf '%s\n' "${RSS[@]: -THIRD}" | median)
    RSS_PCT=$(awk -v first="${RSS_FIRST}" -v last="${RSS_LAST}" 'BEGIN { printf "%.1f", (last - first) * 100 / first }')
    awk -v pct="${RSS_PCT}" -v max="${RSS_GROWTH}" 'BEGIN { exit !(pct > max) }' && \
        fail "RSS grew by ${RSS_PCT}% (${RSS_FIRST} -> ${RSS_LAST} KB, max ${RSS_GROWTH}%), samples in ${RSS_LOG}"
fi

{
    printf '%s' "${FAILS}"
    echo "[i] ntopng: ${NTOPNG_ROOT}/${NTOPNG_BIN#./}, ZMQ tcp://*:${ZMQ_PORT}c, slot ${SLOT}, ClickHouse ${CLICKHOUSE}, pcap ${STRESS_PCAP} at ${PPS} pps"
    echo "[i] RSS (KB, median of the first and of the last third after the warm-up): ${RSS_FIRST:-n/a} -> ${RSS_LAST:-n/a} (${RSS_PCT:-n/a}%)"
    echo "STRESS   MINUTES ${MINUTES}   LOOPS ${LOOPS}   FAIL $(grep -c '^FAIL' <<< "${FAILS}")"
} > "${REPORT}"

cat "${REPORT}"
grep -q '^FAIL' "${REPORT}" && exit 1
exit 0
