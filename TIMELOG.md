# TIMELOG

Wall-clock timestamps per phase (WAT, UTC+1). Each phase ends when its checks pass.

| Phase | Start | End | Notes |
|---|---|---|---|
| 0. Setup + plan | 10:47 | 10:56 | toolchain check, backend choice asked (user creates hosted project), supabase init on ports 563xx |
| 1. Schema | 10:56 | 10:58 | products, ingredients + aliases, product_ingredients, sources, analysis_cache, queue, drafts, audit_log, dead letter, reports |
| 2. Integrity (guard trigger, repair RPC, drafts) | 10:58 | 11:16 | write-token trigger guard, validated idempotent RPC with diff audit + cache invalidate/quarantine, draft approve/reject |
| 3a. Ingest RPCs + hygiene + RLS migrations | 11:00 | 11:03 | name resolution, rate limiter, dead letter, apply page, pg_cron jobs, privileges + policies |
| 3b. Synthetic INCI generator + local stack up | 11:03 | 11:16 | 1.7k-ingredient dictionary, 18 product types, all migrations + seed applied first try |
| 4. Scraping pipeline (Deno edge function + fixtures) | 11:16 | 11:25 | parser (JSON-LD / marked element / heading strategies), INCI split + normalise, retry/backoff, dead letter, rate limit; 52 unit + 11 e2e tests green |
| 5. pgTAP suite | 11:25 | 11:28 | 9 files: schema/privileges, trigger guard, RPC validation, repair effects + cache, drafts + verification flow, RLS by role, ingest RPCs, hygiene + cron |
| 6. Scale: 50k seed + EXPLAIN before/after | 11:29 | 11:36 | 50,301 products / 1.16M list rows seeded in 59 s; found RLS-blocks-index-use on search, fixed with definer search RPCs + per-role policies |
| 7. Hosted project: link, migrations, 5k seed, edge function deploy | 11:36 | 11:40 | user-created "catalog integrity" (eu-west-3); fixtures embedded in the bundle after the API deploy dropped static files |
| 8. Admin UI (React + Vite + TS) | 11:37 | 11:47 | queue / drafts with diff / quality / audit / ingest tabs; Playwright smoke at 1280px + 390px green |
| 9. CI, README, gitleaks, GitHub + Vercel deploy, live verification | 11:47 | 11:55 | CI 4/4 green on first full run; live UI smoke (desktop + 390px) and live ingest verified |

**Total: 10:47 → 11:55** (≈68 min wall clock).

Results: 167 pgTAP + 54 Deno unit + 12 edge-function e2e + 5 UI unit tests + 14-check Playwright smoke. 50k bench in bench/RESULTS.md.
