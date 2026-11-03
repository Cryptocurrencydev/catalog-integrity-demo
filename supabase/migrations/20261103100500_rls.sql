-- Privileges + row level security.
--   anon / authenticated : read the published catalog only
--   admin (app_metadata.role = 'admin') : also read queues, drafts, audit, reports
--   service_role : ingestion RPCs; NO direct write privilege on product_ingredients
-- All catalog writes go through security-definer RPCs; there are no
-- insert/update/delete policies at all.

-- Start from nothing (Supabase grants broadly by default).
revoke all on all tables in schema public from anon, authenticated, service_role;
revoke all on all sequences in schema public from anon, authenticated, service_role;
revoke execute on all functions in schema public from public, anon, authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon, authenticated, service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated, service_role;

-- Policies may call these two helpers.
grant usage on schema private to anon, authenticated, service_role;
grant execute on function private.is_admin() to anon, authenticated, service_role;
grant execute on function private.caller_kind() to anon, authenticated, service_role;

-- Catalog: readable (rows filtered by RLS).
grant select on public.brands, public.ingredients, public.ingredient_aliases,
                public.products, public.product_ingredients, public.analysis_cache
  to anon, authenticated, service_role;

-- Admin surfaces: readable by authenticated, rows only for admins (RLS).
grant select on public.sources, public.verification_queue, public.repair_drafts, public.audit_log,
                public.data_quality_reports, public.ingest_pages, public.ingest_dead_letter, public.hygiene_runs
  to authenticated, service_role;

-- Service role: may maintain reference data, never the catalog list or the audit trail.
grant insert, update on public.brands, public.sources, public.products to service_role;
grant insert on public.ingredients, public.ingredient_aliases to service_role;

-- RPCs
grant execute on function public.normalize_inci(text) to anon, authenticated, service_role;
grant execute on function public.repair_product_ingredients(bigint, jsonb, public.provenance_kind, text, text, text)
  to authenticated, service_role;
grant execute on function public.create_repair_draft(bigint, jsonb, public.provenance_kind, text, text, text)
  to authenticated, service_role;
grant execute on function public.approve_repair_draft(bigint, text) to authenticated;
grant execute on function public.reject_repair_draft(bigint, text) to authenticated;
grant execute on function public.resolve_verification_item(bigint, bigint, text, boolean, text) to authenticated;
grant execute on function public.reject_verification_item(bigint, text) to authenticated;
grant execute on function public.review_quarantined_cache(bigint, text) to authenticated;
grant execute on function public.resolve_ingredient_names(text[]) to authenticated, service_role;
grant execute on function public.cache_put(bigint, text, text, text, text, text, jsonb, interval) to service_role;
grant execute on function public.ingest_take_token(text) to service_role;
grant execute on function public.ingest_record_failure(text, text, text, text, int, jsonb) to service_role;
grant execute on function public.ingest_claim_dead_letters(int) to service_role;
grant execute on function public.ingest_apply_page(jsonb) to service_role;

-- Enable RLS everywhere in public.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Reference data
create policy brands_read on public.brands for select to anon, authenticated using (true);
create policy ingredients_read on public.ingredients for select to anon, authenticated using (true);
create policy aliases_read on public.ingredient_aliases for select to anon, authenticated using (true);

-- Published catalog.
-- Policies are split per role on purpose: an `is_admin() OR EXISTS (...)`
-- qual stops the planner from using a parameterised semi-join and makes it
-- hash every published product id per query (measured: 11 ms -> 0.3 ms on the
-- 50k ingredient search). anon gets the plain EXISTS form.
create policy products_read_anon on public.products for select to anon
  using (status = 'published');
create policy products_read_auth on public.products for select to authenticated
  using (status = 'published' or (select private.is_admin()));

create policy product_ingredients_read_anon on public.product_ingredients for select to anon
  using (exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));
create policy product_ingredients_read_auth on public.product_ingredients for select to authenticated
  using (
    (select private.is_admin())
    or exists (select 1 from public.products p where p.id = product_id and p.status = 'published')
  );

create policy analysis_cache_read_anon on public.analysis_cache for select to anon
  using (not quarantined and invalidated_at is null
         and exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));
create policy analysis_cache_read_auth on public.analysis_cache for select to authenticated
  using (
    (select private.is_admin())
    or (not quarantined and invalidated_at is null
        and exists (select 1 from public.products p where p.id = product_id and p.status = 'published'))
  );

-- Admin-only reads
create policy sources_admin on public.sources for select to authenticated using ((select private.is_admin()));
create policy queue_admin on public.verification_queue for select to authenticated using ((select private.is_admin()));
create policy drafts_admin on public.repair_drafts for select to authenticated using ((select private.is_admin()));
create policy audit_admin on public.audit_log for select to authenticated using ((select private.is_admin()));
create policy reports_admin on public.data_quality_reports for select to authenticated using ((select private.is_admin()));
create policy ingest_pages_admin on public.ingest_pages for select to authenticated using ((select private.is_admin()));
create policy dead_letter_admin on public.ingest_dead_letter for select to authenticated using ((select private.is_admin()));
create policy hygiene_runs_admin on public.hygiene_runs for select to authenticated using ((select private.is_admin()));

-- The service role bypasses RLS but not privileges: it can read everything it was granted.

-- ---------------------------------------------------------------------------
-- Search RPCs. Under RLS, Postgres will not use an index for a non-LEAKPROOF
-- operator (ILIKE, pg_trgm %) and turns the policy EXISTS into a hash of every
-- published product. These definer functions bypass RLS and apply the same
-- visibility rule explicitly ("published only"), so the trigram and
-- (ingredient_id, product_id) indexes are usable. Measured at 50k in bench/.
-- ---------------------------------------------------------------------------
create or replace function public.search_ingredients(p_term text, p_limit int default 5)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with q as (select public.normalize_inci(p_term) as t),
  hits as (
    select ingredient_id, max(sim) as sim from (
      select i.id as ingredient_id, extensions.similarity(i.normalized_name, q.t) as sim,
             i.normalized_name like '%' || q.t || '%' as substr
      from public.ingredients i, q
      where i.normalized_name ilike '%' || q.t || '%' or i.normalized_name operator(extensions.%) q.t
      union all
      select a.ingredient_id, extensions.similarity(a.alias_normalized, q.t),
             a.alias_normalized like '%' || q.t || '%'
      from public.ingredient_aliases a, q
      where a.alias_normalized ilike '%' || q.t || '%' or a.alias_normalized operator(extensions.%) q.t
    ) t
    where substr or sim >= 0.35
    group by ingredient_id
    order by max(sim) desc
    limit least(greatest(p_limit, 1), 20)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'ingredient_id', i.id, 'inci_name', i.inci_name, 'common_name', i.common_name,
           'is_allergen', i.is_allergen, 'similarity', round(h.sim::numeric, 3),
           'products', (
             select coalesce(jsonb_agg(x), '[]'::jsonb) from (
               select p.id, p.name
               from public.product_ingredients pi
               join public.products p on p.id = pi.product_id and p.status = 'published'
               where pi.ingredient_id = i.id
               order by pi.product_id desc
               limit 20) x)
         ) order by h.sim desc), '[]'::jsonb)
  from hits h join public.ingredients i on i.id = h.ingredient_id
  where length(coalesce((select t from q), '')) >= 3
$$;

create or replace function public.search_products(p_term text, p_limit int default 20)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'brand', x.brand,
                                               'category', x.category, 'ingredient_count', x.ingredient_count)), '[]'::jsonb)
  from (
    select p.id, p.name, b.name as brand, p.category, p.ingredient_count
    from public.products p join public.brands b on b.id = p.brand_id
    where p.name_key ilike '%' || lower(btrim(p_term)) || '%'
      and (p.status = 'published' or private.is_admin())
      and length(btrim(coalesce(p_term, ''))) >= 3
    order by p.id desc
    limit least(greatest(p_limit, 1), 50)
  ) x
$$;

grant execute on function public.search_ingredients(text, int) to anon, authenticated, service_role;
grant execute on function public.search_products(text, int) to anon, authenticated, service_role;

-- Admin: run the data-quality report on demand (same job pg_cron runs nightly).
create or replace function public.run_quality_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'running the quality report requires an admin' using errcode = 'CI403';
  end if;
  return private.run_hygiene_job('quality_report');
end;
$$;
grant execute on function public.run_quality_report() to authenticated;
