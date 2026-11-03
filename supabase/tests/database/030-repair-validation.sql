begin;
select plan(24);

create temp table ctx as
select
  (select id from public.products where ingredient_count >= 10 and status = 'published'
     and not exists (select 1 from public.product_ingredients pi where pi.product_id = products.id and pi.provenance_kind > 'scraped')
   order by id limit 1) as scraped_pid,
  (select id from public.products where product_url = 'https://saltglass.example/products/mineral-sunscreen-spf-30') as verified_pid,
  (select id from public.products where status = 'archived' order by id limit 1) as archived_pid;
grant select on ctx to anon, authenticated, service_role;

create temp view v as select
  (select scraped_pid from ctx) as s,
  (select verified_pid from ctx) as v,
  (select archived_pid from ctx) as a,
  (select domain from public.sources s join public.products p on p.source_id = s.id where p.id = (select scraped_pid from ctx)) as dom,
  (select product_url from public.products where id = (select scraped_pid from ctx)) as url;
grant select on v to anon, authenticated, service_role;

-- who may call
select tests.as_anon();
select throws_ok($q$select public.repair_product_ingredients(1, '["Aqua"]', 'manual')$q$, '42501', null,
  'anon has no EXECUTE on the repair RPC');
select tests.as_user();
select throws_ok($q$select public.repair_product_ingredients(1, '["Aqua"]', 'manual')$q$, 'CI403', null,
  'a non-admin authenticated user is refused');
select tests.as_service();
select throws_ok($q$select public.repair_product_ingredients(1, '["Aqua"]', 'manual')$q$, 'CI403', null,
  'service role cannot apply manual lists');
select throws_ok($q$select public.repair_product_ingredients(1, '["Aqua"]', 'verified')$q$, 'CI403', null,
  'service role cannot apply verified lists');
select throws_ok($q$select public.repair_product_ingredients(1, '[{"inci_name":"Aqua","confidence":0.9}]', 'ai_suggested')$q$,
  'CI403', null, 'service role cannot apply ai_suggested lists (drafts only)');

select tests.as_admin();
select throws_ok($q$select public.repair_product_ingredients(999999999, '["Aqua"]', 'manual')$q$, 'CI404', null,
  'unknown product');
select throws_ok(format($q$select public.repair_product_ingredients(%s, '["Aqua"]', 'manual')$q$, (select a from v)),
  'CI400', null, 'archived products cannot be repaired');
select throws_ok(format($q$select public.repair_product_ingredients(%s, '{"a":1}', 'manual')$q$, (select s from v)),
  'CI400', 'ingredients must be a JSON array', 'list must be an array');
select throws_ok(format($q$select public.repair_product_ingredients(%s, '[]', 'manual')$q$, (select s from v)),
  'CI400', 'ingredient list must not be empty', 'list must not be empty');

select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s, '["Aqua", "Glycerin", "Moonbeam Essence", 42]', 'manual')$q$,
     (select s from v))) ->> 'detail')::jsonb,
  '[{"name": "Moonbeam Essence", "error": "unknown_ingredient", "position": 3},
    {"error": "invalid_element", "position": 4}]'::jsonb,
  'every problem is reported, with positions, in DETAIL');

select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s, '["Aqua", "Glycerin", "Water"]', 'manual')$q$,
     (select s from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'duplicate_ingredient', 'an alias that resolves to an ingredient already listed is a duplicate');

select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s, '[{"inci_name":"Aqua","confidence":1.7}]', 'manual')$q$,
     (select s from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'invalid_confidence', 'confidence must be within [0,1]');

select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s, '["Aqua"]', 'ai_suggested')$q$,
     (select s from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'confidence_required', 'ai_suggested rows must carry a confidence');

select tests.as_service();
select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s,
     '[{"inci_name":"Aqua","confidence":0.75,"source_url":"%s"}]', 'scraped', '%s')$q$,
     (select s from v), (select url from v), (select dom from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'confidence_below_threshold', 'scraped rows below the confidence threshold are refused');
select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s, '[{"inci_name":"Aqua","confidence":0.99}]', 'scraped', '%s')$q$,
     (select s from v), (select dom from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'source_url_required', 'scraped rows need a source_url');
select is(
  (tests.err(format($q$select public.repair_product_ingredients(%s,
     '[{"inci_name":"Aqua","confidence":0.99,"source_url":"https://elsewhere.example/p"}]', 'scraped', '%s')$q$,
     (select s from v), (select dom from v))) ->> 'detail')::jsonb -> 0 ->> 'error',
  'source_url_mismatch', 'source_url must belong to the named source');
select throws_ok(format($q$select public.repair_product_ingredients(%s, '[{"inci_name":"Aqua","confidence":0.99}]', 'scraped')$q$,
  (select s from v)), 'CI400', 'scraped lists must name their source', 'scraped lists need a source');
select throws_ok(format($q$select public.repair_product_ingredients(%s,
  '[{"inci_name":"Aqua","confidence":0.99,"source_url":"https://nowhere.example/x"}]', 'scraped', 'nowhere.example')$q$,
  (select s from v)), 'CI400', 'unknown source nowhere.example', 'unknown source');
select throws_ok(format($q$select public.repair_product_ingredients(%s,
  '[{"inci_name":"Aqua","confidence":0.99,"source_url":"https://dermadeals.example/x"}]', 'scraped', 'dermadeals.example')$q$,
  (select s from v)), 'CI423', null, 'suspect sources cannot feed the catalog automatically');

select tests.as_postgres();
update public.sources set trust_level = 'blocked' where domain = 'beautyaisle.example';
select tests.as_admin();
select throws_ok(format($q$select public.repair_product_ingredients(%s, '["Aqua"]', 'manual', 'beautyaisle.example')$q$,
  (select s from v)), 'CI423', null, 'blocked sources are refused even for admins');

select throws_ok(format($q$select public.repair_product_ingredients(%s, '["Aqua"]', 'manual', null, null, 'not-the-hash')$q$,
  (select s from v)), 'CI409', 'ingredient list changed since this repair was prepared',
  'optimistic concurrency: expected hash must match');

-- Never let an automated source overwrite human-verified data
select tests.as_service();
select throws_ok(format($q$select public.repair_product_ingredients(%s,
  '[{"inci_name":"Aqua","confidence":0.99,"source_url":"https://saltglass.example/x"}]', 'scraped', 'saltglass.example')$q$,
  (select v from v)), 'CI412', null, 'service role cannot replace a verified list (provenance downgrade)');

select tests.as_postgres();
select is((select count(*)::int from public.audit_log
           where product_id in ((select scraped_pid from ctx), (select verified_pid from ctx)) and occurred_at >= now()), 0,
  'rejected calls write nothing to audit_log');
select is((select ingredient_count from public.products where id = (select verified_pid from ctx)), 11,
  'verified list untouched');

select * from finish();
rollback;
