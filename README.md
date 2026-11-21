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
the Lua file and line taken from the ntopng log.

Smoke Test of all the GUI pages
===============================

`gui/smoke.sh` starts ntopng as `rest/smoke.sh` does and opens every page of
the menu (as listed by `/lua/rest/v2/get/ntopng/menu.lua`) in headless
Chromium, in four passes: `admin`, `dark` (admin, dark theme), `mobile` (admin,
390px wide screen) and `user` (a user without capabilities, created for the
test and deleted at the end, with its own menu). A page fails on:

- JavaScript exceptions and `console.error` (Vue errors are tagged `[VUE_ERROR]`)
- HTTP 4xx/5xx answers and failed requests of ntopng (the page and its REST calls)
- errors and warnings in the ntopng log while the page was open
- accessibility violations (WCAG 2.2 AA, e.g. low contrast) found by axe
- horizontal scroll (`mobile` pass only)
- broken links to other ntopng pages: HTTP 4xx/5xx, the error page or the login
  page (`admin` and `user` passes; one link per path and parameter names, links
  with side effects such as logout or `action=` are not followed)

On the first page of every desktop pass, axe also checks the sidebar parts shown only
under the mouse (expanded rail and menu panel, user popup). The guided tours of
the user are dismissed after the login (they cover the page).

It also fails on the i18n keys used in the code (`i18n("...")` in Vue, JS and
Lua, `*_i18n` in the table definitions) and missing in `scripts/locales/en.lua`:
the GUI would show an empty or raw text.

Requirements: Node.js. `npm install` also downloads the Chromium used by the
test (Playwright); on a machine without a desktop, Chromium may need some system
libraries: `sudo npx playwright install-deps chromium` installs them.

```
cd gui
npm install                           # once (also downloads Chromium)
./smoke.sh                            # all the pages, all the passes (about 10 minutes)
GUI_SMOKE_ONLY=alert ./smoke.sh       # only the pages whose URL matches a regex
GUI_SMOKE_PASSES=admin,dark ./smoke.sh  # only some passes
```

The check can also be run on an ntopng already running, e.g. the development
one (the log is checked only if `NTOPNG_LOG` is set):

```
cd gui
NTOPNG_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> node smoke.mjs
```

A full `./run.sh` also runs it after the REST smoke test, counted as one more
test; `./run.sh -S` skips both. The report (`gui/logs/gui-smoke-report.txt`,
also printed) lists every failed page with its problems and the path of a full
page screenshot taken when the problems were found (`gui/logs/<pass>_*.png`).

Checks of the sources
=====================

Two checks that do not start ntopng, run by a full `./run.sh` after the smoke
tests (one more test each, `./run.sh -S` skips them):

- `checks/lua.sh`: luacheck of the Lua sources, only the warnings that are
  bugs: syntax errors, assignments to read-only globals, undefined fields of the
  standard libraries (e.g. `string.lenght`), keys repeated in a table
  constructor (a value is lost), unreachable code. Requirements: luacheck
  (`apt install lua-check`). Report: `checks/logs/lua-report.txt`.
- `checks/js.sh`: unit tests of the GUI JavaScript utilities with Vitest
  (`pro/tests/js/*.test.js`, e.g. the dates in the server time zone).
  Requirements: `npm install` in `pro`. Report: `checks/logs/js-report.txt`.

```
cd checks
./lua.sh
./js.sh                               # or: cd pro && npm run test:js
```

A new JS test is a `pro/tests/js/<name>.test.js` file (see
`server-dates.test.js`); code that uses the browser globals needs the
`// @vitest-environment happy-dom` line on top.

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
