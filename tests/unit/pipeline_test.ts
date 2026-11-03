import { assertEquals } from "@std/assert";
import {
  type ApplyPayload,
  buildEntries,
  type CatalogDb,
  ingestUrl,
  type NameResolution,
  type PipelineDeps,
  type TokenResult,
} from "../../supabase/functions/_shared/pipeline.ts";

const dir = new URL("../../supabase/functions/ingest-product-page/fixtures/", import.meta.url);
const html = (f: string) => Deno.readTextFileSync(new URL(f, dir));

// Tiny dictionary standing in for resolve_ingredient_names().
const DICT: Record<string, number> = {
  "aqua": 1,
  "aqua/water/eau": 1,
  "water": 1,
  "glycerin": 2,
  "niacinamide": 3,
  "parfum": 4,
  "parfum/fragrance": 4,
  "linalool": 5,
  "limonene": 6,
};

function fakeDb(overrides: Partial<CatalogDb> = {}) {
  const calls = { applied: [] as ApplyPayload[], failures: [] as Record<string, unknown>[], tokens: 0 };
  const db: CatalogDb = {
    takeToken: (_d): Promise<TokenResult> => {
      calls.tokens++;
      return Promise.resolve({ allowed: true, source_id: 1, trust_level: "trusted" });
    },
    resolveNames: (names) =>
      Promise.resolve(names.map((raw, i): NameResolution => {
        const n = raw.toLowerCase().replace(/\s*\([^)]*\)/g, "").trim();
        const id = DICT[n] ?? null;
        return {
          idx: i + 1,
          raw_name: raw,
          normalized: n,
          match_kind: id ? "canonical" : "none",
          ingredient_id: id,
          suggested_ingredient_id: null,
          inci_name: null,
          similarity: null,
          confidence: id ? 1 : 0,
          accepted: !!id,
        };
      })),
    applyPage: (p) => {
      calls.applied.push(p);
      const unresolved = p.ingredients.filter((e) => e.ingredient_id == null).length;
      return Promise.resolve(
        unresolved ? { status: "held_for_verification", queued: unresolved } : { status: "applied", product_id: 9 },
      );
    },
    recordFailure: (f) => {
      calls.failures.push(f);
      return Promise.resolve({ dead_letter_id: 1, attempts: 1, status: "pending" });
    },
    ...overrides,
  };
  return { db, calls };
}

function deps(db: CatalogDb, pages: Record<string, { status: number; body: string }[]>) {
  const sleeps: number[] = [];
  const fetched: string[] = [];
  const d: PipelineDeps = {
    db,
    fetchPage: (url) => {
      fetched.push(url);
      const seq = pages[url];
      if (!seq) return Promise.resolve({ status: 404, body: "" });
      return Promise.resolve(seq.length > 1 ? seq.shift()! : seq[0]);
    },
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
    random: () => 0.5,
  };
  return { d, sleeps, fetched };
}

const OPTS = { attempts: 3, baseDelayMs: 100, maxDelayMs: 1000 };
const page = (body: string) => [{ status: 200, body }];
const SIMPLE = `<html><head><meta property="og:site_name" content="Velvane Skin"></head><body>
  <h1>Gel Cleanser</h1><h3>Ingredients</h3><p>Aqua, Glycerin, Niacinamide, Water, Parfum, Linalool</p></body></html>`;

Deno.test("happy path: all names resolved -> applied, duplicate Aqua/Water dropped", async () => {
  const { db, calls } = fakeDb();
  const { d } = deps(db, { "https://velvane-skin.example/p/gel": page(SIMPLE) });
  const r = await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  assertEquals(r.status, "applied");
  const sent = calls.applied[0];
  assertEquals(sent.source_domain, "velvane-skin.example");
  assertEquals(sent.ingredients.map((e) => e.ingredient_id), [1, 2, 3, 4, 5]);
  assertEquals(r.status === "applied" && r.parsed.duplicatesDropped, 1);
});

Deno.test("unknown names are sent unresolved -> held for verification (not dropped)", async () => {
  const { db, calls } = fakeDb();
  const { d } = deps(db, {
    "https://ondessa-hair.example/shop/repair-conditioner": page(html("ondessa-repair-conditioner.html")),
  });
  const r = await ingestUrl(d, "https://ondessa-hair.example/shop/repair-conditioner", OPTS);
  assertEquals(r.status, "held_for_verification");
  const unresolved = calls.applied[0].ingredients.filter((e) => e.ingredient_id == null).map((e) => e.raw_name);
  assertEquals(unresolved.includes("Hydrolysed Baobab Protein"), true);
  assertEquals(calls.applied[0].ingredients.length, 17);
});

Deno.test("idempotent payload: same page twice -> identical content hash", async () => {
  const { db, calls } = fakeDb();
  const { d } = deps(db, { "https://velvane-skin.example/p/gel": page(SIMPLE) });
  await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  assertEquals(calls.applied[0].content_hash, calls.applied[1].content_hash);
  assertEquals(calls.applied[0].content_hash.length, 64);
});

Deno.test("rate limited: no fetch, retry-after surfaced", async () => {
  const { db } = fakeDb({
    takeToken: () => Promise.resolve({ allowed: false, reason: "rate_limited", retry_after_ms: 1234 }),
  });
  const { d, fetched } = deps(db, {});
  const r = await ingestUrl(d, "https://petalwright.example/x", OPTS);
  assertEquals(r, { status: "rate_limited", url: "https://petalwright.example/x", retryAfterMs: 1234 });
  assertEquals(fetched.length, 0);
});

Deno.test("unknown or blocked source is rejected; http is rejected before any DB call", async () => {
  let tokenCalls = 0;
  const { db } = fakeDb({
    takeToken: () => {
      tokenCalls++;
      return Promise.resolve({ allowed: false, reason: "unknown_source" });
    },
  });
  const { d } = deps(db, {});
  assertEquals((await ingestUrl(d, "https://nowhere.example/x", OPTS)).status, "rejected");
  const r = await ingestUrl(d, "http://velvane-skin.example/x", OPTS);
  assertEquals(r, { status: "rejected", url: "http://velvane-skin.example/x", reason: "https_required" });
  assertEquals(tokenCalls, 1);
});

Deno.test("flaky origin: 503, 503, 200 -> applied after backoff", async () => {
  const { db } = fakeDb();
  const { d, sleeps } = deps(db, {
    "https://velvane-skin.example/p/gel": [{ status: 503, body: "" }, { status: 503, body: "" }, {
      status: 200,
      body: SIMPLE,
    }],
  });
  const r = await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  assertEquals(r.status, "applied");
  assertEquals(r.status === "applied" && r.attempts, 3);
  assertEquals(sleeps, [75, 150]); // equal jitter with random()=0.5
});

Deno.test("origin down: dead-lettered at fetch stage after max attempts", async () => {
  const { db, calls } = fakeDb();
  const { d, sleeps } = deps(db, { "https://velvane-skin.example/down": [{ status: 503, body: "" }] });
  const r = await ingestUrl(d, "https://velvane-skin.example/down", OPTS);
  assertEquals(r.status, "dead_lettered");
  assertEquals(calls.failures[0].stage, "fetch");
  assertEquals(calls.failures[0].httpStatus, 503);
  assertEquals(sleeps.length, 2);
});

Deno.test("404 is permanent: one attempt, dead-lettered", async () => {
  const { db, calls } = fakeDb();
  const { d, sleeps } = deps(db, {});
  const r = await ingestUrl(d, "https://velvane-skin.example/gone", OPTS);
  assertEquals(r.status === "dead_lettered" && r.attempts, 1);
  assertEquals([calls.failures[0].httpStatus, sleeps.length], [404, 0]);
});

Deno.test("network errors are retried", async () => {
  const { db } = fakeDb();
  let n = 0;
  const { d } = deps(db, {});
  d.fetchPage =
    () => (++n < 2
      ? Promise.reject(new TypeError("connection reset"))
      : Promise.resolve({ status: 200, body: SIMPLE }));
  const r = await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  assertEquals([r.status, n], ["applied", 2]);
});

Deno.test("parse failure -> dead letter (parse stage), nothing applied", async () => {
  const { db, calls } = fakeDb();
  const { d } = deps(db, { "https://halcyra.example/x": page(html("halcyra-broken-page.html")) });
  const r = await ingestUrl(d, "https://halcyra.example/x", OPTS);
  assertEquals([r.status, calls.failures[0].stage, calls.applied.length], ["dead_lettered", "parse", 0]);
});

Deno.test("apply failure (DB rejects) -> dead letter (apply stage)", async () => {
  const { db, calls } = fakeDb({ applyPage: () => Promise.reject(new Error("ingest_apply_page: source is blocked")) });
  const { d } = deps(db, { "https://velvane-skin.example/p/gel": page(SIMPLE) });
  const r = await ingestUrl(d, "https://velvane-skin.example/p/gel", OPTS);
  assertEquals([r.status, calls.failures[0].stage], ["dead_lettered", "apply"]);
});

Deno.test("buildEntries: fuzzy (not accepted) keeps a suggestion, never an id", () => {
  const { entries } = buildEntries(
    [{ raw: "Squalene", optional: false, normalized: "squalene" }],
    [{
      idx: 1,
      raw_name: "Squalene",
      normalized: "squalene",
      match_kind: "fuzzy",
      ingredient_id: null,
      suggested_ingredient_id: 42,
      inci_name: "Squalane",
      similarity: 0.6,
      confidence: 0.51,
      accepted: false,
    }],
  );
  assertEquals([entries[0].ingredient_id, entries[0].suggested_ingredient_id], [null, 42]);
});
