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
# Clone the packager repository in the same folder to enable notifications
#

TESTS_PATH="${PWD}"
NTOPNG_ROOT="../../.."
NTOPNG_BIN="./ntopng"

NTOPNG_TEST_DATADIR="${TESTS_PATH}/data"
NTOPNG_TEST_CONF="${NTOPNG_TEST_DATADIR}/ntopng.conf"
NTOPNG_TEST_CUSTOM_PROTOS="${NTOPNG_TEST_DATADIR}/protos.txt"
NTOPNG_TEST_REDIS="2"
NTOPNG_TEST_HTTP_PORT="3333"
NTOPNG_TEST_DB="ntopngtests"

DEFAULT_PCAP="test_01.pcap"

MAIL_FROM=""
MAIL_TO=""
DISCORD_WEBHOOK=""
TEST_NAME=""
API_VERSION=""

RUN_FROM_PACKAGES=false
DEBUG_LEVEL=0
KEEP_RUNNING=0

NOTIFICATIONS_ON=false
if [ -d packager ]; then
    source packager/utils/alerts.sh
    NOTIFICATIONS_ON=true
fi

function usage {
    echo "Usage: run.sh [-y=<test>] [-f=<mail from>] [-t=<mail to>] [-d=<discord webhook>] [-D=<debug level>] [-K]"
    echo ""
    echo "Options:"
    echo "[-y|--test]=<test>                | Run a selected test (e.g. -y=v2/get_host_active_01)"
    echo "[-v|--api-version]=<version>      | Run a test for the specified Rest API Version (1|2)"
    echo "[-f|--mail-from]=<address>        | Send notifications from the specified email address"
    echo "[-t|--mail-to]=<address>          | Send notifications to the specified email address"
    echo "[-d|--discord-webhook]=<endpoint> | Send notification to the specified Discord endpoint"
    echo "[-p|--use-package]		    | Run ntopng from binary package"
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
    killall -9 ntopng > /dev/null 2>&1 || true

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
    echo "-N=ntopng_test" >> ${NTOPNG_TEST_CONF}
    echo "--http-port=${NTOPNG_TEST_HTTP_PORT}" >> ${NTOPNG_TEST_CONF}
    if [ "${KEEP_RUNNING}" -eq "0" ]; then
        echo "--shutdown-when-done" >> ${NTOPNG_TEST_CONF}
    fi
    echo "--disable-login=1" >> ${NTOPNG_TEST_CONF}
    echo "--dont-change-user" >> ${NTOPNG_TEST_CONF}
    echo "--pid=./ntopng.pid" >> ${NTOPNG_TEST_CONF}

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

RC=0

#
# Run tests and compare the output with the expected output
# Params:
# $1 - List of tests to run
#
run_tests() {
    TESTS="${1}"
    TESTS_ARR=( $TESTS )
    NUM_TESTS=${#TESTS_ARR[@]}
    NUM_RAN=0
    NUM_SUCCESS=0

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

    I=1
    for T in ${TESTS}; do 
        TEST=${T%.yaml}

        echo "[>] Running test '${TEST}' (${I}/${NUM_TESTS})"
        ((I=I+1))

        # Cleanup ntopng
        ntopng_cleanup

        # Init ntopng configuration
        ntopng_init_conf

        # Init paths
        TMP_FILE=$(mktemp)
        NTOPNG_LOG=${TMP_FILE}.ntopng
        NTOPNG_FILTERED_LOG=${TMP_FILE}.filtered
        SCRIPT_OUT=${TMP_FILE}.out
        OUT_CSV=${TMP_FILE}.csv
        OUT_JSON=${TMP_FILE}.json
        OUT_DIFF=${TMP_FILE}.diff
        PRE_TEST=${TMP_FILE}.pre
        RUNTIME_TEST=${TMP_FILE}.runtime
        POST_TEST=${TMP_FILE}.post
        IGNORE=${TMP_FILE}.ignore
        EXTRA_OPTIONS=${TMP_FILE}.opt
        FORMATTED_OLD_OUT=${TMP_FILE}.new
        FORMATTED_NEW_OUT=${TMP_FILE}.old

        # Parsing YAML
        PCAP=`cat tests/${TEST}.yaml | shyaml -q get-value input`
        LOCALNET=`cat tests/${TEST}.yaml | shyaml -q get-value localnet`
        FORMAT=`cat tests/${TEST}.yaml | shyaml -q get-value format`
        REQUIRES=`cat tests/${TEST}.yaml | shyaml -q get-value requires`
        cat tests/${TEST}.yaml | shyaml -q get-value pre > ${PRE_TEST}
        cat tests/${TEST}.yaml | shyaml -q get-value runtime > ${RUNTIME_TEST}
        cat tests/${TEST}.yaml | shyaml -q get-value post > ${POST_TEST}
        cat tests/${TEST}.yaml | shyaml -q get-values ignore > ${IGNORE}
        cat tests/${TEST}.yaml | shyaml -q get-values options > ${EXTRA_OPTIONS}
	
        if [ -z "${FORMAT}" ] || [ $FORMAT == "None" ]; then
            FORMAT="json"
        fi
	
        if [ ! -z "$REQUIRES" ]; then
            if [ ! -d ${NTOPNG_ROOT}/pro ]; then
                echo "[i] This test requires ntopng Pro/Enterprise (skip)"
                continue
            fi
        fi

        ((NUM_RAN=NUM_RAN+1))

        # Run the test
        ntopng_run "${PCAP}" "${PRE_TEST}" "${RUNTIME_TEST}" "${POST_TEST}" "${SCRIPT_OUT}" "${NTOPNG_LOG}" "${LOCALNET}" "${EXTRA_OPTIONS}"

        # Filter/process ntopng output
        filter_ntopng_log "${NTOPNG_LOG}" "${NTOPNG_FILTERED_LOG}"

        if [ -s "${NTOPNG_FILTERED_LOG}" ]; then
            # ntopng Error/Warning

            cp ${NTOPNG_LOG} logs/${TEST}.log

            send_error "ntopng Error" "ntopng generated errors or warnings running '${TEST}'" "${NTOPNG_FILTERED_LOG}"
            RC=1

        elif [ ! -s "${SCRIPT_OUT}" ]; then

            send_error "Test Failure" "No output produced by the test '${TEST}'"
            RC=1

        elif [ ! -f ${RESULTS_FOLDER}/${TEST}.out ]; then
            ((NUM_SUCCESS=NUM_SUCCESS+1))
            echo "[i] SAVING OUTPUT"
            # Output not present, setting current output as expected

        if [ $FORMAT == "json" ]; then

            cat ${SCRIPT_OUT} | jq -cS . > ${RESULTS_FOLDER}/${TEST}.out

        elif [ $FORMAT == "csv" ]; then
            cat ${SCRIPT_OUT} > ${RESULTS_FOLDER}/${TEST}.out
        fi

        else

        if [ $FORMAT == "json" ]; then

            # NOTE: using jq as sometimes the json is sorted differently
            cat ${SCRIPT_OUT} | jq -cS . > ${OUT_JSON}

            # Comparison of two JSONs in bash, see
            # https://stackoverflow.com/questions/31930041/using-jq-or-alternative-command-line-tools-to-compare-json-files/31933234#31933234
           
            # Formatting JSON
            jq -S 'def post_recurse(f): def r: (f | select(. != null) | r), .; r; def post_recurse: post_recurse(.[]?); (. | (post_recurse | arrays) |= sort)' "${RESULTS_FOLDER}/${TEST}.out" > ${FORMATTED_OLD_OUT}
            jq -S 'def post_recurse(f): def r: (f | select(. != null) | r), .; r; def post_recurse: post_recurse(.[]?); (. | (post_recurse | arrays) |= sort)' "${OUT_JSON}" > ${FORMATTED_NEW_OUT}
            
            # Computing diff between old and new JSON with sorting
            diff --side-by-side --suppress-common-lines --ignore-all-space <(cat ${FORMATTED_OLD_OUT} | sort) <(cat ${FORMATTED_NEW_OUT} | sort) >"${OUT_DIFF}"
            filter_json "${OUT_DIFF}" "${IGNORE}"

        elif [ $FORMAT == "csv" ]; then

            cat ${SCRIPT_OUT} > ${OUT_CSV}
            TEMP1=${TMP_FILE}.1
            TEMP2=${TMP_FILE}.2
            cat ${RESULTS_FOLDER}/${TEST}.out > ${TEMP1}
            cat ${OUT_CSV} > ${TEMP2}
            filter_csv "${TEMP1}" "${IGNORE}"
            filter_csv "${TEMP2}" "${IGNORE}"
            diff --side-by-side --suppress-common-lines --ignore-all-space <(cat ${TEMP1} | sort) <(cat ${TEMP2} | sort) >"${OUT_DIFF}"
            /bin/rm -f ${TEMP1}
            /bin/rm -f ${TEMP2}

        fi

            if [ `cat "${OUT_DIFF}" | wc -l` -eq 0 ]; then
                ((NUM_SUCCESS=NUM_SUCCESS+1))
                echo "[i] OK"

                # Remove old conflicts if any
                rm -f ${CONFLICTS_FOLDER}/${TEST}.out
            else
                if [ $FORMAT == "json" ]; then
                    # Computing diff between old and new JSON (unsorted)
                    diff --side-by-side --suppress-common-lines --ignore-all-space <(cat ${FORMATTED_OLD_OUT}) <(cat ${FORMATTED_NEW_OUT}) >"${OUT_DIFF}"
                    filter_json "${OUT_DIFF}" "${IGNORE}"

                    # Store the new output under conflicts for debugging
                    cp ${OUT_JSON} ${CONFLICTS_FOLDER}/${TEST}.out
                elif [ $FORMAT == "csv" ]; then
                    # Store the new output under conflicts for debugging
                    cp ${OUT_CSV} ${CONFLICTS_FOLDER}/${TEST}.out
                fi

                send_error "Test Failure" "Unexpected output from the test '${TEST}'. Please check ${CONFLICTS_FOLDER}/${TEST}.out" "${OUT_DIFF}"
                RC=1
            fi

        fi

        /bin/rm -f ${TMP_FILE} ${SCRIPT_OUT} ${NTOPNG_LOG} ${NTOPNG_FILTERED_LOG} ${OUT_DIFF} ${OUT_JSON} ${OUT_CSV} ${PRE_TEST} "${RUNTIME_TEST}" ${POST_TEST} ${IGNORE} ${FORMATTED_OLD_OUT} ${FORMATTED_NEW_OUT}
    done

    if [ "${NUM_SUCCESS}" == "${NUM_RAN}" ]; then
        send_success "ntopng TESTS completed successfully" "All tests completed successfully with the expected output."
    else
        send_error "ntopng TESTS completed with errors" "${NUM_SUCCESS} out of ${NUM_RAN} completed successfully." ""
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
