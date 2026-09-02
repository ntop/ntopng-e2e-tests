#!/bin/bash
#
# Running this script without parameters, all tests in the tests folder will be executed.
#
# ./run.sh
#
# In order to run a specific test, provide the name of the test with the -y option.
#
# ./run.sh -y=get_host_active_01
#
# By default tests run sequentially (one ntopng instance at a time). Pass -j=<N>
# to run up to N tests concurrently, each on its own isolated set of resources
# (HTTP port, Redis DB, data dir, ...). This requires GNU parallel.
#
# ./run.sh -j=8
#
# Clone the packager repository in the same folder to enable notifications
#

TESTS_PATH="${PWD}"
NTOPNG_ROOT="../../.."
NTOPNG_BIN="./ntopng"

DEFAULT_PCAP="test_01.pcap"

MAIL_FROM=""
MAIL_TO=""
DISCORD_WEBHOOK=""
TEST_NAME=""
API_VERSION=""

RUN_FROM_PACKAGES=false
DEBUG_LEVEL=0
KEEP_RUNNING=0
JOBS=1

# Redis ships with 16 logical DBs; parallel slots use DB 2..(1+JOBS)
MAX_JOBS=14

source "${TESTS_PATH}/common.sh"

function usage {
    echo "Usage: run.sh [-y=<test>] [-j=<jobs>] [-f=<mail from>] [-t=<mail to>] [-d=<discord webhook>] [-D=<debug level>] [-K]"
    echo ""
    echo "Options:"
    echo "[-y|--test]=<test>                | Run a selected test (e.g. -y=v2/get_host_active_01)"
    echo "[-v|--api-version]=<version>      | Run a test for the specified Rest API Version (1|2)"
    echo "[-j|--jobs]=<jobs>                | Run <jobs> tests in parallel (default 1, max ${MAX_JOBS}, needs GNU parallel)"
    echo "[-f|--mail-from]=<address>        | Send notifications from the specified email address"
    echo "[-t|--mail-to]=<address>          | Send notifications to the specified email address"
    echo "[-d|--discord-webhook]=<endpoint> | Send notification to the specified Discord endpoint"
    echo "[-p|--use-package]                | Run ntopng from binary package"
    echo "[-D|--debug]=<level>              | Set the debug level (0 - default, 1 - verbose, 2 - gdb)"
    echo "[-K|--keep-running]               | Keep ntopng running after completing the test (with -y)"
    echo "[-h|--help]                       | Print this help"
    exit 0
}

for i in "$@"
do
    case $i in
        -f=*|--mail-from=*)
            MAIL_FROM="${i#*=}"
            ;;

        -t=*|--mail-to=*)
            MAIL_TO="${i#*=}"
            ;;

        -d=*|--discord-webhook=*)
            DISCORD_WEBHOOK="${i#*=}"
            ;;

        -y=*|--test=*)
            TEST_NAME="${i#*=}"
            ;;

	-p|--use-package)
	    RUN_FROM_PACKAGES=true
	    ;;

        -v=*|--api-version=*)
            API_VERSION="${i#*=}"
            ;;

        -j=*|--jobs=*)
            JOBS="${i#*=}"
            ;;

        -D=*|--debug=*)
            DEBUG_LEVEL=${i#*=}
            ;;

        -K|--keep-running)
            KEEP_RUNNING=1
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            # unknown option
            ;;
    esac
done

if ! command -v shyaml &> /dev/null; then
    echo "Please install shyaml (pip install shyaml)"
    exit 0
fi

if ! command -v curl &> /dev/null; then
    echo "Please install curl"
    exit 0
fi

if ! command -v jq &> /dev/null; then
    echo "Please install jq"
    exit 0
fi

if [ "${NOTIFICATIONS_ON}" = true ]; then
    if [ -z "$MAIL_FROM" ] || [ -z "$MAIL_TO" ] ; then
        echo "Warning: please specify -f=<from> -t=<to> to send alerts by mail"
    fi

    if [ -z "$DISCORD_WEBHOOK" ] ; then
        echo "Warning: please specify -d=<discord webhook url> to send alerts to Discord"
    fi
fi

if [ "${DEBUG_LEVEL}" -eq "2" ]; then
    NTOPNG_BIN="gdb --tui --args ${NTOPNG_BIN}"
fi

# Validate the requested parallelism level
if ! [[ "${JOBS}" =~ ^[0-9]+$ ]] || [ "${JOBS}" -lt "1" ]; then
    echo "Error: -j must be a positive integer"
    exit 1
fi

if [ "${JOBS}" -gt "${MAX_JOBS}" ]; then
    echo "Error: -j cannot exceed ${MAX_JOBS} (Redis provides only 16 logical DBs;"
    echo "       parallel slots use DB 2..$((1 + JOBS)))"
    exit 1
fi

if [ "${JOBS}" -gt "1" ]; then
    if ! parallel --version 2> /dev/null | grep -qi "^GNU parallel"; then
        echo "Error: GNU parallel is required to run tests in parallel (-j)"
        exit 1
    fi

    if [ ! -z "${TEST_NAME}" ]; then
        echo "[i] Ignoring -j: running a single test (-y)"
        JOBS=1
    elif [ "${KEEP_RUNNING}" -eq "1" ] || [ "${DEBUG_LEVEL}" -ge "1" ]; then
        echo "[i] Ignoring -j: not compatible with -K / -D"
        JOBS=1
    fi
fi

RC=0

#
# Order tests by input pcap size (descending); tests with an explicit 'sleep'
# in their scripts are pushed to the very front. This way the slowest tests
# start first and no long-pole test is left running alone at the end.
# Params:
# $1 - List of tests
#
prioritize_tests() {
    local T PCAP SZ
    for T in ${1}; do
        PCAP=$(grep -m1 '^input:' "tests/${T}" 2> /dev/null | awk '{print $2}')
        [ -z "${PCAP}" ] && PCAP="${DEFAULT_PCAP}"
        SZ=$(stat -c '%s' "pcap/${PCAP}" 2> /dev/null || echo 0)
        if grep -qE '^[[:space:]]*sleep ' "tests/${T}" 2> /dev/null; then
            SZ=$((SZ + 1000000000))
        fi
        printf '%s\t%s\n' "${SZ}" "${T}"
    done | sort -rn | cut -f2
}

#
# Run a batch of tests sequentially (historical behaviour, resource slot 0)
# Params:
# $1 - List of tests to run
# $2 - Number of tests
#
run_tests_sequential() {
    local TESTS="${1}"
    local NUM_TESTS="${2}"
    local I=1
    local EV

    for T in ${TESTS}; do
        PROGRESS="${I}/${NUM_TESTS}" bash "${TESTS_PATH}/run-one.sh" "${T}" 0
        EV=$?
        ((I=I+1))

        case "${EV}" in
            0) ((G_RAN=G_RAN+1)); ((G_SUCCESS=G_SUCCESS+1)) ;;
            2) ((G_SKIP=G_SKIP+1)) ;;
            *) ((G_RAN=G_RAN+1)); RC=1 ;;
        esac
    done
}

#
# Run a batch of tests in parallel, each worker on its own resource slot
# Params:
# $1 - List of tests to run
# $2 - Number of tests
#
run_tests_parallel() {
    local TESTS="${1}"
    local NUM_TESTS="${2}"
    local JOBLOG DB SEQ EV

    JOBLOG=$(mktemp)

    # One-shot global cleanup before spawning the workers
    killall -9 ntopng > /dev/null 2>&1 || true
    rm -rf "${TESTS_PATH}/data"
    for DB in $(seq 2 $((1 + JOBS))); do
        redis-cli -n "${DB}" "flushdb" > /dev/null 2>&1
    done

    echo "[i] Running ${NUM_TESTS} tests with ${JOBS} parallel workers"

    # Start with the slowest tests
    TESTS=$(prioritize_tests "${TESTS}")

    # Each worker notifies its own failures (as in the sequential run).
    # --group (default) prints each test's whole output as one uninterleaved
    # block; --keep-order emits those blocks in test-start order.
    printf '%s\n' ${TESTS} | \
        parallel --will-cite --jobs "${JOBS}" --joblog "${JOBLOG}" \
                 --group --keep-order --tagstring '{/.}' \
                 bash "${TESTS_PATH}/run-one.sh" {} '{%}'

    # Aggregate outcomes from the job log (Exitval is column 7)
    while IFS=$'\t' read -r SEQ _ _ _ _ _ EV _; do
        [ "${SEQ}" = "Seq" ] && continue
        [ -z "${SEQ}" ] && continue
        case "${EV}" in
            0) ((G_RAN=G_RAN+1)); ((G_SUCCESS=G_SUCCESS+1)) ;;
            2) ((G_SKIP=G_SKIP+1)) ;;
            *) ((G_RAN=G_RAN+1)); RC=1 ;;
        esac
    done < "${JOBLOG}"

    /bin/rm -f "${JOBLOG}"
    /bin/rm -f "${NTOPNG_ROOT}"/ntopng.slot-*.pid
}

#
# Prepare the environment and dispatch a batch of tests
# Params:
# $1 - List of tests to run
#
run_tests() {
    local TESTS="${1}"
    local TESTS_ARR=( $TESTS )
    local NUM_TESTS=${#TESTS_ARR[@]}

    G_RAN=0
    G_SUCCESS=0
    G_SKIP=0

    # Check Internet connectivity
    check_connectivity

    # Use binary package if -p is set
    if [ "${RUN_FROM_PACKAGES}" = true ]; then
        NTOPNG_ROOT="."
        NTOPNG_BIN="ntopng"
    fi

    if [ "${RUN_FROM_PACKAGES}" = false ]; then
        if [ ! -f "${NTOPNG_ROOT}/ntopng" ]; then
            send_error "Unable to run tests" "ntopng binary not found, unable to run the tests"
            exit 1
        fi
    fi

    RESULTS_FOLDER=result
    CONFLICTS_FOLDER=conflicts
    if [ "${RUN_FROM_PACKAGES}" = false ]; then
        if [ ! -d ${NTOPNG_ROOT}/pro ]; then
            RESULTS_FOLDER=result-community
            CONFLICTS_FOLDER=conflicts-community
        fi
    fi

    # Everything the run-one.sh workers need to know
    export TESTS_PATH NTOPNG_ROOT NTOPNG_BIN RUN_FROM_PACKAGES DEBUG_LEVEL KEEP_RUNNING
    export RESULTS_FOLDER CONFLICTS_FOLDER
    export NOTIFICATIONS_ON MAIL_FROM MAIL_TO DISCORD_WEBHOOK

    if [ "${JOBS}" -le "1" ]; then
        run_tests_sequential "${TESTS}" "${NUM_TESTS}"
    else
        run_tests_parallel "${TESTS}" "${NUM_TESTS}"
    fi

    if [ "${G_SUCCESS}" == "${G_RAN}" ]; then
        send_success "ntopng TESTS completed successfully" "All tests completed successfully with the expected output."
    else
        send_error "ntopng TESTS completed with errors" "${G_SUCCESS} out of ${G_RAN} completed successfully." ""
    fi

    #ntopng_cleanup
}

if [ ! -z "${TEST_NAME}" ]; then
    run_tests "${TEST_NAME}.yaml"
elif [ ! -z "${API_VERSION}" ]; then
    TESTS=`cd tests; /bin/ls v${API_VERSION}/*.yaml`
    run_tests "${TESTS}"
else
    #TESTS=`cd tests; /bin/ls {v1,v2}/*.yaml`
    TESTS=`cd tests; /bin/ls v2/*.yaml`
    run_tests "${TESTS}"
fi

exit $RC
