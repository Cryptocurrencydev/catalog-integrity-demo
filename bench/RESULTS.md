# Benchmark at 50,301 products

50,301 products, 1,162,167 list rows, 1,758 ingredients, 426 aliases, 243,342 cache rows, 20,105 queue rows (2,042 pending), 16,609 audit rows.

Median of 7 warm runs of `EXPLAIN (ANALYZE, BUFFERS)`, each inside a rolled-back transaction, as the role that issues the query in production (RLS on).

| Query | Role | Before (ms) | After (ms) | Speed-up |
|---|---|---:|---:|---:|
| product_page | anon | 17.06 | 0.36 | 48x |
| ingredient_search_rls | anon | 14.62 | 14.76 | 1x |
| ingredient_search | anon | 5.30 | 2.40 | 2x |
| ingredient_search_body | system | 3.27 | 3.28 | 1x |
| product_search_rls | anon | 24.30 | 24.66 | 1x |
| product_search | anon | 25.03 | 2.44 | 10x |
| cache_lookup | service_role | 9.35 | 0.03 | 360x |
| queue_listing | admin | 10.00 | 0.62 | 16x |
| drafts_listing | admin | 1.28 | 0.51 | 3x |
| audit_for_product | admin | 2.06 | 0.26 | 8x |
| repair_rpc | system | 37.41 | 6.11 | 6x |
| quality_report | system | 384.63 | 299.31 | 1x |

Plans: `bench/plans/before/*.txt` and `bench/plans/after/*.txt`.
