// Counts one UTC day's website page views from Cloud Run request log entries,
// by the rules the website applies to its own request log
// (src/lib/proxy/requestLog.ts in DevelopmentFinanceObservatory/website), for
// capture-website-page-history.sh.
//
// Usage: node website-page-history-classify.mjs <isbot_dir> <date>
//
// <isbot_dir> is an npm prefix holding isbot 5.2.2, the version the website
// pins; any other version is refused, since the bot rule must be the
// website's own. stdin holds one entry per line, as `gcloud logging read
// --format='value(httpRequest.status,httpRequest.requestUrl,httpRequest.userAgent)'`
// prints it: status, URL and user agent, separated by tabs. The user agent
// comes last, so a tab inside it stays part of it.
//
// An entry is a page view when its URL's host is developmentfinance.org or
// www.developmentfinance.org, its status is 2xx, and its kind is page, so its
// path is neither a static asset nor an API path and its query has no _rsc
// parameter. Cloud Run's log has no request headers, so the _rsc parameter,
// which Next.js adds to every RSC fetch and router prefetch, stands in for the
// website's rsc and next-router-prefetch headers. Next.js sends it bare, with
// no value, when its cache-busting hash is empty, so a bare _rsc counts too.
// A page view is a bot page view when the user agent is empty or isbot flags
// it. Every method counts, as in the website.
//
// Prints one JSON line, {"date", "page_views", "bot_page_views"}, on stdout,
// and the entries read on stderr. A line without a whole-number status exits
// 1, naming its line number but not its content, and so does a day with no
// entries, which no public day has.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { createInterface } from "node:readline";

const ISBOT_VERSION = "5.2.2";
const PUBLIC_HOSTS = new Set([
  "developmentfinance.org",
  "www.developmentfinance.org",
]);
// The website's STATIC_ASSET and API_PATHS.
const STATIC_ASSET =
  /^\/_next\/|\.(?:png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf)$/i;
const API_PATHS = ["/api", "/mcp", "/openapi.json", "/codes"];

const fail = (message) => {
  process.stderr.write(`${message}\n`);
  process.exit(1);
};

const [isbotDir, date] = process.argv.slice(2);
if (!isbotDir || !/^\d{4}-\d{2}-\d{2}$/.test(date ?? "")) {
  fail(
    "usage: node website-page-history-classify.mjs <isbot_dir> <YYYY-MM-DD>",
  );
}
const isbotPackage = join(isbotDir, "node_modules", "isbot", "package.json");
const { version } = JSON.parse(readFileSync(isbotPackage, "utf8"));
if (version !== ISBOT_VERSION) {
  fail(
    `isbot in ${isbotDir} is ${version}; the website's rule needs ${ISBOT_VERSION}`,
  );
}
const { isbot } = createRequire(isbotPackage)("isbot");

const isApiPath = (path) =>
  API_PATHS.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));

// True when the request is a page view on the public site.
const isPublicPageView = (status, requestUrl) => {
  if (status < 200 || status > 299) return false;
  let url;
  try {
    url = new URL(requestUrl);
  } catch {
    return false;
  }
  return (
    PUBLIC_HOSTS.has(url.hostname) &&
    !STATIC_ASSET.test(url.pathname) &&
    !isApiPath(url.pathname) &&
    !url.searchParams.has("_rsc")
  );
};

let read = 0;
let pageViews = 0;
let botPageViews = 0;
for await (const line of createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
})) {
  read += 1;
  const [statusField, requestUrl = "", ...userAgentParts] = line.split("\t");
  if (!/^\d+$/.test(statusField))
    fail(`${date}: line ${read} has no whole-number status`);
  if (!isPublicPageView(Number(statusField), requestUrl)) continue;
  const userAgent = userAgentParts.join("\t");
  if (!userAgent || isbot(userAgent)) botPageViews += 1;
  else pageViews += 1;
}

process.stderr.write(`${date}: ${read} entries read\n`);
if (read === 0) {
  fail(
    `${date}: no entries were read, so the day has expired from the log or the filter matched nothing`,
  );
}
process.stdout.write(
  `${JSON.stringify({ date, page_views: pageViews, bot_page_views: botPageViews })}\n`,
);
