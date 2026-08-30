#!/bin/bash
#
# Shared configuration and helpers for the ntopng REST e2e tests.
#
# Sourced by:
#   run.sh      - argument parsing, orchestration, result aggregation
#   run-one.sh  - execution of a single test on a given resource slot
#
# Nothing here is meant to be executed directly.
#

# These are normally exported by run.sh; keep sane defaults so that
# run-one.sh can also be launched by hand for debugging.
TESTS_PATH="${TESTS_PATH:-${PWD}}"
NTOPNG_ROOT="${NTOPNG_ROOT:-../../..}"
NTOPNG_BIN="${NTOPNG_BIN:-./ntopng}"

RUN_FROM_PACKAGES="${RUN_FROM_PACKAGES:-false}"
DEBUG_LEVEL="${DEBUG_LEVEL:-0}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"

DEFAULT_PCAP="test_01.pcap"

NOTIFICATIONS_ON="${NOTIFICATIONS_ON:-false}"
if [ -d ${HOME}/packager ]; then
    source ${HOME}/packager/utils/alerts.sh
    NOTIFICATIONS_ON=true
fi

#
# Compute the set of resources used by a test worker.
#
# Slot 0 keeps the historical single-instance layout, so that the default
# (sequential) run is behaviourally identical to the previous script.
# Slots >= 1 get an isolated HTTP port, Redis DB, data dir, pid file and
# ClickHouse DB, so that several workers can run in parallel without clashing.
#
# Params:
# $1 - slot number (0 = sequential, >= 1 = parallel worker)
#
ntopng_slot_setup() {
    local slot="${1:-0}"

    if [ "${slot}" -le 0 ]; then
        NTOPNG_TEST_DATADIR="${TESTS_PATH}/data"
        NTOPNG_TEST_REDIS="2"
        NTOPNG_TEST_HTTP_PORT="3333"
        NTOPNG_TEST_DB="ntopngtests"
        NTOPNG_TEST_INSTANCE="ntopng_test"
        NTOPNG_TEST_PID="./ntopng.pid"
        NTOPNG_TEST_PARALLEL=0
    else
        NTOPNG_TEST_DATADIR="${TESTS_PATH}/data/slot-${slot}"
        NTOPNG_TEST_REDIS="$((1 + slot))"
        NTOPNG_TEST_HTTP_PORT="$((3300 + slot))"
        NTOPNG_TEST_DB="ntopngtests_${slot}"
        NTOPNG_TEST_INSTANCE="ntopng_test_${slot}"
        NTOPNG_TEST_PID="./ntopng.slot-${slot}.pid"
        NTOPNG_TEST_PARALLEL=1
    fi

    NTOPNG_TEST_CONF="${NTOPNG_TEST_DATADIR}/ntopng.conf"
    NTOPNG_TEST_CUSTOM_PROTOS="${NTOPNG_TEST_DATADIR}/protos.txt"
}

# Make defaults available to code that sources this file without a slot
ntopng_slot_setup 0

# Send a success alert
function send_success {
    TITLE="${1}"
    MESSAGE="${2}"

    if [ "${NOTIFICATIONS_ON}" = true ]; then
        sendSuccess "${TITLE}" "${MESSAGE}" ""
    else
        echo "[i] ${TITLE}: ${MESSAGE}"
    fi
}

# Send an error alert
function send_error {
    TITLE="${1}"
    MESSAGE="${2}"
    FILE_PATH="${3}"

    if [ "${NOTIFICATIONS_ON}" = true ]; then
        if [ ! -z "${FILE_PATH}" ]; then
            TITLE="${TITLE}: ${MESSAGE}"
        fi

        sendError "${TITLE}" "${MESSAGE}" "${FILE_PATH}"
    else
        echo "[!] ${TITLE}: ${MESSAGE}"

        if [ ! -z "${FILE_PATH}" ]; then
            cat "${FILE_PATH}"
        fi
    fi
}

check_connectivity() {
    URL="https://packages.ntop.org"
    CURL_FAIL_CODE=6
    CURL_LOG=$(mktemp)

    curl -ksSf "${URL}" > ${CURL_LOG} 2>&1

    if [ ! $? = ${CURL_FAIL_CODE} ]; then
        echo "[i] Connectivity ok"
    else
        send_error "Unable to run tests" "No connectivity, unable to run the tests" "${CURL_LOG}"
        exit 1
    fi

    if [ "${KEEP_RUNNING}" -eq "1" ]; then
        echo "[i] ntopng is reachable on port ${NTOPNG_TEST_HTTP_PORT}"
    fi
}

ntopng_cleanup() {
    # Make sure no other process is running
    if [ "${NTOPNG_TEST_PARALLEL}" -eq "1" ]; then
        # Only terminate this slot's ntopng, never a sibling worker's
        if [ -f "${NTOPNG_ROOT}/${NTOPNG_TEST_PID}" ]; then
            kill -9 "$(cat "${NTOPNG_ROOT}/${NTOPNG_TEST_PID}")" > /dev/null 2>&1 || true
            rm -f "${NTOPNG_ROOT}/${NTOPNG_TEST_PID}"
        fi
        pkill -9 -f "${NTOPNG_TEST_CONF}" > /dev/null 2>&1 || true
    else
        killall -9 ntopng > /dev/null 2>&1 || true
    fi

    # Cleanup old test stuff
    redis-cli -n "${NTOPNG_TEST_REDIS}" "flushdb" > /dev/null 2>&1
    rm -rf "${NTOPNG_TEST_DATADIR}"

    # Cleanup database if any
    if command -v clickhouse-client &> /dev/null; then
        clickhouse-client -q "DROP database IF EXISTS ${NTOPNG_TEST_DB}"
    fi
}

ntopng_init_conf() {
    # Prepare a custom protocols file to also check for custom protocols
    mkdir -p "${NTOPNG_TEST_DATADIR}"

    echo "-d=${NTOPNG_TEST_DATADIR}" > ${NTOPNG_TEST_CONF}
    echo "-r=@${NTOPNG_TEST_REDIS}" >> ${NTOPNG_TEST_CONF}
    echo "-p=${NTOPNG_TEST_CUSTOM_PROTOS}" >> ${NTOPNG_TEST_CONF}
    echo "-N=${NTOPNG_TEST_INSTANCE}" >> ${NTOPNG_TEST_CONF}
    echo "--http-port=${NTOPNG_TEST_HTTP_PORT}" >> ${NTOPNG_TEST_CONF}
    if [ "${NTOPNG_TEST_PARALLEL}" -eq "1" ]; then
        # Keep the default HTTPS port (3001) from clashing across workers
        echo "--https-port=0" >> ${NTOPNG_TEST_CONF}
    fi
    if [ "${KEEP_RUNNING}" -eq "0" ]; then
        echo "--shutdown-when-done" >> ${NTOPNG_TEST_CONF}
    fi
    echo "--disable-login=1" >> ${NTOPNG_TEST_CONF}
    echo "--dont-change-user" >> ${NTOPNG_TEST_CONF}
    echo "--pid=${NTOPNG_TEST_PID}" >> ${NTOPNG_TEST_CONF}
    echo "--dns-mode=2" >> ${NTOPNG_TEST_CONF}

    cat <<EOF >> "${NTOPNG_TEST_CUSTOM_PROTOS}"
# charles
host:"charles"@Charles

# sebastian
host:"sebastian"@Sebastian

# lando
host:"lando"@Lando
EOF
}

#
# Run ntopng
# Params:
# $1 - Pcap files (Optional)
# $2 - Pre Script (Optional)
# $3 - Runtime Script (Optional)
# $4 - Post Script (Optional)
# $5 - Script Output file
# $6 - ntopng Output file
# $7 - Local networks
# $8 - Extra options file
#
ntopng_run() {
    if [ ! -z "${1}" ]; then
        # TODO handle folder with multiple PCAPs
        echo "-i=${TESTS_PATH}/pcap/${PCAP}" >> ${NTOPNG_TEST_CONF}
    else
        # Default PCAP
        echo "-i=${TESTS_PATH}/pcap/${DEFAULT_PCAP}" >> ${NTOPNG_TEST_CONF}
    fi

    if [ ! -z "${2}" ]; then
        if [ "${DEBUG_LEVEL}" -gt "0" ]; then
            echo "[D] Pre-script:"
            cat ${2}
        fi

        echo "--test-script-pre=bash ${2} >> ${5}" >> ${NTOPNG_TEST_CONF}
    fi

    if [ ! -z "${3}" ]; then
        if [ "${DEBUG_LEVEL}" -gt "0" ]; then
            echo "[D] Runtime-script:"
            cat ${3}
        fi

        echo "--test-script=bash ${3} >> ${5}" >> ${NTOPNG_TEST_CONF}
    fi

    if [ ! -z "${4}" ]; then
        if [ "${DEBUG_LEVEL}" -gt "0" ]; then
            echo "[D] Post-script:"
            cat ${4}
        fi

        echo "--test-script-post=bash ${4} >> ${5}" >> ${NTOPNG_TEST_CONF}
    fi

    if [ ! -z "${7}" ]; then
        echo "-m=${7}" >> ${NTOPNG_TEST_CONF}
    fi

    if [ ! -z "${8}" ]; then
        cat "${8}" >> ${NTOPNG_TEST_CONF}
    fi

    # Start the test

    cd ${NTOPNG_ROOT};

    touch ${6}
    if [ "${DEBUG_LEVEL}" -gt "0" ]; then

        echo "[D] Configuration:"
        cat ${NTOPNG_TEST_CONF}

        ${NTOPNG_BIN} ${NTOPNG_TEST_CONF}
    else
        ${NTOPNG_BIN} ${NTOPNG_TEST_CONF} > ${6} 2>&1
    fi

    cd ${TESTS_PATH}
}

#
# Filter ntopng log
# Params:
# $1 - ntopng raw output file
# $2 - Filtered output file
#
filter_ntopng_log() {

    # Move to the ntopng folder to run addr2line
    cd ${NTOPNG_ROOT};

    # Filter log
    cat ${1} | grep -i "ERROR:\|WARNING:\|Direct leak\|    #" > ${2}.stage1

    # Process filtered log
    touch ${2}
    while IFS= read -r line; do
        if [[ ${line} == *"    #"* ]] && [[ ${line} == *" 0x"* ]]; then
            echo "${line}" | awk '{print $2}' | xargs addr2line -e ntopng >> ${2}
        else
            echo "${line}" >> ${2}
        fi
    done <${2}.stage1
    rm -f ${2}.stage1

    # Move log
    mv ${1} ${1}.stage1

    # Process raw log
    touch ${1}
    while IFS= read -r line; do
        if [[ ${line} == *"    #"* ]] && [[ ${line} == *" 0x"* ]]; then
            echo "${line}" | awk '{print $2}' | xargs addr2line -e ntopng >> ${1}
        else
            echo "${line}" >> ${1}
        fi
    done <${1}.stage1
    rm -f ${1}.stage1

    cd ${TESTS_PATH}
}

#
# Filter test output (JSON) to remove fields that can change
# Params:
# $1 - JSON file
# $2 - File with items to be ignores
#
filter_json() {
    TMP=${1}.1

    # Filter out fields in the 'ignore' section of the conf file
    if [ -s "${2}" ]; then
        cat ${1} | grep -v -f "${IGNORE}" > ${TMP}
        cat ${TMP} > ${1}
        /bin/rm -f ${TMP}
    fi

    # Filter out timestamps (1621612265) and duration (17:51:05)
    cat ${1} | grep -v "\"value\": [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]" | grep -v "\"label\": \"[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\"" > ${TMP}
    cat ${TMP} > ${1}
    /bin/rm -f ${TMP}
}

#
# Filter test output (CSV) to remove fields that can change
# Params:
# $1 - CSV file
# $2 - File with items to be ignores
#
filter_csv() {
    TMP=${1}.1

    # Filter out information unnecessary for comparison
    if [ -s "${2}" ]; then
        while read p; do
            cutting_value=$(head -n 1 ${1} | tr "|" " " | awk -v search="$p" '{ for(i=1; i<=NF; i++) if($i == search) print i }')
            cat ${TMP} | cut -d '|' --complement --fields=$cutting_value > ${TMP}
        done < "${IGNORE}"
    fi

    cat ${TMP} > ${1}

    /bin/rm -f ${TMP}
}
