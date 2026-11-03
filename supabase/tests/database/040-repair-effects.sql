begin;
select plan(26);

-- A product with known state: fresh, admin-managed, with live cache rows.
select tests.as_postgres();
insert into public.products (brand_id, name, category, product_type, product_url, status)
values ((select id from public.brands where name = 'Northfern'), 'Test Barrier Cream', 'skincare', 'moisturizer',
        'https://northfern.example/test/barrier-cream', 'published');
create temp table ctx as select (select id from public.products where product_url = 'https://northfern.example/test/barrier-cream') as pid;
grant select on ctx to authenticated, service_role;

select tests.as_admin();
create temp table r1 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Glycerin","Niacinamide","Cetearyl Alcohol","Squalane","Ceramide NP","Xanthan Gum","Phenoxyethanol"]',
  'manual', null, 'initial') as r;
grant select on r1 to public;

select is((select r ->> 'status' from r1), 'applied', 'first list applied');
select is((select (r ->> 'added')::int from r1), 8, 'diff: 8 added');
select is((select ingredient_count from public.products where id = (select pid from ctx)), 8, 'ingredient_count maintained');
select is((select ingredients_hash from public.products where id = (select pid from ctx)), (select r ->> 'hash' from r1),
  'ingredients_hash maintained');
select is((select array_agg(i.inci_name order by pi.position) from public.product_ingredients pi
           join public.ingredients i on i.id = pi.ingredient_id where pi.product_id = (select pid from ctx)),
  array['Aqua','Glycerin','Niacinamide','Cetearyl Alcohol','Squalane','Ceramide NP','Xanthan Gum','Phenoxyethanol'],
  'rows stored in label order');

-- Idempotency
create temp table r2 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Glycerin","Niacinamide","Cetearyl Alcohol","Squalane","Ceramide NP","Xanthan Gum","Phenoxyethanol"]',
  'manual', null, 'same again') as r;
select is((select r ->> 'status' from r2), 'unchanged', 'identical call is a no-op');
select is((select count(*)::int from public.audit_log where product_id = (select pid from ctx)), 1,
  'no-op writes no audit row');

-- Live cache rows for the current list
select tests.as_service();
select public.cache_put((select pid from ctx), 'ingredient_score', 'internal', 'scorer-4', 'v4', (select r ->> 'hash' from r1), '{"score":81}');
select public.cache_put((select pid from ctx), 'safety_narrative', 'anthropic', 'claude-sonnet-5-5', 'v3', (select r ->> 'hash' from r1), '{"summary":"x"}');
select public.cache_put((select pid from ctx), 'safety_narrative', 'openai', 'gpt-5-mini', 'v3', (select r ->> 'hash' from r1), '{"summary":"y"}');
select is((select count(*)::int from public.analysis_cache where product_id = (select pid from ctx) and invalidated_at is null), 3,
  'three live cache rows');
select public.cache_put((select pid from ctx), 'ingredient_score', 'internal', 'scorer-4', 'v4', (select r ->> 'hash' from r1), '{"score":82}');
select is((select count(*)::int from public.analysis_cache where product_id = (select pid from ctx)), 3,
  'cache_put is idempotent per exact input (upsert, not duplicate)');
select throws_ok(format($q$select public.cache_put(%s, 'ingredient_score', 'internal', 'scorer-4', 'v4', 'stale-hash', '{}')$q$,
  (select pid from ctx)), 'CI409', 'output was generated for a superseded ingredient list', 'cache writes for a superseded list are refused');

-- Non-material change: append a non-allergen below the top 5 -> invalidate, no quarantine
select tests.as_admin();
create temp table r3 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Glycerin","Niacinamide","Cetearyl Alcohol","Squalane","Ceramide NP","Xanthan Gum","Phenoxyethanol","Ethylhexylglycerin"]',
  'manual', null, 'add preservative booster') as r;
grant select on r3 to public;
select is((select r ->> 'material' from r3), 'false', 'appending a non-allergen is not material');
select is((select (r ->> 'cache_invalidated')::int from r3), 3, 'all three live cache rows invalidated');
select is((select (r ->> 'cache_quarantined')::int from r3), 0, 'nothing quarantined');
select is((select count(*)::int from public.analysis_cache where product_id = (select pid from ctx) and invalidated_at is null), 0,
  'no live cache rows remain for the old list');

-- Material change: reorder inside the top 5 -> narratives quarantined, scores just invalidated
select tests.as_service();
select public.cache_put((select pid from ctx), 'ingredient_score', 'internal', 'scorer-4', 'v4', (select r ->> 'hash' from r3), '{"score":80}');
select public.cache_put((select pid from ctx), 'safety_narrative', 'anthropic', 'claude-sonnet-5-5', 'v3', (select r ->> 'hash' from r3), '{"summary":"niacinamide third"}');
select tests.as_admin();
create temp table r4 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Niacinamide","Glycerin","Cetearyl Alcohol","Squalane","Ceramide NP","Xanthan Gum","Phenoxyethanol","Ethylhexylglycerin"]',
  'manual', null, 'label shows niacinamide second') as r;
select is((select (r ->> 'moved')::int from r4), 2, 'diff: two ingredients moved');
select is((select r ->> 'material' from r4), 'true', 'a top-5 reorder is material');
select is((select (r ->> 'cache_quarantined')::int from r4), 1, 'the served narrative is quarantined');
select is((select quarantined from public.analysis_cache where product_id = (select pid from ctx)
           and analysis_kind = 'ingredient_score' and ingredients_hash = (select r ->> 'hash' from r3)), false,
  'deterministic scores are invalidated, not quarantined');

-- Audit diff
select is((select diff -> 'moved' from public.audit_log where id = (select (r ->> 'audit_id')::bigint from r4)),
  jsonb_build_array(
    jsonb_build_object('to', 2, 'from', 3, 'inci_name', 'Niacinamide', 'ingredient_id', (select id from public.ingredients where inci_name = 'Niacinamide')),
    jsonb_build_object('to', 3, 'from', 2, 'inci_name', 'Glycerin', 'ingredient_id', (select id from public.ingredients where inci_name = 'Glycerin'))),
  'audit_log records the exact moves');
select is((select actor_kind || '/' || coalesce(actor_id::text, '') from public.audit_log where id = (select (r ->> 'audit_id')::bigint from r4)),
  'admin/00000000-0000-0000-0000-0000000000ad', 'audit_log records who made the change');

-- Removal (material) + allergen addition
create temp table r5 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Niacinamide","Glycerin","Cetearyl Alcohol","Squalane","Xanthan Gum","Phenoxyethanol","Ethylhexylglycerin","Parfum","Linalool"]',
  'manual', null, 'reformulation') as r;
grant select on r5 to public;
select is((select jsonb_array_length(diff -> 'removed') || '/' || jsonb_array_length(diff -> 'added')
           from public.audit_log where id = (select (r ->> 'audit_id')::bigint from r5)), '1/2', 'diff: 1 removed, 2 added');

-- Provenance upgrade only: same list, verified -> rows upgraded, cache untouched
select tests.as_service();
select public.cache_put((select pid from ctx), 'ingredient_score', 'internal', 'scorer-4', 'v4', (select r ->> 'hash' from r5), '{"score":70}');
select tests.as_admin();
create temp table r6 as select public.repair_product_ingredients((select pid from ctx),
  '["Aqua","Niacinamide","Glycerin","Cetearyl Alcohol","Squalane","Xanthan Gum","Phenoxyethanol","Ethylhexylglycerin","Parfum","Linalool"]',
  'verified', null, 'checked against physical label') as r;
select is((select (r ->> 'provenance_upgraded')::int from r6), 10, 'all rows upgraded to verified');
select is((select (r ->> 'cache_invalidated')::int from r6), 0, 'provenance-only change keeps the cache');

-- A later scraped confirmation of the same list never downgrades verified rows
select tests.as_postgres();
update public.sources set trust_level = 'trusted' where domain = 'northfern.example';
select tests.as_service();
create temp table r7 as select public.repair_product_ingredients((select pid from ctx),
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id, 'confidence', 0.99,
     'source_url', 'https://northfern.example/test/barrier-cream') order by position)
     from public.product_ingredients where product_id = (select pid from ctx)), 'scraped', 'northfern.example', 'rescrape') as r;
select is((select r ->> 'status' from r7), 'unchanged', 'scraped confirmation of a verified list is a no-op');
select is((select count(*)::int from public.product_ingredients where product_id = (select pid from ctx) and provenance_kind = 'verified'),
  10, 'verified provenance kept');

select tests.as_postgres();
select is((select count(*)::int from public.audit_log where product_id = (select pid from ctx) and action = 'repair_product_ingredients'), 5,
  'one audit row per effective change (5), none for no-ops');

select * from finish();
rollback;
