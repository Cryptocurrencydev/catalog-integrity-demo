begin;
select plan(25);

-- Make sure every visibility class exists.
select tests.as_postgres();
create temp table expected as select
  (select count(*)::int from public.products where status = 'published') as published,
  (select count(*)::int from public.products) as all_products,
  (select count(*)::int from public.verification_queue) as queue,
  (select count(*)::int from public.product_ingredients pi join public.products p on p.id = pi.product_id where p.status = 'published') as pub_rows,
  (select count(*)::int from public.analysis_cache c join public.products p on p.id = c.product_id
     where p.status = 'published' and not c.quarantined and c.invalidated_at is null) as live_cache;
grant select on expected to public;
select cmp_ok((select all_products - published from expected), '>', 0, 'fixture has unpublished products');

-- anon
select tests.as_anon();
select is((select count(*)::int from public.products), (select published from expected), 'anon sees only published products');
select is((select count(*)::int from public.products where status <> 'published'), 0, 'anon sees no draft/archived products');
select is((select count(*)::int from public.product_ingredients), (select pub_rows from expected), 'anon sees only published lists');
select is((select count(*)::int from public.analysis_cache), (select live_cache from expected),
  'anon sees only live, unquarantined AI output for published products');
select ok((select count(*) from public.ingredients) > 0, 'anon can read the ingredient dictionary');
select throws_ok('select count(*) from public.verification_queue', '42501', null, 'anon cannot read the verification queue');
select throws_ok('select count(*) from public.audit_log', '42501', null, 'anon cannot read the audit log');
select throws_ok($q$insert into public.brands (name, slug) values ('X', 'x')$q$, '42501', null, 'anon cannot write');
select is((select count(*)::int from jsonb_array_elements(public.search_ingredients('glycerin') -> 0 -> 'products') x
           join public.products p on p.id = (x ->> 'id')::bigint), 20,
  'search_ingredients (definer) returns only products anon can see');
select tests.as_postgres();
create temp table hidden as select id, name from public.products where status = 'draft' order by id limit 1;
grant select on hidden to public;
select tests.as_anon();
select ok(not exists (select 1 from jsonb_array_elements(public.search_products((select name from hidden))) x
                      where (x ->> 'id')::bigint = (select id from hidden)),
  'search_products (definer) never returns draft products to anon');
select tests.as_admin();
select ok(exists (select 1 from jsonb_array_elements(public.search_products((select name from hidden))) x
                  where (x ->> 'id')::bigint = (select id from hidden)),
  'admins can find draft products');
select tests.as_anon();

-- ordinary authenticated user
select tests.as_user();
select is((select count(*)::int from public.products), (select published from expected), 'users see only published products');
select is((select count(*)::int from public.verification_queue), 0, 'users see no queue rows');
select is((select count(*)::int from public.repair_drafts), 0, 'users see no drafts');
select is((select count(*)::int from public.audit_log), 0, 'users see no audit rows');
select throws_ok($q$select public.resolve_verification_item(1, 1)$q$, 'CI403', null, 'users cannot resolve queue items');
select throws_ok($q$select public.ingest_take_token('northfern.example')$q$, '42501', null, 'users cannot call ingestion RPCs');

-- admin
select tests.as_admin();
select is((select count(*)::int from public.products), (select all_products from expected), 'admins see every product');
select is((select count(*)::int from public.verification_queue), (select queue from expected), 'admins see the whole queue');
select ok((select count(*) from public.data_quality_reports) > 0, 'admins see quality reports');
select throws_ok($q$update public.verification_queue set status = 'resolved'$q$, '42501', null,
  'even admins cannot write tables directly (RPCs only)');

-- service role
select tests.as_service();
select ok((select count(*) from public.verification_queue) > 0, 'service role reads the queue');
select throws_ok($q$delete from public.product_ingredients where product_id = 1$q$, '42501', null,
  'service role cannot write product_ingredients');
select is((public.ingest_take_token('northfern.example')) ->> 'allowed', 'true', 'service role can take an ingest token');

select * from finish();
rollback;
