-- Hot queries, run by scripts/bench.sh as the role that issues them in production.
-- psql variables (:pid, :hash, ...) are set by the script.

-- @product_page anon
select p.id, p.name, b.name as brand, p.category,
  (select jsonb_agg(jsonb_build_object('pos', pi.position, 'inci', i.inci_name, 'provenance', pi.provenance_kind,
                                       'allergen', i.is_allergen) order by pi.position)
     from public.product_ingredients pi join public.ingredients i on i.id = pi.ingredient_id
    where pi.product_id = p.id) as ingredients,
  (select jsonb_agg(jsonb_build_object('kind', c.analysis_kind, 'provider', c.provider, 'output', c.output))
     from public.analysis_cache c
    where c.product_id = p.id and c.invalidated_at is null and not c.quarantined) as analysis
from public.products p join public.brands b on b.id = p.brand_id
where p.id = :pid;

-- @ingredient_search_rls anon
-- naive: the same search as plain SQL under RLS (index unusable, policy hashes all products)
with hits as (
  select ingredient_id, max(sim) as sim from (
    select id as ingredient_id, extensions.similarity(normalized_name, :'term') as sim
    from public.ingredients
    where normalized_name ilike '%' || :'term' || '%' or normalized_name operator(extensions.%) :'term'
    union all
    select ingredient_id, extensions.similarity(alias_normalized, :'term')
    from public.ingredient_aliases
    where alias_normalized ilike '%' || :'term' || '%' or alias_normalized operator(extensions.%) :'term'
  ) t group by ingredient_id order by sim desc limit 5
)
select i.inci_name,
  (select jsonb_agg(x) from (
     select p.id, p.name from public.product_ingredients pi join public.products p on p.id = pi.product_id
     where pi.ingredient_id = i.id and p.status = 'published' order by pi.product_id desc limit 20) x) as products
from hits h join public.ingredients i on i.id = h.ingredient_id
order by h.sim desc;

-- @ingredient_search anon
select public.search_ingredients(:'term');

-- @ingredient_search_body system
-- body of public.search_ingredients (definer: RLS bypassed, visibility filter explicit) so the plan is visible
with hits as (
  select ingredient_id, max(sim) as sim from (
    select i.id as ingredient_id, extensions.similarity(i.normalized_name, :'term') as sim
    from public.ingredients i
    where i.normalized_name ilike '%' || :'term' || '%' or i.normalized_name operator(extensions.%) :'term'
    union all
    select a.ingredient_id, extensions.similarity(a.alias_normalized, :'term')
    from public.ingredient_aliases a
    where a.alias_normalized ilike '%' || :'term' || '%' or a.alias_normalized operator(extensions.%) :'term'
  ) t group by ingredient_id order by max(sim) desc limit 5
)
select i.inci_name,
  (select jsonb_agg(x) from (
     select p.id, p.name from public.product_ingredients pi
     join public.products p on p.id = pi.product_id and p.status = 'published'
     where pi.ingredient_id = i.id order by pi.product_id desc limit 20) x) as products
from hits h join public.ingredients i on i.id = h.ingredient_id
order by h.sim desc;

-- @product_search_rls anon
-- naive: ILIKE under RLS -> seq scan regardless of the trigram index
select p.id, p.name, b.name as brand
from public.products p join public.brands b on b.id = p.brand_id
where p.name_key ilike '%' || :'product_term' || '%'
order by p.id desc
limit 20;

-- @product_search anon
select public.search_products(:'product_term');

-- @cache_lookup service_role
select id, output from public.analysis_cache
where product_id = :pid and analysis_kind = 'safety_narrative' and provider = :'provider'
  and input_hash = md5(:'hash' || '|safety_narrative|' || :'provider' || '|' || :'model' || '|v3')
  and invalidated_at is null and not quarantined;

-- @queue_listing admin
select q.id, q.raw_name, q.reason, q.created_at, p.name as product, b.name as brand, s.inci_name as suggestion
from public.verification_queue q
left join public.products p on p.id = q.product_id
left join public.brands b on b.id = p.brand_id
left join public.ingredients s on s.id = q.suggested_ingredient_id
where q.status = 'pending'
order by q.created_at, q.id
limit 50;

-- @drafts_listing admin
select d.id, d.reason, d.provenance, d.created_at, p.name
from public.repair_drafts d join public.products p on p.id = d.product_id
where d.status = 'pending'
order by d.created_at, d.id
limit 50;

-- @audit_for_product admin
select id, occurred_at, actor_kind, action, diff from public.audit_log
where product_id = :pid order by id desc limit 50;

-- @repair_rpc system
select public.repair_product_ingredients(:pid, :'reordered'::jsonb, 'manual', null, 'bench: swap positions 2/3');

-- @quality_report system
select private.hygiene_quality_report();
