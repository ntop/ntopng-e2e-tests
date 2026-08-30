#!/bin/bash
#
# Execute a single ntopng REST e2e test and compare the produced output with
# the expected one.
#
# This is invoked once per test by run.sh (sequentially, or by GNU parallel
# when -j is used). It can also be run by hand for debugging:
#
#   ./run-one.sh v2/get_host_active_01.yaml 0
#
# Usage: run-one.sh <test.yaml> <slot>
#   <test.yaml>  test path relative to ./tests (e.g. v2/get_host_active_01.yaml)
#   <slot>       resource slot: 0 keeps the historical single-instance layout
#                (sequential runs), >= 1 selects an isolated set of resources
#                (HTTP port, Redis DB, data dir, ...) for a parallel worker
#
# Exit code: 0 = ok (or expected output saved), 1 = failure, 2 = skipped
#

TEST_ARG="${1}"
SLOT="${2:-0}"

TESTS_PATH="${TESTS_PATH:-${PWD}}"
cd "${TESTS_PATH}" || exit 1

source "${TESTS_PATH}/common.sh"
ntopng_slot_setup "${SLOT}"

RESULTS_FOLDER="${RESULTS_FOLDER:-result}"
CONFLICTS_FOLDER="${CONFLICTS_FOLDER:-conflicts}"

RC=0

TEST=${TEST_ARG%.yaml}

echo "[>] Running test '${TEST}'${PROGRESS:+ (${PROGRESS})}"

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

cleanup_tmp() {
    /bin/rm -f ${TMP_FILE} ${SCRIPT_OUT} ${NTOPNG_LOG} ${NTOPNG_FILTERED_LOG} ${OUT_DIFF} ${OUT_JSON} ${OUT_CSV} ${PRE_TEST} "${RUNTIME_TEST}" ${POST_TEST} ${IGNORE} ${EXTRA_OPTIONS} ${FORMATTED_OLD_OUT} ${FORMATTED_NEW_OUT}
}

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
        cleanup_tmp
        exit 2
    fi
fi

# The pre/runtime/post snippets talk to ntopng on the hard-coded port 3333.
# A parallel worker runs on its own port, so rewrite the endpoint accordingly.
if [ "${NTOPNG_TEST_HTTP_PORT}" != "3333" ]; then
    sed -i "s#\(localhost\|127\.0\.0\.1\):3333#\1:${NTOPNG_TEST_HTTP_PORT}#g" \
        "${PRE_TEST}" "${RUNTIME_TEST}" "${POST_TEST}"
fi

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

cleanup_tmp

exit ${RC}
