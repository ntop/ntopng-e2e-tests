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

The Tests Run by run.sh
=======================

A full `./run.sh` runs two kinds of tests, in this order:

1. The regression tests: one `.yaml` file per test in `rest/tests/v2/` (see
   "Add a Test" below). Each one starts ntopng on a pcap, calls some REST
   endpoints and compares their output with the one saved in
   `rest/result/v2/<test>.out`.
2. Six tests with no expected output to maintain, each one a bash script that
   writes a report and exits with 0 (ok) or 1 (failures):

| # | Test | Script | Starts ntopng | Report | Time |
|---|------|--------|---------------|--------|------|
| 1 | All the REST endpoints | `rest/smoke.sh` | yes (slot 14) | `rest/logs/smoke-report.txt` | ~3 min |
| 2 | All the GUI pages | `gui/smoke.sh` | yes (slot 13) | `gui/logs/gui-smoke-report.txt` | ~10 min |
| 3 | Lua sources | `checks/lua.sh` | no | `checks/logs/lua-report.txt` | - |
| 4 | JS utilities (unit tests) | `checks/js.sh` | no | `checks/logs/js-report.txt` | - |
| 5 | GUI sources (ESLint) | `checks/js-lint.sh` | no | `checks/logs/js-lint-report.txt` | - |
| 6 | REST documentation | `checks/rest-docs.sh` | no | `checks/logs/rest-docs-report.txt` | ~6 s |

They are called by `run_smoke()` in `rest/run.sh`, each counted as one more
test in the total. On a failure the notification (Discord, mail) has the last
line of the report (the summary, e.g. `ENDPOINTS 512   FAIL 3`) and the full
report attached; with no report (ntopng did not start) the ntopng log is
attached instead. They are skipped with `./run.sh -S`, with `-y` (single test)
and with `-p` (package: the endpoints and pages are listed from the sources).
Each one can also be run alone, see below.

Requirements of the six (once per machine): Node.js (22 or later), luacheck
(`apt install lua-check`), jq, `npm install` in `pro` and in `gui` (the latter
also downloads Chromium; on a machine without a desktop
`sudo npx playwright install-deps chromium` installs its system libraries).
A missing requirement is reported as `FAIL  setup: ...`.

How the two smoke tests run ntopng
----------------------------------

Both use the helpers of `rest/common.sh`, the same as the regression tests:

- `ntopng_slot_setup N`: own HTTP port (3300 + N), Redis DB and data folder.
  Slot 0 would `killall ntopng`, a development instance included, and the two
  smoke tests use different slots, so they do not interfere
- `ntopng_init_conf`: a temporary configuration file, the admin password set in
  Redis
- `ntopng_run`: adds the pcap (`-i`), the local networks (`-m`), ClickHouse
  (`-F=clickhouse`, when a local server answers: the historical endpoints and
  pages need it) and starts ntopng with `--shutdown-when-done`

ntopng runs the test scripts at three moments:

| Option | When |
|--------|------|
| `--test-script-pre` | before reading the pcap |
| `--test-script` | after reading the pcap, with the live hosts and flows still in memory |
| `--test-script-post` | after the interfaces are shut down (no live hosts and flows) |

The smoke tests use `--test-script`, so the live pages and endpoints have the
data of the pcap. When the script ends, ntopng shuts down.

1. Smoke test of all the REST endpoints
---------------------------------------

Finds the REST endpoints that raise a Lua error, answer HTTP 5xx or invalid
JSON, do not answer, or whose permissions changed by mistake.

1. `rest/smoke.sh` starts ntopng (slot 14, port 3314) with login enabled,
   `test_01.pcap` and local network `192.168.0.0/16`, with
   `rest/smoke-check.sh` as `--test-script`
2. `smoke-check.sh` takes real params from the instance
   (`get/host/active_list.lua`, `get/host/data.lua`, `get/flow/active.lua`): a
   host, its VLAN, MAC and ASN, a flow (`flow_key`, `flow_hash_id`) and the time
   range of the pcap traffic. The endpoints that need a host or a flow then run
   the code path with the data instead of stopping at `INVALID_ARGUMENTS`
3. It adds the user `smoke`, unprivileged and with no capabilities
4. It lists every `.lua` file under `scripts/lua/rest/v2` and
   `pro/scripts/lua/rest/v2` and, for each one:
   - as admin, only `get/*` and `export/*` (the write endpoints would change
     the instance under test), a FAIL on:
     - an `ERROR:` or `WARNING:` line written in the ntopng log during the call
       (the log size is taken before the call, only the new lines are read)
     - no answer within 20 s, 300 s for the exports (`download` in the path)
     - HTTP 5xx with no declared REST error (a 503 `IFACE_ENCRYPTION_NOT_PRESENT`
       is a valid answer)
     - two HTTP answers in one body (a missing `return` after `rest_utils.answer`)
     - a JSON content type with invalid JSON, or `rc_str=INTERNAL_ERROR`
     - ntopng no longer answering on `/` (crash): the test stops there
   - as the user `smoke` and as anonymous, every endpoint: the outcome
     `denied` (401/403, redirect to the login, `NOT_GRANTED`) or `allowed`
5. The outcomes are compared with `rest/smoke-baseline.txt`: an endpoint that
   was denied and is now allowed (or the opposite) is a FAIL, and so is a new
   endpoint. Check that its permission is right, then save the new baseline with
   `./smoke.sh -u` and commit it
6. The report has one entry per problem: the URL to retry with curl, who called
   it and what went wrong (with the Lua file and line from the log). At the top
   `smoke.sh` adds the ntopng version, the configuration and how to reproduce;
   at the end the admin params and `ENDPOINTS N   FAIL M`

```
cd rest
./smoke.sh                            # all the endpoints
SMOKE_ONLY=get/host/ ./smoke.sh       # only the paths matching a regex
./smoke.sh -u                         # rewrite the baseline after a permission change
```

On an ntopng already running, e.g. the development one with real traffic, only
the admin calls of the read endpoints are done (no permission check, the
endpoints with side effects are skipped); `SMOKE_IFID` chooses the interface (a
view interface has the hosts):

```
cd rest
SMOKE_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> SMOKE_IFID=<ifid> ./smoke-check.sh
```

2. Smoke test of all the GUI pages
----------------------------------

Finds the pages with JavaScript or Vue errors, failed REST calls, errors in
the ntopng log, accessibility violations, horizontal scroll on a phone, broken
links, XSS, and i18n keys missing.

1. `gui/smoke.sh` starts ntopng as the REST smoke test does, on slot 13 (port
   3313) and with `rest/pcap/gui_smoke.pcap` (see XSS below), with
   `node gui/smoke.mjs` as `--test-script`
2. `smoke.mjs` (Playwright, headless Chromium, axe-core) reads the pages from
   `/lua/rest/v2/get/ntopng/menu.lua`, the real menu of the user: a new page in
   the menu is tested with no change to the test
3. It checks the pages in four passes, each one logged in in the browser (the
   guided tours are dismissed, they cover the page):

| Pass | User | Screen | Also |
|------|------|--------|------|
| `admin` | admin | 1400×900 | links, XSS detail pages |
| `dark` | admin | 1400×900 | dark theme (set back at the end) |
| `mobile` | admin | 390×844 | horizontal scroll |
| `user` | `gui_smoke`, no capabilities (added for the test, deleted at the end) | 1400×900 | links, its own menu |

4. For each page, a FAIL on:
   - a JavaScript exception, a `console.error` (Vue errors are tagged
     `[VUE_ERROR]`), an HTTP 4xx/5xx answer or a failed request to ntopng (the
     page and its REST calls), a redirect to the login page
   - a JavaScript dialog (`alert`, `confirm`): no page opens one by itself, it
     is an XSS payload of the pcap run by the page
   - an accessibility violation found by axe, WCAG 2.2 AA (contrast, labels,
     24px targets, ARIA roles), with the selectors of the elements
   - `mobile` only: a page wider than the screen
   - `admin` and `user` only: a link to another ntopng page that answers
     4xx/5xx, the error page or the login page. One link per path and parameter
     names (not 500 equal table rows); links with side effects (logout,
     `action=`, `delete`...) are not followed
   - an `ERROR:` or `WARNING:` line in the ntopng log while the page was open

   A failed page gets a full page screenshot, `gui/logs/<pass>_<url>.png`
5. On the first page of every desktop pass, axe also checks the sidebar parts
   shown only under the mouse: the expanded rail, the menu panel, the user popup
6. i18n: the keys used in the code (`i18n("...")` in Vue, JS and Lua, `*_i18n`
   in the table definitions) and missing in `scripts/locales/en.lua` are a FAIL:
   the GUI would show an empty or raw text
7. The report lists every failed page with its problems and screenshot, then
   `PAGES N   FAIL M   I18N MISSING K`

XSS: `gui/make_xss_pcap.py` (scapy) builds `gui_smoke.pcap`: `test_01.pcap`
copied byte by byte, followed by 11 packets of the host `192.168.1.250` with the
payload `<img src=x onerror=alert(N)>` in a field shown by the GUI, N says
which: 1 HTTP Host, 2 User-Agent, 3 URL, 4 TLS SNI, 5 DNS query, 6 DHCP host
name. A page that shows the field without escaping it runs `alert(N)`, reported
as `XSS: a alert("N") ran`. The `admin` pass also opens the detail pages of
`192.168.1.250` and of its flows, the only ones that show the User-Agent and the
URL. Run the script again only when the payloads change (the pcap is in the
repository).

```
cd gui
npm install                             # once (also downloads Chromium)
./smoke.sh                              # all the pages, all the passes
GUI_SMOKE_ONLY=alert ./smoke.sh         # only the pages whose URL matches a regex
GUI_SMOKE_PASSES=admin,dark ./smoke.sh  # only some passes
```

On an ntopng already running (the log is checked only if `NTOPNG_LOG` is set):

```
cd gui
NTOPNG_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> node smoke.mjs
```

3. Lua sources (luacheck)
-------------------------

Finds the Lua bugs visible without running the code, no style. `checks/lua.sh`
runs luacheck on `scripts/lua`, `pro/scripts/lua` and `scripts/locales`
(`attic` and the `scripts/lua/pro` link left out) with only these warnings:

- `011` syntax error
- `121` assignment to a read-only global (e.g. `string = ...`)
- `143` undefined field of a standard library (e.g. `string.lenght`, `table.insrt`)
- `314` key repeated in a table constructor (one of the values is lost)
- `511` unreachable code

The functions ntopng adds to the standard libraries (e.g. `function string.split(`,
`table.merge = ...`) are found in the sources at every run and passed to
luacheck as known, so they are not reported.

4. JS utilities (Vitest)
------------------------

Finds the regressions of the GUI JavaScript utilities. `checks/js.sh` runs
`npm run test:js` in `pro`: Vitest on `pro/tests/js/*.test.js` (e.g.
`server-dates.test.js`, the dates in the server time zone). The failed tests
are printed in full, a dot for each passed one.

A new test is a `pro/tests/js/<name>.test.js` file; code that uses the browser
globals (`window`, `document`) needs the `// @vitest-environment happy-dom`
line on top.

5. GUI sources (ESLint)
-----------------------

Finds the bugs in the `.vue` and `.js` files of `pro/http_src`, no style.
`checks/js-lint.sh` runs `npm run lint:errors` in `pro` (`eslint --no-eslintrc
-c .eslintrc.errors.json`, so the style config is not used). The config
`pro/.eslintrc.errors.json` has `vue3-essential` and the core rules that find
bugs:

- undefined variables (a ReferenceError when the code runs)
- templates and `v-for` not valid (missing `key`, same `key` in `v-if` and `v-else`)
- props changed by the child, refs used without `.value`
- keys repeated in an object, unreachable code

The globals the pages define (`i18n`, `http_prefix`, `ntopng_utility`, `$`...)
are listed in the `globals` of the config: a new one goes there. The report has
one `FAIL  file:line:col: message [rule]` line per problem.

6. REST documentation
---------------------

Finds a REST documentation (`httpdocs/misc/rest-api-v2.json`, the spec of the
REST API page) that no longer matches the code. `checks/rest-docs.sh` (jq):

- every documented path must exist (`/lua/pro/rest/v2/...` is
  `pro/scripts/lua/rest/v2/...`): a moved or removed endpoint is a FAIL, its
  documentation would answer 404
- a path documented as GET must not read only `_POST` (comments are left out):
  a GET request does not fill `_POST`, the documented call cannot work. The
  opposite is fine: ntopng also puts the params of a JSON POST in `_GET`
- the endpoints not documented are listed, not failed: the internal ones (page
  contexts, wizard helpers) are left out on purpose

The last line of the report is `REST DOCS   PATHS N   FAIL M`.

```
cd checks
./lua.sh
./js.sh                               # or: cd pro && npm run test:js
./js-lint.sh                          # or: cd pro && npm run lint:errors
./rest-docs.sh
```

Tests with the Sanitizers
=========================

Not run by `./run.sh`: they need an ntopng built with the sanitizers
(AddressSanitizer, LeakSanitizer, UBSan) and take longer.

Build: a copy of the sources next to `ntopng` (the build looks for `../nDPI`,
`../PF_RING`, `../license`), without `.git` (do not run `autogen.sh` in a git
checkout: it updates the submodules and resets `httpdocs/dist`), then
`./configure --with-leak-sanitizer && make` in the copy (clang).

The environment of every run below:

```
export ASAN_OPTIONS=detect_leaks=1                         # 0: memory errors only
export ASAN_SYMBOLIZER_PATH=/usr/bin/llvm-symbolizer-18    # file and line in the stacks (same version as clang)
export UBSAN_OPTIONS=print_stacktrace=1
```

All the tests: `./run.sh -j=4` from `tests/e2e/rest` of the copy (`run.sh` tests
the ntopng three folders up; `-j` needs GNU parallel; about 50 minutes). A
sanitizer report or a leak is an error in the ntopng log: the test fails and the
notification has the report, with file and line. The REST and GUI smoke tests
also check the log after ntopng exits (the leaks are reported at exit). The
source checks need `node_modules` in `pro` and `gui` of the copy (e.g. links to
the ones of the tree).

Stress test with live traffic: `stress/run.sh` starts the ntopng of the tree
(slot 12, port 3312) with one ZMQ collector interface, fed by nProbe with a
NetFlow pcap replayed in a loop by sendPcap, and ClickHouse when a local server
answers (historical endpoints, flow dump under traffic). With `--simulate-vlans` (random VLAN
per flow), idle timeouts of 10 s and low host and flow limits (`-x 5000 -X 20000`)
hosts and flows are created and purged all the time while, for
`STRESS_MINUTES`, the REST smoke check (live mode, `STRESS_REST_WORKERS` copies
in parallel) and the GUI smoke check (live mode, `admin` pass) run in a loop and
the RSS of ntopng is sampled every 30 s. Then ntopng is stopped with SIGTERM. It
fails on a sanitizer report, a crash, a shutdown longer than
`STRESS_SHUTDOWN_TIMEOUT` (300 s), a FAIL of the smoke checks (reported once,
URL without its params), an error or warning in the ntopng log (listed once with
its count: with calls in parallel it cannot be tied to one of them, the REST
smoke test tells the endpoint),
an RSS growth over `STRESS_RSS_GROWTH` % (20) between the first and the last third
of the samples after the warm-up, and when no flow arrives within 60 s (e.g.
nProbe stopped on its license: it validates it only as root).

```
cd stress
STRESS_PCAP=<NetFlow pcap> NPROBE="sudo <path>/nprobe" SENDPCAP=<path>/sendPcap \
    STRESS_MINUTES=60 ./run.sh
```

Report: `stress/logs/stress-report.txt`, with the ntopng log, the RSS samples and
the smoke reports of every loop in `stress/logs/`.

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
- prefs: a list of preferences set before ntopng starts, each one as "<name> <value>" (written to Redis as ntopng.prefs.<name>, e.g. "enable_flow_swap_heuristic 0"): for the preferences read at startup, that a pre script would change too late
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
