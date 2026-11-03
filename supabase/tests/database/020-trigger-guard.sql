begin;
select plan(13);

create temp table ctx as
select (select id from public.products where ingredient_count >= 10 and status = 'published' order by id limit 1) as pid;

-- Direct writes are blocked even for the table owner / superuser session.
select throws_ok(format('delete from public.product_ingredients where product_id = %s', (select pid from ctx)),
  'CI403', null, 'direct DELETE is blocked');
select throws_ok(format('update public.product_ingredients set position = position where product_id = %s', (select pid from ctx)),
  'CI403', null, 'direct UPDATE is blocked');
select throws_ok(format(
  'insert into public.product_ingredients (product_id, ingredient_id, position, provenance_kind) values (%s, (select max(id) from public.ingredients), 299, ''manual'')',
  (select pid from ctx)), 'CI403', null, 'direct INSERT is blocked');
select throws_ok('truncate public.product_ingredients', 'CI403', null, 'TRUNCATE is blocked');

select throws_ok(format('update public.products set ingredients_hash = ''x'' where id = %s', (select pid from ctx)),
  'CI403', null, 'products.ingredients_hash cannot be edited directly');
select throws_ok(format('update public.products set ingredient_count = 0 where id = %s', (select pid from ctx)),
  'CI403', null, 'products.ingredient_count cannot be edited directly');
select lives_ok(format('update public.products set name = name || '' (renamed)'' where id = %s', (select pid from ctx)),
  'other product columns stay editable');

-- A spoofed token for some other transaction id does not open the guard.
select throws_ok(format(
  $q$select set_config('catalog.write_token', '12345', true); delete from public.product_ingredients where product_id = %s$q$,
  (select pid from ctx)), 'CI403', null, 'a token not bound to this transaction is rejected');

-- The token is closed again before the RPC returns.
select lives_ok(format($q$select public.repair_product_ingredients(%s,
  (select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id) order by position desc)
     from public.product_ingredients where product_id = %s), 'manual', null, 'reverse for test')$q$,
  (select pid from ctx), (select pid from ctx)), 'the canonical RPC can write');
select throws_ok(format('delete from public.product_ingredients where product_id = %s', (select pid from ctx)),
  'CI403', null, 'after the RPC returns, direct writes in the same transaction are blocked again');

-- Alias shadowing
select throws_ok($q$insert into public.ingredient_aliases (alias_normalized, alias, ingredient_id)
  values ('glycerin', 'Glycerin', (select id from public.ingredients where inci_name = 'Niacinamide'))$q$,
  'CI409', null, 'an alias cannot shadow a canonical ingredient name');
select throws_ok($q$insert into public.ingredients (inci_name, normalized_name) values ('Glycerine', 'glycerine')$q$,
  'CI409', null, 'a new canonical ingredient cannot collide with an existing alias');
select throws_ok($q$insert into public.ingredients (inci_name, normalized_name) values ('Odd Name', 'odd  name')$q$,
  '23514', null, 'normalized_name must equal normalize_inci(inci_name)');

select * from finish();
rollback;
