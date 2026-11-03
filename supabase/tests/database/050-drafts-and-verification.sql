begin;
select plan(24);

create temp table ctx as
select (select id from public.products where status = 'published' and ingredient_count >= 6 order by id offset 3 limit 1) as pid;
grant select on ctx to public;

-- ---------------------------------------------------------------- drafts
select tests.as_admin();
select throws_ok(format($q$select public.create_repair_draft(%s, '["Aqua","Stardust"]', 'manual', 'typo test')$q$, (select pid from ctx)),
  'CI400', null, 'drafts are validated at creation (same validator as apply)');

create temp table d as select public.create_repair_draft((select pid from ctx),
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id) order by case position when 2 then 1 when 1 then 2 else position end)
     from public.product_ingredients where product_id = (select pid from ctx)),
  'manual', 'customer photo shows positions 1/2 swapped') as id;
grant select on d to public;
select isnt((select id from d), null, 'admin can create a draft');
select is(public.create_repair_draft((select pid from ctx),
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id) order by case position when 2 then 1 when 1 then 2 else position end)
     from public.product_ingredients where product_id = (select pid from ctx)),
  'manual', 'same proposal again'), (select id from d), 'an identical pending proposal is de-duplicated');
select is((select base_hash from public.repair_drafts where id = (select id from d)),
  (select ingredients_hash from public.products where id = (select pid from ctx)), 'draft records the base hash it was made against');

select tests.as_user();
select throws_ok(format('select public.approve_repair_draft(%s)', (select id from d)), 'CI403', null, 'non-admins cannot approve');
select is((select count(*)::int from public.repair_drafts), 0, 'non-admins cannot even see drafts (RLS)');

select tests.as_admin();
create temp table a as select public.approve_repair_draft((select id from d), 'matches photo') as r;
grant select on a to public;
select is((select r ->> 'draft_status' from a), 'applied', 'approval applies the draft');
select is((select status::text from public.repair_drafts where id = (select id from d)), 'applied', 'draft marked applied');
select is((select context ->> 'draft_id' from public.audit_log where id = (select (r ->> 'audit_id')::bigint from a)),
  (select id from d)::text, 'the repair audit row links back to the draft');
select is((select applied_audit_id from public.repair_drafts where id = (select id from d)), (select (r ->> 'audit_id')::bigint from a),
  'the draft links to its audit row');
select throws_ok(format('select public.approve_repair_draft(%s)', (select id from d)), 'CI409', null, 'a draft applies once');

-- stale draft: list changes after the draft was made
create temp table d2 as select public.create_repair_draft((select pid from ctx),
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id) order by position desc)
     from public.product_ingredients where product_id = (select pid from ctx)), 'manual', 'reverse it') as id;
grant select on d2 to public;
select public.repair_product_ingredients((select pid from ctx),
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id) order by case position when 2 then 1 when 1 then 2 else position end)
     from public.product_ingredients where product_id = (select pid from ctx)), 'manual', null, 'swap back');
select is(public.approve_repair_draft((select id from d2)) ->> 'status', 'stale', 'approving against a changed list marks it stale');
select is((select status::text from public.repair_drafts where id = (select id from d2)), 'stale', 'stale is persisted, nothing applied');

create temp table d3 as select public.create_repair_draft((select pid from ctx), '["Aqua"]', 'manual', 'nonsense') as id;
grant select on d3 to public;
select throws_ok(format($q$select public.reject_repair_draft(%s, '')$q$, (select id from d3)), 'CI400', null, 'rejection needs a note');
select is(public.reject_repair_draft((select id from d3), 'not supported by label') ->> 'status', 'rejected', 'draft rejected');

-- ----------------------------------------------------- verification flow
select tests.as_service();
create temp table ing as select public.ingest_apply_page(jsonb_build_object(
  'url', 'https://northfern.example/p/test-oil', 'source_domain', 'northfern.example', 'content_hash', 'h1',
  'product', jsonb_build_object('brand', 'Northfern', 'name', 'Test Face Oil', 'category', 'skincare', 'product_type', 'serum'),
  'ingredients', jsonb_build_array(
    jsonb_build_object('raw_name', 'Squalane', 'normalized', 'squalane', 'ingredient_id', (select id from public.ingredients where inci_name = 'Squalane'), 'confidence', 1),
    jsonb_build_object('raw_name', 'Squalene', 'normalized', 'squalene', 'ingredient_id', null, 'confidence', 0.5,
                       'suggested_ingredient_id', (select id from public.ingredients where inci_name = 'Squalane')),
    jsonb_build_object('raw_name', 'Rosehip Seed Oyl', 'normalized', 'rosehip seed oyl', 'ingredient_id', null, 'confidence', 0),
    jsonb_build_object('raw_name', 'Tocopherol', 'normalized', 'tocopherol', 'ingredient_id', (select id from public.ingredients where inci_name = 'Tocopherol'), 'confidence', 1)
  ))) as r;
grant select on ing to public;
select is((select r ->> 'status' from ing), 'held_for_verification', 'unresolved names hold the page');
select is((select (r ->> 'queued')::int from ing), 2, 'two queue items created');

select tests.as_admin();
-- "Squalene" here is a real mislabel for squalane on this brand's site: map it, without a global alias.
select is(public.resolve_verification_item(
  (select id from public.verification_queue where normalized_name = 'rosehip seed oyl' and status = 'pending'),
  p_new_inci_name => 'Rosa Canina Seed Oil', p_add_alias => true) ->> 'alias_added', 'true',
  'resolving with a new canonical ingredient learns the alias');
select ok(exists (select 1 from public.ingredient_aliases where alias_normalized = 'rosehip seed oyl'), 'alias stored');
select is((select count(*)::int from public.repair_drafts where product_id = (select (r ->> 'product_id')::bigint from ing)), 0,
  'no draft while an item is still pending');
create temp table res as select public.resolve_verification_item(
  (select id from public.verification_queue where normalized_name = 'squalene' and status = 'pending'
     and ingest_page_id = (select (r ->> 'page_id')::bigint from ing)),
  p_ingredient_id => (select id from public.ingredients where inci_name = 'Squalane'), p_add_alias => false) as r;
grant select on res to public;
select is(jsonb_array_length((select r -> 'drafts_created' from res)), 1, 'last resolution creates the repair draft');
select is((select jsonb_array_length(proposed) from public.repair_drafts where id = (select (r -> 'drafts_created' ->> 0)::bigint from res)), 3,
  'draft list: Squalane (deduped with Squalene) + Rosa Canina Seed Oil + Tocopherol');
select is(public.approve_repair_draft((select (r -> 'drafts_created' ->> 0)::bigint from res)) ->> 'status', 'applied',
  'approving the draft writes the catalog through the canonical RPC');
select is((select ingredient_count from public.products where id = (select (r ->> 'product_id')::bigint from ing)), 3,
  'the held product now has its list');

select * from finish();
rollback;
