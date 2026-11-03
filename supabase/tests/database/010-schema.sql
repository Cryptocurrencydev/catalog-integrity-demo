begin;
select plan(16);

select tables_are('public', array[
  'brands', 'sources', 'products', 'ingredients', 'ingredient_aliases', 'product_ingredients', 'analysis_cache',
  'ingest_pages', 'verification_queue', 'repair_drafts', 'audit_log', 'ingest_dead_letter',
  'data_quality_reports', 'hygiene_runs'], 'public tables are exactly the catalog + integrity tables');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0, 'RLS is enabled on every public table');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and cmd <> 'SELECT'),
  0, 'no insert/update/delete policies exist: every write goes through definer RPCs');

select ok(not has_table_privilege('service_role', 'public.product_ingredients', 'INSERT'),
  'service_role cannot INSERT product_ingredients');
select ok(not has_table_privilege('service_role', 'public.product_ingredients', 'UPDATE'),
  'service_role cannot UPDATE product_ingredients');
select ok(not has_table_privilege('service_role', 'public.product_ingredients', 'DELETE'),
  'service_role cannot DELETE product_ingredients');
select ok(not has_table_privilege('service_role', 'public.audit_log', 'UPDATE')
          and not has_table_privilege('service_role', 'public.audit_log', 'DELETE'),
  'service_role cannot UPDATE/DELETE audit_log');
select ok(not exists (
    select 1 from information_schema.role_table_grants
    where grantee in ('anon', 'authenticated') and table_schema = 'public' and privilege_type <> 'SELECT'),
  'anon/authenticated hold only SELECT on public tables');

select has_trigger('public', 'product_ingredients', 'product_ingredients_write_guard', 'row guard trigger exists');
select has_trigger('public', 'product_ingredients', 'product_ingredients_truncate_guard', 'truncate guard exists');
select has_trigger('public', 'audit_log', 'audit_log_no_update_delete', 'audit append-only trigger exists');
select has_trigger('public', 'products', 'products_list_columns_guard', 'products hash/count guard exists');

select function_privs_are('public', 'ingest_apply_page', array['jsonb'], 'anon', array[]::text[],
  'anon cannot execute ingest_apply_page');
select function_privs_are('public', 'ingest_apply_page', array['jsonb'], 'authenticated', array[]::text[],
  'authenticated cannot execute ingest_apply_page');
select is(
  (select prosecdef from pg_proc where oid = 'public.repair_product_ingredients(bigint,jsonb,public.provenance_kind,text,text,text)'::regprocedure),
  true, 'repair_product_ingredients is SECURITY DEFINER');
select is(
  (select proconfig from pg_proc where oid = 'public.repair_product_ingredients(bigint,jsonb,public.provenance_kind,text,text,text)'::regprocedure),
  array['search_path=""'], 'repair_product_ingredients pins an empty search_path');

select * from finish();
rollback;
