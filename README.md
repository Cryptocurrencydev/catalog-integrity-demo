# Catalog integrity on Supabase/Postgres

A working demo of a beauty and personal-care product catalog (skincare and haircare products, scored from their INCI ingredient lists) where **the database enforces catalog integrity**. The app does not. It covers the patterns a live AI catalog needs as it grows from 9k to 40k+ products: a canonical repair RPC behind a trigger guard, provenance on every row, quarantining AI output when its inputs change, a verification queue, admin-reviewed repair drafts, an append-only audit log, a scraping pipeline in Deno edge functions, and nightly hygiene with pg_cron.

**Inciva** is a fictional brand. Every brand, product, URL (`*.example`) and ingredient list is synthetic.

- **Live admin UI:** https://catalog-integrity-demo.vercel.app (the demo admin login is pre-filled)
- **Stack:** Postgres 17 on Supabase (RLS, pg_cron, pg_trgm, plpgsql), Deno edge function, React + Vite + TypeScript admin, GitHub Actions running everything against a local Supabase

```
                 fixture brand pages (no real scraping)
                               │
        ┌──────────────────────▼───────────────────────┐
        │ edge fn  ingest-product-page (Deno)          │
        │  rate-limit token ─ fetch w/ retry+backoff ─ │──► ingest_dead_letter (backoff, abandon after 6)
        │  parse (JSON-LD / marked el / heading) ─     │
        │  INCI split + normalise + dedupe ─           │
        │  alias matching (resolve_ingredient_names)   │
        └──────────────────────┬───────────────────────┘
                               │ one transaction: ingest_apply_page()
         ┌─────────────────────┼─────────────────────────────┐
   all names resolved    unknown / fuzzy names     list would overwrite human-verified
         │               │                         data, or source is suspect
         ▼               ▼                         ▼
 repair_product_   verification_queue ──resolve──► repair_drafts ──admin approve──┐
 ingredients()     (learns aliases)   (all names)                                 │
   │  ▲                                                                           │
   │  └───────────────────────────────── same RPC ◄──────────────────────────────┘
   ├─► product_ingredients (trigger: no other write path)
   ├─► audit_log (append-only diff)
   └─► analysis_cache: invalidate, or quarantine narratives on material change
                     pg_cron 02:00–02:45 UTC: url trust · stale cache · orphans · quality report
```

## Integrity rules, and where each is enforced

All of these live in `supabase/migrations/`. Every write path goes through them: PostgREST, the service role, pg_cron and the SQL editor.

| Rule | Enforced by |
|---|---|
| Ingredient lists change **only** through `repair_product_ingredients()` | `BEFORE INSERT/UPDATE/DELETE/TRUNCATE` trigger on `product_ingredients`. The RPC opens a write token bound to `pg_current_xact_id()` and closes it before returning, so a spoofed token or a later statement in the same transaction is still refused. A second trigger guards `products.ingredients_hash/ingredient_count`. Privileges come first: even `service_role` has no INSERT/UPDATE/DELETE on the table. |
| Lists are validated as a whole | `private.resolve_ingredient_list()` resolves ids, canonical names and aliases, then rejects unknown names, duplicates (including alias duplicates such as Aqua + Water), invalid elements, confidence outside [0,1], scraped rows below the 0.90 threshold, scraped rows without `source_url`, and a `source_url` whose host isn't the named source. Every problem comes back at once as JSON in `DETAIL` (`CI400`). |
| Idempotent upsert | The new list hash is compared with the stored one. An identical call returns `unchanged` and writes nothing, not even an audit row. Positions use a `DEFERRABLE` unique constraint, so a reorder is a single upsert. |
| Provenance never silently downgrades | `provenance_kind` is an ordered enum: `ai_suggested < scraped < manual < verified`. The service role may only apply `scraped` lists. It gets `CI412` if the change would replace manual or verified rows, and the pipeline turns that into a repair draft. A scraped re-confirmation never overwrites verified rows. |
| Untrusted sources can't write the catalog | Lists from a `blocked` source are refused for everyone (`CI423`). Lists from a `suspect` source are refused for the service role and drafted instead. |
| Concurrency | `SELECT … FOR UPDATE` on the product serialises repairs. `p_expected_hash` gives optimistic concurrency (`CI409`), and drafts carry the `base_hash` they were made against. A stale draft is marked `stale` and never applied. |
| Every change is audited with its diff | `audit_log` gets added, removed, moved and provenance-upgraded rows, from/to hash, the cache effect, the actor (JWT `sub` and role) and context such as `draft_id`. |
| Audit log is append-only | A trigger rejects UPDATE, DELETE and TRUNCATE for every role, including the table owner. |
| AI output follows its inputs | `analysis_cache.input_hash` is a **generated column** over (list hash, kind, provider, model, prompt version). `cache_put()` refuses output for a superseded list. When a list changes, every live row is invalidated. On a *material* change, served narratives are also **quarantined** for review. Material means an ingredient was removed, the top 5 (label order roughly follows concentration) changed, or an allergen was added. Deterministic scores are invalidated only. |
| Aliases can't be ambiguous | Triggers stop an alias from shadowing a canonical name, and a new canonical from colliding with an alias. `normalized_name` has a CHECK requiring it to equal `normalize_inci(inci_name)`. |
| Drafts apply through the same RPC | `approve_repair_draft()` (admin only) calls `repair_product_ingredients()` with the draft's `base_hash` and links the draft and the audit row in both directions. Drafts are validated by the same function when they are created. |
| Who can do what | RLS on every table, with no write policies at all. anon and users read the published catalog only. Admins (`app_metadata.role = 'admin'`, settable only with the service key) also read the queues, drafts, audit and reports, and write through admin-checked RPCs. Ingestion RPCs can be executed only by `service_role`. |

Error codes: `CI400` invalid, `CI403` not allowed, `CI404` not found, `CI409` conflict or stale, `CI412` provenance downgrade, `CI423` untrusted source.

## Scraping pipeline (`supabase/functions/ingest-product-page`)

- **Fixtures:** 8 HTML pages that look like brand sites (`fixtures/*.html`, embedded into the bundle at build time). They cover an accordion `<ul>`, JSON-LD with organic footnotes, an `<h3>` with a paragraph, a spec table, a marketplace `data-ingredients` blob in capitals, a `<dl>` with "May contain (+/-)", a flaky origin (503 twice) and a page whose theme dropped the list.
- **INCI handling:** splits only at depth 0, keeps `1,2-Hexanediol` whole, drops footnote lines and flags "may contain" shades as optional. Normalisation (`_shared/inci.ts`) mirrors `public.normalize_inci()`, and `tests/normalize_vectors.json` is asserted against **both** implementations in CI.
- **Alias matching:** exact canonical, then alias (`water/aqua/eau`, `vitamin e`, `fragrance/parfum`, `sulphate`), then derived candidates (parenthetical stripped or inner, slash parts), then a fuzzy trigram suggestion. Fuzzy matches are **never** auto-accepted. They go to the queue with a suggestion (Squalene → Squalane).
- **Idempotent ingest:** `ingest_pages` stores a content hash per URL, so re-ingesting the same content is a no-op. Queue items are de-duplicated by a partial unique index.
- **Per-source rate limiting:** a fixed window in Postgres using an atomic `INSERT … ON CONFLICT … WHERE used < limit`, shared by all workers.
- **Retries:** exponential backoff with jitter on 5xx, 429 and network errors. A 4xx fails immediately. Failures land in `ingest_dead_letter` with DB-side backoff (1, 2, 4… minutes, capped at 6 h, abandoned after 6 attempts). `{"mode":"retry_dead_letters"}` claims due rows with `FOR UPDATE SKIP LOCKED`.
- **The verification loop:** resolving a queue item can learn a global alias, which resolves every open item with that name. When a held page has no open items left, a repair draft is created automatically. An admin approves it and it goes through the canonical RPC.

## Nightly hygiene (pg_cron, UTC)

| Time | Job | What it does |
|---|---|---|
| 02:00 | `url_trust` | Re-probes sources (mocked in `private.url_check_mock`). A failing probe moves a source down one level (trusted → unverified → suspect) and writes an audit row. |
| 02:15 | `stale_cache` | Invalidates expired AI output and raises an alarm on **hash drift** (a live row whose hash differs from its product's). Drift should always be 0; if it isn't, something bypassed the RPC. |
| 02:30 | `cleanup_orphans` | Purges old invalidated cache rows (quarantined rows are kept), marks stale drafts, removes unused learned ingredients after 30 days, clears expired rate windows and old dead letters. It never touches the audit log. |
| 02:45 | `quality_report` | Writes products with no ingredients, duplicates (brand + name + list hash), the low-provenance mix, untrusted-source rows, queue age and stale drafts into `data_quality_reports`. |

Every job runs through `private.run_hygiene_job()`, which records each run in `hygiene_runs`. A failing job is recorded as `ok=false` and doesn't abort the others.

## Scale: 50k products

`scripts/seed-scale.sh 50000` generates the data in-database in **59 s**: 50,301 products, **1.16M** ordered list rows, 243k cache rows, 20k queue rows and 16k audit rows. Lists are realistic and in label order: 18 product types grouped into formula families such as cleanser, emulsion, anhydrous balm, mineral and chemical SPF, shampoo and conditioner. The dictionary has 1,758 INCI names, including the long tail of PEG-n, Polyquaternium-n, peptides, esters, CI colours and botanicals. `scripts/bench.py` drops the workload indexes, runs `EXPLAIN (ANALYZE, BUFFERS)` 7 times per query **as the production role with RLS on**, re-applies `20261103100700_scale_indexes.sql` and runs it again.

| Query | Role | Before (ms) | After (ms) | Plan change |
|---|---|---:|---:|---|
| Product page (list + live AI output) | anon | 17.06 | **0.36** | Seq Scan on `analysis_cache` (243k rows) → `analysis_cache_live_key` |
| Ingredient search, naive SQL under RLS | anon | 14.62 | 14.76 | the index can't help: see below |
| Ingredient search via `search_ingredients()` RPC | anon | 5.30 | **2.40** | parameterised semi-join on `(ingredient_id, product_id)` |
| Product name search, naive SQL under RLS | anon | 24.30 | 24.66 | Seq Scan in both cases |
| Product name search via `search_products()` RPC | anon | 25.03 | **2.44** | trigram GIN `products_name_trgm` |
| AI cache lookup | service_role | 9.35 | **0.03** | Parallel Seq Scan → partial unique index |
| Verification queue, first page | admin | 10.00 | **0.62** | Seq Scan on products + sort → `verification_queue_pending` (partial) |
| Repair drafts, first page | admin | 1.28 | **0.51** | partial index on pending drafts |
| Audit log for a product | admin | 2.06 | **0.26** | `audit_log_product (product_id, id desc)` |
| `repair_product_ingredients()` (reorder, invalidates and quarantines cache) | system | 37.41 | **6.11** | cache invalidation uses the partial live key |
| Nightly quality report (whole catalog) | system | 384.63 | 299.31 | full aggregate; runs nightly |

Full plans: [`bench/plans/before`](bench/plans/before) and [`bench/plans/after`](bench/plans/after). Raw numbers: [`bench/results.json`](bench/results.json).

**What the benchmark found:** under RLS, Postgres won't use an index for a non-LEAKPROOF operator (`ILIKE`, pg_trgm `%`). It also turns the policy's `is_admin() OR EXISTS (…)` into a hash of all 49k published product ids on *every* query. Two fixes are in the migrations:

1. Policies are split per role, so anon gets a plain `EXISTS` with no `OR`.
2. Search goes through `SECURITY DEFINER` RPCs (`search_ingredients`, `search_products`) that write out the same visibility rule (`status = 'published'`) and can use the trigram and reverse-lookup indexes. pgTAP tests assert that these RPCs never return draft products to anon.

```
-- cache lookup, before                                     -- after
Parallel Seq Scan on analysis_cache                         Index Scan using analysis_cache_live_key
  Rows Removed by Filter: 81114   (x3 workers)                Execution Time: 0.028 ms
Execution Time: 9.347 ms
```

### Scaling plan for 40k+ products (and beyond)

1. **Keep writes set-based and per product.** The repair RPC touches one product, one lock, ~25 rows and one audit row. At 6 ms that is ~150 repairs/s per connection, which is plenty for nightly re-scrapes of 40k products. Bulk backfills use the same write-token path inside one transaction, the way `generate_catalog` does.
2. **Indexes follow the open work, not the history.** Queues, drafts and the live cache use partial indexes, so they stay small while the resolved history keeps growing.
3. **Denormalise what hot paths read.** `ingredients_hash` and `ingredient_count` are maintained only by the RPC. That makes "missing ingredients" a partial-index lookup, and the cache key is checkable without joining the list.
4. **Search through definer RPCs with explicit visibility.** Under RLS, `ILIKE` and trigram can't use indexes. Add a `tsvector` column with GIN for multi-word product search when names get longer.
5. **Audit and cache growth.** `audit_log` is append-only with a BRIN index on time. Past ~10M rows, partition it by month (`pg_partman`) and detach old partitions to cold storage. Invalidated cache rows are purged after 30 days, and quarantined rows are kept until someone reviews them.
6. **Pipeline throughput.** Rate limits are per source and live in Postgres, so you can run N edge-function workers (or a queue such as pgmq or Supabase Queues) without overrunning a brand site. Dead letters retry with `SKIP LOCKED`.
7. **Nightly jobs stay O(changed).** The trust re-check works in batches (`p_batch`, `SKIP LOCKED`). The quality report (~300 ms at 50k) is the only full scan. At 500k+, move it to a read replica or make it incremental from `audit_log`.
8. **Tune before scaling up hardware.** Watch `pg_stat_statements` for RLS-shaped plans (hashed SubPlans over products) and add `(select auth.…)` initplans, as the policies here already do.

## Tests

| Suite | Count | What |
|---|---:|---|
| pgTAP (`supabase/tests/database`) | **167** | schema and privileges, trigger guard (including spoofed tokens and same-transaction writes), RPC validation (every error path), repair effects (idempotency, diff, cache invalidate vs quarantine, provenance upgrade without downgrade), drafts and the verification flow end to end, RLS by role (anon / user / admin / service), ingest RPCs (resolution kinds, rate limiter, dead-letter backoff), hygiene and cron |
| Deno unit (`tests/unit`) | **54** | INCI normalise and split, parsing every fixture, retry and backoff, pipeline routing with a fake DB, fixture bundle is current |
| Deno e2e (`tests/integration`) | **12** | the served edge function against the real DB: every fixture route, SQL/TS normaliser parity, auth (service key, admin JWT, non-admin refused) |
| Admin UI (vitest) | **5** | ordered-list diff and the "material change" rule |
| UI smoke (Playwright, `admin/e2e/smoke.mjs`) | 14 checks | sign-in, resolve a queue item, approve a draft, every tab, at 1280px and 390px |

CI (`.github/workflows/ci.yml`) runs gitleaks over the full history, the Deno fmt/lint/typecheck/unit tests, and `supabase start` → `db reset` → plpgsql_check lint → pgTAP → edge function e2e → a 5k scale smoke with the bench. It also runs the UI typecheck, tests and build.

## Run it locally

```bash
supabase start            # ports 563xx; applies migrations + seed (300 products + fixtures)
supabase test db          # pgTAP
deno task test:unit
set -a; eval "$(supabase status -o env)"; set +a; deno task test:integration
scripts/seed-scale.sh 50000 && python3 scripts/bench.py   # 50k + EXPLAIN before/after
cd admin && npm i && npm run dev   # set VITE_SUPABASE_URL / VITE_SUPABASE_KEY in admin/.env.local
```

Demo logins (local and hosted): `admin@catalog-demo.example` / `catalog-demo-2026`. A non-admin `viewer@…` exists locally for RLS tests.

## Layout

```
supabase/migrations/   foundation · catalog schema · integrity · ingest · hygiene · rls · synthetic generator · scale indexes · demo fixtures
supabase/functions/    ingest-product-page (+ fixtures) · _shared (inci, parse, retry, pipeline, db)
supabase/tests/        pgTAP
tests/                 Deno unit + e2e, shared normalisation vectors
bench/                 hot queries, results, before/after plans
admin/                 React + Vite + TS admin UI (Vercel)
TIMELOG.md             time per phase
```

---

Demo by [DC Tech](https://dctechltd.com)
