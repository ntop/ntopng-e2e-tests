# ntopng E2E tests

This is a ntopng submodule including E2E tests.

Run the Tests
=============

An automated test suite is available under rest directory,
in order to run it:

1. Compile ntopng or install it from packages (go to https://packages.ntop.org/)

2. Make sure you have all the prerequisites installed: 

- redis-cli
- curl
- jq
- shyaml (pip install shyaml)

Note: to run the tests properly the redis service must be enabled.

3. Run the run.sh script:

```
cd rest
./run.sh
```
In case of failures, the output of the tests is stored in the
*ntopng/tests/e2e/rest/conflicts/* folder, in order to be able to compare
it with the expected output in the *ntopng/tests/e2e/rest/result* folder. 
The output is mainly produced in JSON format, but in some cases it can also be in CSV format.
In the first case, use the jq tool to better understand the inconsistency the contents of files. 
In case of test failures due to errors or warnings in the ntopng trace,
the full ntopng log is stored in the *ntopng/tests/e2e/rest/logs/* folder.

Version of ntopng installed as package may differ from the compiled one (e.g. enterprise/community version). In order to run the tests using the package build of ntopng, it is possible to use -p when running the run.sh under ntopng/tests/e2e/rest:

```
cd rest
./run.sh -p
```

In order to run a specific test and avoid running all the suite, it is possible to specify -y=<API version>/<test name> when running the run.sh script under ntopng/tests/e2e/rest:

```
cd rest
./run.sh -y=v2/get_alert_data_01
```

It is possible keep ntopng running for a specific test in order to access the web interface, in this case use -K when running the run.sh script with -y option under ntopng/tests/e2e/rest:

```
cd rest
./run.sh -y=v2/get_alert_data_01 -K
```

Then go to **localhost:3333/**

Smoke Test of all the REST endpoints
====================================

`rest/smoke.sh` calls every REST v2 endpoint (found under `scripts/lua/rest/v2`
and `pro/scripts/lua/rest/v2`) on a ntopng instance with login enabled and the
default pcap, with no expected output to maintain:

- as admin (read endpoints only): no error or warning in the ntopng log during
  the call, no HTTP 5xx, valid JSON with a single answer, no INTERNAL_ERROR
- as a user without capabilities and as anonymous (all endpoints): the outcome
  (allowed or denied) is the one recorded in `rest/smoke-baseline.txt`

```
cd rest
./smoke.sh                            # all the endpoints (about 3 minutes)
SMOKE_ONLY=get/host/ ./smoke.sh       # only the paths matching a regex
./smoke.sh -u                         # rewrite the baseline after a permission change
```

A full `./run.sh` also runs the smoke test after the other tests, counted as one
more test (its report is attached to the failure notification); `./run.sh -S`
skips it. It is not run with `-y` (single test) nor with `-p` (package: the
endpoints are listed from the sources).

The report (`rest/logs/smoke-report.txt`, also printed) has one entry per
problem: the URL to retry with curl, who called it and what went wrong, with
the Lua file and line taken from the ntopng log. It ends with the endpoints
that answered OK with no data (the code path with data did not run).

Add a Test
==========

When implementing a new feature, it is recommended to write a new
regression test to test the feature. This is based on the Rest API:
the first time the test is executed, the output (this is usually in 
JSON format, but could be in CSV format if a specific file is downloaded)
is stored in the 'result' folder, subsequent executions will compare
the output of the test with the old one to make sure it is still the same.

Creating a new test is as simple as creating a small .yaml file, with
the test name as name of the file, under ntopng/tests/e2e/rest/tests/<API version>
(where *API version* should be at least the latest API, e.g. v2) containing
the below sections:

- input: the name of a pcap in the 'ntopng/tests/e2e/rest/pcap' folder containing some traffic to be provided to ntopng as input
- localnet: the local network(s) as usually specified with the -m option in ntopng
- format: specify the format of the output to be written to the file, which can be either csv or json. If not specified, json will be used by default
- pre: a bash script with commands to be executed before processing the pcap in ntopng (initialization)
- post: a bash script with commands to be executed after the pcap has been processed by ntopng and generating some json output (using the Rest API)
- ignore: fields from the output to be ignored when comparing the output with the old file (this is usually used to ignore time, date or other fields that can change over time)
- options: a list of extra options for the ntopng configuration file
- login: true to run ntopng with the user login enabled (by default the tests run with --disable-login=1, so every request is handled as the administrator's and credentials are never checked). The 'admin' password is then the one in $NTOPNG_TEST_ADMIN_PASSWORD (see rest/common.sh)

Example:

```
input: traffic.pcap

localnet: 192.168.1.0/24

format: json

pre: |
  curl -s -u admin:admin -H "Content-Type: application/json" -d '{"ifid": 0, "action": "enable"}' http://localhost:3333/lua/toggle_all_user_scripts.lua

post: |
  sleep 10
  curl -s -u admin:admin  -H "Content-Type: application/json" -d '{"ifid": 0, "status": "historical-flows"}' http://localhost:3333/lua/rest/v2/get/alert/data.lua

ignore:
  - date

options:
  - -F=nindex
```
