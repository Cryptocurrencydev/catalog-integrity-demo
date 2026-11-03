// UI smoke test: sign in, walk every tab, resolve a queue item, approve a draft,
// screenshot desktop + 390px mobile. Usage: node e2e/smoke.mjs [baseUrl] [outDir]
import { chromium } from "playwright";
const BASE = process.argv[2] ?? "http://localhost:5179";
const OUT = process.argv[3] ?? "e2e/screens";
const browser = await chromium.launch();
const errors = [];
const check = (c, m) => { if (!c) throw new Error("FAIL: " + m); console.log("ok -", m); };

for (const [label, viewport] of [["desktop", { width: 1280, height: 860 }], ["mobile", { width: 390, height: 844 }]]) {
  const page = await browser.newPage({ viewport });
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.goto(BASE);
  await page.getByRole("button", { name: "Sign in as demo admin" }).click();
  await page.getByText(/pending/).first().waitFor();
  await page.locator("article").first().waitFor();
  check(await page.locator("article").count() > 0, `${label}: queue shows items`);
  await page.screenshot({ path: `${OUT}/${label}-queue.png` });

  if (label === "desktop") {
    const first = page.locator("article").first();
    const raw = await first.locator(".raw").innerText();
    const accept = first.getByRole("button", { name: /^Accept/ });
    if (await accept.count()) {
      await accept.click();
      await page.locator(".toast").waitFor();
      check(/Resolved/.test(await page.locator(".toast").innerText()), `resolve "${raw}" via suggestion -> toast`);
    }
  }

  await page.getByRole("button", { name: /Repair drafts/ }).click();
  await page.locator(".diff li").first().waitFor();
  check(await page.locator(".diff li").count() > 3, `${label}: draft diff rendered`);
  await page.screenshot({ path: `${OUT}/${label}-drafts.png`, fullPage: label === "mobile" });
  if (label === "desktop") {
    await page.getByRole("button", { name: "Approve & apply" }).click();
    await page.locator(".toast", { hasText: /Draft #/ }).waitFor();
    const t = await page.locator(".toast").innerText();
    check(/applied|stale/.test(t), `approve draft -> "${t.slice(0, 90)}"`);
  }

  await page.getByRole("button", { name: "Data quality" }).click();
  await page.locator(".kpi").first().waitFor();
  check(await page.locator(".kpi").count() >= 8, `${label}: quality KPIs`);
  await page.screenshot({ path: `${OUT}/${label}-quality.png`, fullPage: true });

  await page.getByRole("button", { name: "Audit log" }).click();
  await page.locator(".audit-row").first().waitFor();
  check(await page.locator(".audit-row").count() > 5, `${label}: audit rows`);
  await page.screenshot({ path: `${OUT}/${label}-audit.png` });

  await page.getByRole("button", { name: "Ingest", exact: true }).click();
  await page.locator("article").first().waitFor();
  await page.screenshot({ path: `${OUT}/${label}-ingest.png` });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  check(!overflow, `${label}: no horizontal page overflow`);
  check(await page.getByRole("link", { name: "DC Tech" }).getAttribute("href") === "https://dctechltd.com", `${label}: DC Tech credit links to dctechltd.com`);
  await page.close();
}
await browser.close();
if (errors.length) { console.log("console errors:\n" + errors.join("\n")); process.exit(1); }
console.log("UI smoke passed");
