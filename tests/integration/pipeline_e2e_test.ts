// End-to-end: the deployed (local) edge function against the real database.
// Run on a freshly reset database (CI does `supabase db reset` first).
// Env: API_URL, SERVICE_ROLE_KEY (from `supabase status -o env`).
import { assert, assertEquals } from "@std/assert";

const API = Deno.env.get("API_URL") ?? "http://127.0.0.1:56321";
const KEY = Deno.env.get("SERVICE_ROLE_KEY")!;
const headers = { apikey: KEY, authorization: `Bearer ${KEY}`, "content-type": "application/json" };

async function ingest(body: unknown, auth = true) {
  const res = await fetch(`${API}/functions/v1/ingest-product-page`, {
    method: "POST",
    headers: auth ? headers : { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}

async function rest(path: string) {
  const res = await fetch(`${API}/rest/v1/${path}`, { headers });
  assert(res.ok, `${path}: ${res.status} ${await res.clone().text()}`);
  return await res.json();
}

async function rpc(fn: string, args: unknown) {
  const res = await fetch(`${API}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  return { status: res.status, json: await res.json() };
}

const url = {
  velvane: "https://velvane-skin.example/products/hydrating-facial-cleanser",
  northfern: "https://northfern.example/p/niacinamide-10-serum",
  ondessa: "https://ondessa-hair.example/shop/repair-conditioner",
  saltglass: "https://saltglass.example/products/mineral-sunscreen-spf-30",
  dermadeals: "https://dermadeals.example/item/velvane-hydrating-cleanser-150ml",
  balm: "https://petalwright.example/products/lip-conditioning-balm",
  down: "https://petalwright.example/products/overnight-lip-mask",
  broken: "https://halcyra.example/products/calm-barrier-cream",
};

Deno.test("SQL and TS normalisers agree on every shared vector", async () => {
  const vectors: { input: string; expected: string | null }[] = JSON.parse(
    await Deno.readTextFile(new URL("../normalize_vectors.json", import.meta.url)),
  );
  for (const v of vectors) {
    const r = await rpc("normalize_inci", { p_name: v.input });
    assertEquals(r.json, v.expected, `normalize_inci(${JSON.stringify(v.input)})`);
  }
});

Deno.test("function refuses callers without the service key", async () => {
  const r = await ingest({ url: url.velvane }, false);
  assertEquals(r.status, 401);
});

Deno.test("brand page with alias mess -> applied, published, scraped provenance", async () => {
  const r = await ingest({ url: url.velvane });
  const res = r.json.results[0];
  assertEquals(res.status, "applied");
  assertEquals(res.parsed.duplicatesDropped, 1); // "Water" repeats "Aqua/Water/Eau"
  const [p] = await rest(
    `products?product_url=eq.${encodeURIComponent(url.velvane)}&select=id,status,ingredient_count`,
  );
  assertEquals([p.status, p.ingredient_count], ["published", 22]);
  const rows = await rest(
    `product_ingredients?product_id=eq.${p.id}&select=position,raw_name,provenance_kind,confidence,ingredients(inci_name)&order=position`,
  );
  assertEquals(rows[0].ingredients.inci_name, "Aqua");
  assertEquals(rows[0].raw_name, "Aqua/Water/Eau");
  assertEquals(rows.find((x: any) => x.raw_name === "Tocopherol (Vitamin E)").ingredients.inci_name, "Tocopherol");
  assert(rows.every((x: any) => x.provenance_kind === "scraped" && x.confidence >= 0.9));
});

Deno.test("re-ingesting identical content is a no-op", async () => {
  const before = await rest(`audit_log?select=id&order=id.desc&limit=1`);
  const r = await ingest({ url: url.velvane });
  assertEquals(r.json.results[0].status, "unchanged");
  const after = await rest(`audit_log?select=id&order=id.desc&limit=1`);
  assertEquals(after[0].id, before[0].id);
});

Deno.test("JSON-LD page with footnotes + 1,2-Hexanediol -> applied", async () => {
  const r = await ingest({ url: url.northfern });
  assertEquals(r.json.results[0].status, "applied");
  assertEquals(r.json.results[0].db.added, 19);
});

Deno.test("unknown / low-confidence names go to the queue, not the catalog", async () => {
  const r = await ingest({ url: url.ondessa });
  const res = r.json.results[0];
  assertEquals(res.status, "held_for_verification");
  const q = await rest(
    `verification_queue?ingest_page_id=eq.${res.db.page_id}&status=eq.pending&select=raw_name,reason`,
  );
  assertEquals(q.map((x: any) => x.raw_name).sort(), [
    "Hydrolysed Baobab Protein",
    "Sodium Cocoyl Glycinate",
    "Squalene",
  ]);
  const [p] = await rest(`products?id=eq.${res.db.product_id}&select=status,ingredient_count`);
  assertEquals([p.status, p.ingredient_count], ["draft", 0]);
  // re-ingest does not duplicate queue items
  await ingest({ url: url.ondessa });
  const q2 = await rest(`verification_queue?ingest_page_id=eq.${res.db.page_id}&status=eq.pending&select=id`);
  assertEquals(q2.length, 3);
});

Deno.test("scrape that differs from a human-verified list becomes a repair draft", async () => {
  const [before] = await rest(
    `products?product_url=eq.${encodeURIComponent(url.saltglass)}&select=id,ingredients_hash`,
  );
  const r = await ingest({ url: url.saltglass });
  assertEquals(r.json.results[0].status, "drafted");
  const [after] = await rest(`products?id=eq.${before.id}&select=ingredients_hash`);
  assertEquals(after.ingredients_hash, before.ingredients_hash);
  const drafts = await rest(`repair_drafts?product_id=eq.${before.id}&status=eq.pending&select=created_via,base_hash`);
  assertEquals(drafts.length, 1);
  assertEquals([drafts[0].created_via, drafts[0].base_hash], ["pipeline", before.ingredients_hash]);
});

Deno.test("suspect marketplace source cannot write the catalog directly -> draft", async () => {
  const r = await ingest({ url: url.dermadeals });
  assertEquals(r.json.results[0].status, "drafted");
  assert(String(r.json.results[0].db.reason).includes("suspect"));
});

Deno.test("flaky origin succeeds after retries; dead origin is dead-lettered; per-source rate limit", async () => {
  const r = await ingest({ urls: [url.balm, url.down, url.balm] });
  const [balm, down, third] = r.json.results;
  assertEquals(balm.status, "applied");
  assert(balm.attempts >= 1);
  assertEquals([down.status, down.stage, down.attempts], ["dead_lettered", "fetch", 3]);
  // petalwright.example allows 2 requests/minute
  assertEquals(third.status, "rate_limited");
  assert(third.retryAfterMs > 0);
  const dl = await rest(`ingest_dead_letter?url=eq.${encodeURIComponent(url.down)}&select=stage,http_status,status`);
  assertEquals(dl[0], { stage: "fetch", http_status: 503, status: "pending" });
});

Deno.test("page without an ingredient list is dead-lettered at the parse stage", async () => {
  const r = await ingest({ url: url.broken });
  assertEquals([r.json.results[0].status, r.json.results[0].stage], ["dead_lettered", "parse"]);
});

Deno.test("the service role still cannot write product_ingredients directly", async () => {
  const res = await fetch(`${API}/rest/v1/product_ingredients`, {
    method: "POST",
    headers,
    body: JSON.stringify({ product_id: 1, ingredient_id: 1, position: 99, provenance_kind: "manual" }),
  });
  assertEquals(res.status, 403);
  await res.body?.cancel();
});

async function signIn(email: string) {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: Deno.env.get("ANON_KEY") ?? KEY, "content-type": "application/json" },
    body: JSON.stringify({ email, password: "catalog-demo-2026" }),
  });
  const body = await res.json();
  assert(body.access_token, `sign-in failed for ${email}`);
  return body.access_token as string;
}

Deno.test("signed-in admins may trigger an ingest; ordinary users may not", async () => {
  const call = async (jwt: string) => {
    const res = await fetch(`${API}/functions/v1/ingest-product-page`, {
      method: "POST",
      headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
      body: JSON.stringify({ url: url.northfern }),
    });
    return { status: res.status, body: await res.json() };
  };
  assertEquals((await call(await signIn("viewer@catalog-demo.example"))).status, 401);
  const admin = await call(await signIn("admin@catalog-demo.example"));
  assertEquals(admin.status, 200);
  assertEquals(admin.body.results[0].status, "unchanged");
});
