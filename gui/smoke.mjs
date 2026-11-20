//
// Smoke test of the ntopng web GUI: opens every page of the menu as admin in
// headless Chromium and reports, for each page:
//   - JavaScript exceptions and console errors (Vue errors are logged as [VUE_ERROR])
//   - HTTP 4xx/5xx answers and failed requests of ntopng (the page and its REST calls)
//   - errors and warnings written to the ntopng log while the page was open
//   - accessibility violations (WCAG 2.2 AA, e.g. low contrast) found by axe
//
// The pages are the entries of the menu (GET /lua/rest/v2/get/ntopng/menu.lua),
// so a new page is tested as soon as it is in the menu. A failed page is saved as
// a full page screenshot next to the report.
//
// Started by smoke.sh on a test instance, or by hand on any running ntopng:
//   NTOPNG_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> node smoke.mjs
//
// Environment:
//   NTOPNG_URL       ntopng address (default http://localhost:3000)
//   NTOPNG_USER      user, an administrator (default admin)
//   NTOPNG_PASSWORD  password of the user (required)
//   NTOPNG_LOG       ntopng log file to check (optional: without it the log is not checked)
//   GUI_SMOKE_ONLY   only the pages whose URL matches this regex (e.g. alert)
//   GUI_SMOKE_REPORT report file (default logs/gui-smoke-report.txt)
//
// Exit code: 0 no problem, 1 at least one FAIL.
//

import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const BASE_URL = process.env.NTOPNG_URL ?? "http://localhost:3000";
const USER = process.env.NTOPNG_USER ?? "admin";
const PASSWORD = process.env.NTOPNG_PASSWORD;
const NTOPNG_LOG = process.env.NTOPNG_LOG;
const ONLY = process.env.GUI_SMOKE_ONLY ? new RegExp(process.env.GUI_SMOKE_ONLY) : null;
const REPORT = process.env.GUI_SMOKE_REPORT ?? "logs/gui-smoke-report.txt";

const PAGE_LOAD_TIMEOUT_MS = 30000;
// Most pages refresh their data periodically and never reach network idle: wait at most this
const NETWORK_IDLE_TIMEOUT_MS = 10000;
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];
// The lines of the ntopng log that are problems
const LOG_PROBLEM = /ERROR:|WARNING:/;

if (!PASSWORD) {
  console.error("NTOPNG_PASSWORD is not set");
  process.exit(2);
}

// ############################################## Login

// Logs in with the login form, as a user does: the session cookie is then
// shared by all the pages of the context and by context.request
async function login(context) {
  const page = await context.newPage();
  await page.goto(`${BASE_URL}/lua/login.lua`);
  await page.fill("#input-username", USER);
  await page.fill("#input-password", PASSWORD);
  await Promise.all([page.waitForNavigation(), page.click("button[type=submit]")]);
  const loggedIn = !isLoginPage(page.url());
  await page.close();
  if (!loggedIn) {
    throw new Error(`login of '${USER}' failed: check NTOPNG_USER and NTOPNG_PASSWORD`);
  }
}

function isLoginPage(url) {
  return new URL(url).pathname.endsWith("/login.lua");
}

// ############################################## Pages to test

// The URLs of the menu entries that open an ntopng page (no dividers, external
// links or entries disabled by the current configuration)
async function getMenuPages(request) {
  const answer = await request.get(`${BASE_URL}/lua/rest/v2/get/ntopng/menu.lua`);
  if (!answer.ok()) {
    throw new Error(`menu.lua answered HTTP ${answer.status()}`);
  }
  const menu = (await answer.json()).rsp;

  const urls = menu.sections
    .flatMap((section) => section.entries ?? [])
    .filter((entry) => entry.url?.startsWith("/lua/") && !entry.is_external && !entry.is_divider && !entry.disabled)
    .map((entry) => entry.url);

  // The same page can be in more than one section
  return [...new Set(urls)];
}

// ############################################## ntopng log

// Size of the log now: the lines written after this offset are the ones of the page under test
function logOffset() {
  return NTOPNG_LOG ? fs.statSync(NTOPNG_LOG).size : 0;
}

function logProblemsSince(offset) {
  if (!NTOPNG_LOG) {
    return [];
  }
  const newLines = fs.readFileSync(NTOPNG_LOG).subarray(offset).toString().split("\n");
  return newLines.filter((line) => LOG_PROBLEM.test(line));
}

// ############################################## Check of one page

// Opens the page and returns the list of its problems, one string each
async function checkPage(context, url) {
  const problems = [];
  const page = await context.newPage();
  const isNtopng = (requestUrl) => requestUrl.startsWith(BASE_URL);

  page.on("pageerror", (error) => problems.push(`JS exception: ${error.message}`));
  page.on("console", (message) => {
    // "Failed to load resource" is already reported, with its URL, by the response check below
    if (message.type() === "error" && !message.text().startsWith("Failed to load resource")) {
      problems.push(`console.error: ${message.text()}`);
    }
  });
  page.on("response", (response) => {
    if (isNtopng(response.url()) && response.status() >= 400) {
      problems.push(`HTTP ${response.status()}: ${response.request().method()} ${response.url().slice(BASE_URL.length)}`);
    }
  });
  page.on("requestfailed", (request) => {
    // ERR_ABORTED: request cancelled by the page itself (e.g. a query replaced by a newer one)
    const error = request.failure()?.errorText;
    if (isNtopng(request.url()) && error !== "net::ERR_ABORTED") {
      problems.push(`request failed (${error}): ${request.method()} ${request.url().slice(BASE_URL.length)}`);
    }
  });

  const offset = logOffset();
  try {
    await page.goto(`${BASE_URL}${url}`, { timeout: PAGE_LOAD_TIMEOUT_MS });
    if (isLoginPage(page.url())) {
      throw new Error("redirected to the login page (session lost?)");
    }
    await page.waitForLoadState("networkidle", { timeout: NETWORK_IDLE_TIMEOUT_MS }).catch(() => {});

    const axe = await new AxeBuilder({ page }).withTags(AXE_TAGS).analyze();
    for (const violation of axe.violations) {
      const where = violation.nodes.slice(0, 3).map((node) => node.target.join(" ")).join(", ");
      problems.push(`accessibility (${violation.id}, ${violation.nodes.length} elements): ${violation.help}. E.g. ${where}`);
    }
  } catch (error) {
    problems.push(`page not loaded: ${error.message.split("\n")[0]}`);
  }
  if (problems.length) {
    const screenshot = path.join(path.dirname(REPORT), `${url.replace(/[^\w]+/g, "_")}.png`);
    await page.screenshot({ path: screenshot, fullPage: true }).catch(() => {});
    problems.push(`screenshot: ${screenshot}`);
  }
  await page.close();

  for (const line of logProblemsSince(offset)) {
    problems.push(`ntopng log: ${line.replace(/^.*?(ERROR|WARNING): /, "$1: ")}`);
  }

  return problems;
}

// ############################################## Main

// The Chromium downloaded by npm install (postinstall)
const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
await login(context);

const pages = (await getMenuPages(context.request)).filter((url) => !ONLY || ONLY.test(url));
const report = [];
let failedPages = 0;

for (const url of pages) {
  const problems = await checkPage(context, url);
  console.log(`${problems.length ? "FAIL" : "OK  "}  ${url}`);
  if (problems.length) {
    failedPages++;
    report.push(`FAIL  ${url}`, ...problems.map((problem) => `      ${problem}`));
  }
}
await browser.close();

report.push(`PAGES ${pages.length}   FAIL ${failedPages}`);
fs.mkdirSync(path.dirname(REPORT), { recursive: true });
fs.writeFileSync(REPORT, report.join("\n") + "\n");
console.log(`\n${report.join("\n")}`);

process.exit(failedPages ? 1 : 0);
