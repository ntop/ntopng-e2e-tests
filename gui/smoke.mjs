//
// Smoke test of the ntopng web GUI: opens every page of the menu in headless
// Chromium and reports, for each page:
//   - JavaScript exceptions and console errors (Vue errors are logged as [VUE_ERROR])
//   - HTTP 4xx/5xx answers and failed requests of ntopng (the page and its REST calls)
//   - errors and warnings written to the ntopng log while the page was open
//   - accessibility violations (WCAG 2.2 AA, e.g. low contrast) found by axe
//   - broken links to other ntopng pages (HTTP 4xx/5xx, the error page, the login page)
//
// The sidebar hover states (expanded rail, menu panel, user popup) are checked
// with axe on the first page of every pass.
//
// The pages are checked in more passes (see PASSES): as admin, in the dark
// theme, on a phone screen (also horizontal scroll) and as a user without
// capabilities. The pages are the entries of the menu of the user
// (GET /lua/rest/v2/get/ntopng/menu.lua), so a new page is tested as soon as
// it is in the menu. A failed page is saved as a full page screenshot next to
// the report.
//
// It also reports the i18n keys used in the code (Vue, JS, Lua, table
// definitions) that are missing in scripts/locales/en.lua: the GUI would show
// an empty or raw text.
//
// Started by smoke.sh on a test instance, or by hand on any running ntopng:
//   NTOPNG_URL=http://localhost:3000 NTOPNG_PASSWORD=<admin password> node smoke.mjs
//
// Environment:
//   NTOPNG_URL        ntopng address (default http://localhost:3000)
//   NTOPNG_USER       user, an administrator (default admin)
//   NTOPNG_PASSWORD   password of the user (required)
//   NTOPNG_LOG        ntopng log file to check (optional: without it the log is not checked)
//   NTOPNG_ROOT       ntopng sources, for the i18n check (default: the ntopng this folder is in)
//   GUI_SMOKE_ONLY    only the pages whose URL matches this regex (e.g. alert)
//   GUI_SMOKE_PASSES  only these passes, comma separated (e.g. admin,dark; default all)
//   GUI_SMOKE_REPORT  report file (default logs/gui-smoke-report.txt)
//
// Exit code: 0 no problem, 1 at least one FAIL.
//

import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const BASE_URL = process.env.NTOPNG_URL ?? "http://localhost:3000";
const ADMIN = { username: process.env.NTOPNG_USER ?? "admin", password: process.env.NTOPNG_PASSWORD };
const NTOPNG_LOG = process.env.NTOPNG_LOG;
const NTOPNG_ROOT = process.env.NTOPNG_ROOT ?? path.resolve(import.meta.dirname, "../../..");
const ONLY = process.env.GUI_SMOKE_ONLY ? new RegExp(process.env.GUI_SMOKE_ONLY) : null;
const REPORT = process.env.GUI_SMOKE_REPORT ?? "logs/gui-smoke-report.txt";

// User without capabilities, created for the "user" pass and deleted at the end
const UNPRIVILEGED = { username: "gui_smoke", password: "Gui_smoke_pw_1" };

const DESKTOP = { width: 1400, height: 900 };
const PHONE = { width: 390, height: 844 };

// One pass = every page of the menu of the user, checked with these settings
// (the links are the same in every theme and screen size: checked once per user)
const PASSES = [
  { name: "admin", user: ADMIN, viewport: DESKTOP, checkLinks: true },
  { name: "dark", user: ADMIN, viewport: DESKTOP, dark: true },
  { name: "mobile", user: ADMIN, viewport: PHONE, noHorizontalScroll: true },
  { name: "user", user: UNPRIVILEGED, viewport: DESKTOP, checkLinks: true },
].filter((pass) => !process.env.GUI_SMOKE_PASSES || process.env.GUI_SMOKE_PASSES.split(",").includes(pass.name));

const PAGE_LOAD_TIMEOUT_MS = 30000;
// Most pages refresh their data periodically and never reach network idle: wait at most this
const NETWORK_IDLE_TIMEOUT_MS = 10000;
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];
// The lines of the ntopng log that are problems
const LOG_PROBLEM = /ERROR:|WARNING:/;
// Links not followed: they change the state of the instance under test
const LINK_SKIP_PATH = /\/(logout|rest\/)/;
const LINK_SKIP_PARAMS = ["action", "delete", "remove", "reset", "restart", "shutdown"];
// Where ntopng sends a missing page or a script error
const ERROR_PAGE = "/lua/http_status_code.lua";

// i18n check: where the keys are used and how (i18n("a.b"), _i18n('a.b'), "title_i18n": "a.b")
const I18N_DIRS = ["http_src", "pro/http_src", "scripts/lua", "pro/scripts/lua", "httpdocs/tables_config", "pro/httpdocs/tables_config"];
const I18N_SKIP_DIRS = ["node_modules", "attic", "dist"];
const I18N_FILES = /\.(vue|js|lua|json)$/;
const I18N_USES = [/\b_?i18n\(\s*["'`]([\w-]+(?:\.[\w-]+)*)["'`]\s*[,)]/g, /"\w*_i18n"\s*:\s*"([\w-]+(?:\.[\w-]+)*)"/g];
const COMMENT_LINE = /^\s*(--|\/\/|\/?\*)/;

if (!ADMIN.password) {
  console.error("NTOPNG_PASSWORD is not set");
  process.exit(2);
}

// ############################################## Login and users

// Logs in with the login form, as a user does: the session cookie is then
// shared by all the pages of the context and by context.request
async function login(context, user) {
  const page = await context.newPage();
  await page.goto(`${BASE_URL}/lua/login.lua`);
  await page.fill("#input-username", user.username);
  await page.fill("#input-password", user.password);
  await Promise.all([page.waitForNavigation(), page.click("button[type=submit]")]);
  const loggedIn = !isLoginPage(page.url());
  await page.close();
  if (!loggedIn) {
    throw new Error(`login of '${user.username}' failed`);
  }
}

function isLoginPage(url) {
  return new URL(url).pathname.endsWith("/login.lua");
}

// REST calls as admin, authenticated per request (no CSRF token needed)
async function adminPost(request, url, form) {
  const auth = Buffer.from(`${ADMIN.username}:${ADMIN.password}`).toString("base64");
  const answer = await request.post(`${BASE_URL}${url}`, { form, headers: { Authorization: `Basic ${auth}` } });
  if (!answer.ok()) {
    throw new Error(`${url} answered HTTP ${answer.status()}`);
  }
}

async function addUnprivilegedUser(request) {
  await adminPost(request, "/lua/rest/v2/add/ntopng/user.lua", {
    username: UNPRIVILEGED.username,
    full_name: UNPRIVILEGED.username,
    password: UNPRIVILEGED.password,
    confirm_password: UNPRIVILEGED.password,
    user_role: "unprivileged",
    allowed_networks: "0.0.0.0/0,::/0",
    allowed_interface: "",
    add_user_language: "en",
  });
}

async function deleteUnprivilegedUser(request) {
  await adminPost(request, "/lua/rest/v2/delete/ntopng/user.lua", { username: UNPRIVILEGED.username });
}

// POST of a form as the logged in user, with the CSRF token of the session (as the GUI does)
async function postAsUser(context, url, form) {
  const page = await context.newPage();
  await page.goto(`${BASE_URL}/lua/about.lua`);
  await page.evaluate(async ({ url, form }) => {
    await fetch(url, { method: "POST", body: new URLSearchParams({ ...form, csrf: window.__CSRF_DATATABLE__ }) });
  }, { url: `${BASE_URL}${url}`, form });
  await page.close();
}

// Sets the theme of the logged in user, as the theme switch of the GUI does
async function setTheme(context, dark) {
  await postAsUser(context, "/lua/update_prefs.lua", { action: "toggle_theme", toggle_dark_theme: String(dark) });
}

// "Never show again" on the guided tours the user would see: a tour covers the
// page (e.g. the first login one of a new user)
async function dismissDemoTours(context) {
  const status = await (await context.request.get(`${BASE_URL}/lua/rest/v2/get/demo/status.lua`)).json();
  for (const demo of status.rsp?.demos ?? []) {
    if (demo.should_show) {
      await postAsUser(context, "/lua/rest/v2/add/demo/progress.lua", { id: demo.id, action: "dismiss" });
    }
  }
}

// ############################################## Pages to test

// The menu of the logged in user
async function getMenu(request) {
  const answer = await request.get(`${BASE_URL}/lua/rest/v2/get/ntopng/menu.lua`);
  if (!answer.ok()) {
    throw new Error(`menu.lua answered HTTP ${answer.status()}`);
  }
  return (await answer.json()).rsp;
}

// The URLs of the menu entries that open an ntopng page (no dividers, external
// links or entries disabled by the current configuration)
function getMenuPages(menu) {
  const urls = menu.sections
    .flatMap((section) => section.entries ?? [])
    .filter((entry) => entry.url?.startsWith("/lua/") && !entry.is_external && !entry.is_divider && !entry.disabled)
    .map((entry) => entry.url)
    .filter((url) => !ONLY || ONLY.test(url));

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

// ############################################## Links

// A link is checked once per shape (path + names of the parameters): the links
// to the 1000 hosts of a table are the same link
function linkShape(url) {
  return `${url.pathname}?${[...url.searchParams.keys()].sort().join("&")}`;
}

// Problems of the links to other ntopng pages found in the page; checkedShapes
// keeps the shapes already checked in this pass
async function checkLinks(page, request, checkedShapes) {
  const problems = [];
  const hrefs = await page.evaluate(() => [...document.querySelectorAll("a[href]")].map((a) => a.href));
  for (const href of new Set(hrefs)) {
    const url = new URL(href);
    const shape = linkShape(url);
    const sideEffects = LINK_SKIP_PATH.test(url.pathname) || LINK_SKIP_PARAMS.some((name) => url.searchParams.has(name));
    if (url.origin !== new URL(BASE_URL).origin || !url.pathname.startsWith("/lua/") || sideEffects || checkedShapes.has(shape)) {
      continue;
    }
    checkedShapes.add(shape);

    const answer = await request.get(href, { timeout: PAGE_LOAD_TIMEOUT_MS }).catch((error) => error);
    const target = href.slice(BASE_URL.length);
    if (answer instanceof Error) {
      problems.push(`broken link (${answer.message.split("\n")[0]}): ${target}`);
    } else if (answer.status() >= 400) {
      problems.push(`broken link (HTTP ${answer.status()}): ${target}`);
    } else if (new URL(answer.url()).pathname === ERROR_PAGE) {
      problems.push(`broken link (${new URL(answer.url()).searchParams.get("message")}): ${target}`);
    } else if (isLoginPage(answer.url())) {
      problems.push(`link to a page the user cannot open (login page): ${target}`);
    }
  }
  return problems;
}

// ############################################## Check of one page

// Opens the page and returns the list of its problems, one string each
async function checkPage(context, pass, url, checkedShapes) {
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

    if (pass.noHorizontalScroll) {
      const pageWidth = await page.evaluate(() => document.documentElement.scrollWidth);
      if (pageWidth > pass.viewport.width) {
        problems.push(`horizontal scroll: the page is ${pageWidth}px wide on a ${pass.viewport.width}px screen`);
      }
    }

    if (pass.checkLinks) {
      problems.push(...(await checkLinks(page, context.request, checkedShapes)));
    }
  } catch (error) {
    problems.push(`page not loaded: ${error.message.split("\n")[0]}`);
  }
  if (problems.length) {
    const screenshot = path.join(path.dirname(REPORT), `${pass.name}${url.replace(/[^\w]+/g, "_")}.png`);
    await page.screenshot({ path: screenshot, fullPage: true }).catch(() => {});
    problems.push(`screenshot: ${screenshot}`);
  }
  await page.close();

  for (const line of logProblemsSince(offset)) {
    problems.push(`ntopng log: ${line.replace(/^.*?(ERROR|WARNING): /, "$1: ")}`);
  }

  return problems;
}

// ############################################## Sidebar hover states

// The sidebar parts shown only under the mouse, checked with axe: the
// expanded rail with the menu panel of a section, then the user popup
async function checkSidebarHover(context, url) {
  const problems = [];
  const page = await context.newPage();
  await page.goto(`${BASE_URL}${url}`, { timeout: PAGE_LOAD_TIMEOUT_MS });
  await page.waitForLoadState("networkidle", { timeout: NETWORK_IDLE_TIMEOUT_MS }).catch(() => {});

  const states = [
    { name: "menu panel", hover: ".sb-rail__btn[data-section]", shown: ".sb-panel" },
    { name: "user popup", hover: ".sb-rail__btn--avatar", shown: ".sb-user-popup" },
  ];
  for (const state of states) {
    const hovered = await page.hover(state.hover, { timeout: 5000 }).then(() => true, (error) => {
      problems.push(`${state.name}: cannot hover ${state.hover}: ${error.message.split("\n")[0]}`);
      return false;
    });
    if (!hovered) {
      continue;
    }
    await page.waitForSelector(state.shown, { state: "visible", timeout: 5000 }).catch(() => {});
    // The colors change with a transition
    await page.waitForTimeout(500);
    const axe = await new AxeBuilder({ page }).include(".sb-rail").include(state.shown).withTags(AXE_TAGS).analyze();
    for (const violation of axe.violations) {
      const where = violation.nodes.slice(0, 3).map((node) => node.target.join(" ")).join(", ");
      problems.push(`${state.name}: accessibility (${violation.id}, ${violation.nodes.length} elements): ${violation.help}. E.g. ${where}`);
    }
  }
  await page.close();
  return problems;
}

// ############################################## Check of one pass

// Checks every page of the menu of the pass user; adds the failed pages to the
// report and returns how many pages were checked and how many failed
async function checkPass(browser, pass, report) {
  const context = await browser.newContext({ viewport: pass.viewport });
  await login(context, pass.user);
  await dismissDemoTours(context);

  const menu = await getMenu(context.request);
  if (pass.dark) {
    await setTheme(context, true);
  }

  const pages = getMenuPages(menu);
  let failed = 0;
  if (pages.length) {
    const problems = await checkSidebarHover(context, pages[0]);
    console.log(`${problems.length ? "FAIL" : "OK  "}  [${pass.name}] sidebar hover`);
    if (problems.length) {
      failed++;
      report.push(`FAIL  [${pass.name}] sidebar hover (on ${pages[0]})`, ...problems.map((problem) => `      ${problem}`));
    }
  }

  const checkedShapes = new Set();
  for (const url of pages) {
    const problems = await checkPage(context, pass, url, checkedShapes);
    console.log(`${problems.length ? "FAIL" : "OK  "}  [${pass.name}] ${url}`);
    if (problems.length) {
      failed++;
      report.push(`FAIL  [${pass.name}] ${url}`, ...problems.map((problem) => `      ${problem}`));
    }
  }

  if (pass.dark) {
    // Back to the theme the user had: the instance may be a real one
    await setTheme(context, menu.theme === "dark");
  }
  await context.close();
  return { checked: pages.length, failed };
}

// ############################################## i18n keys

// The English strings, as served to the GUI: /lua/locale.lua is a script that sets
// "const ntop_locale = {...};" (the content of scripts/locales/en.lua as JSON)
async function getLocale(request) {
  const script = await (await request.get(`${BASE_URL}/lua/locale.lua`)).text();
  const start = script.indexOf("{");
  const end = script.indexOf(";\n\nfunction i18n");
  return JSON.parse(script.slice(start, end));
}

// "file:line key" of every key used in the sources and missing in the locale
function missingI18nKeys(locale) {
  // As i18n() does: the whole key (keys written with the dots in en.lua), then field by field
  const exists = (key) => locale[key] != null || key.split(".").reduce((value, field) => value?.[field], locale) != null;
  const missing = [];

  const scan = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory() && !I18N_SKIP_DIRS.includes(entry.name)) {
        scan(file);
      } else if (entry.isFile() && I18N_FILES.test(entry.name)) {
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
          if (COMMENT_LINE.test(line)) {
            return;
          }
          for (const use of I18N_USES) {
            for (const [, key] of line.matchAll(use)) {
              if (!exists(key)) {
                missing.push(`${path.relative(NTOPNG_ROOT, file)}:${index + 1} ${key}`);
              }
            }
          }
        });
      }
    }
  };

  for (const dir of I18N_DIRS) {
    if (fs.existsSync(path.join(NTOPNG_ROOT, dir))) {
      scan(path.join(NTOPNG_ROOT, dir));
    }
  }
  return missing;
}

// ############################################## Main

// The Chromium downloaded by npm install (postinstall)
const browser = await chromium.launch();
const adminRequest = (await browser.newContext()).request;
const report = [];
let pagesChecked = 0;
let pagesFailed = 0;

const usesUnprivileged = PASSES.some((pass) => pass.user === UNPRIVILEGED);
if (usesUnprivileged) {
  await addUnprivilegedUser(adminRequest);
}
try {
  for (const pass of PASSES) {
    const { checked, failed } = await checkPass(browser, pass, report);
    pagesChecked += checked;
    pagesFailed += failed;
  }
} finally {
  if (usesUnprivileged) {
    await deleteUnprivilegedUser(adminRequest);
  }
}

const adminContext = await browser.newContext();
await login(adminContext, ADMIN);
const missingKeys = missingI18nKeys(await getLocale(adminContext.request));
if (missingKeys.length) {
  report.push(`FAIL  i18n: keys used in the code and missing in scripts/locales/en.lua`, ...missingKeys.map((key) => `      ${key}`));
}
await browser.close();

report.push(`PAGES ${pagesChecked}   FAIL ${pagesFailed}   I18N MISSING ${missingKeys.length}`);
fs.mkdirSync(path.dirname(REPORT), { recursive: true });
fs.writeFileSync(REPORT, report.join("\n") + "\n");
console.log(`\n${report.join("\n")}`);

process.exit(pagesFailed || missingKeys.length ? 1 : 0);
