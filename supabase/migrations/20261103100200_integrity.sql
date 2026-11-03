-- Integrity rules, enforced in the database:
--   1. product_ingredients (and the product's hash/count) can only be written
--      inside repair_product_ingredients(); a trigger blocks every other path.
--   2. repair_product_ingredients() validates, upserts idempotently, writes a
--      diff to audit_log and invalidates / quarantines dependent AI output.
--   3. audit_log is append-only.
--   4. an alias can never shadow another ingredient's canonical name.
--   5. repair drafts are applied through the same RPC, with optimistic
--      concurrency on the list they were drafted against.

-- ---------------------------------------------------------------------------
-- Write token: a transaction-local flag bound to the current transaction id.
-- Opened only by the canonical RPC (and the bulk seed), closed before it returns.
-- ---------------------------------------------------------------------------
create or replace function private.open_catalog_write()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('catalog.write_token', pg_current_xact_id()::text, true);
end;
$$;

create or replace function private.close_catalog_write()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('catalog.write_token', '', true);
end;
$$;

create or replace function private.catalog_write_open()
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce(current_setting('catalog.write_token', true), '') = pg_current_xact_id()::text
$$;

create or replace function private.guard_product_ingredients()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.catalog_write_open() then
    raise exception 'direct % on product_ingredients is blocked', lower(tg_op)
      using errcode = 'CI403',
            hint = 'Use public.repair_product_ingredients(product_id, ingredients, provenance, source) or a repair draft.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger product_ingredients_write_guard
  before insert or update or delete on public.product_ingredients
  for each row execute function private.guard_product_ingredients();

create trigger product_ingredients_truncate_guard
  before truncate on public.product_ingredients
  for each statement execute function private.guard_product_ingredients();

-- The product's denormalised list hash/count follow the same rule.
create or replace function private.guard_product_list_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.catalog_write_open() then
    return new;
  end if;
  if tg_op = 'INSERT' and (new.ingredients_hash is not null or new.ingredient_count <> 0) then
    raise exception 'products.ingredients_hash / ingredient_count are maintained by repair_product_ingredients()'
      using errcode = 'CI403';
  end if;
  if tg_op = 'UPDATE' and (new.ingredients_hash is distinct from old.ingredients_hash
                           or new.ingredient_count is distinct from old.ingredient_count) then
    raise exception 'products.ingredients_hash / ingredient_count are maintained by repair_product_ingredients()'
      using errcode = 'CI403';
  end if;
  return new;
end;
$$;

create trigger products_list_columns_guard
  before insert or update on public.products
  for each row execute function private.guard_product_list_columns();

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger products_touch_updated_at
  before update on public.products
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Alias shadowing: one normalised term maps to exactly one ingredient.
-- ---------------------------------------------------------------------------
create or replace function private.guard_alias_shadowing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'ingredient_aliases' then
    if exists (select 1 from public.ingredients i
               where i.normalized_name = new.alias_normalized) then
      raise exception 'alias "%" collides with a canonical ingredient name', new.alias
        using errcode = 'CI409';
    end if;
  else
    if exists (select 1 from public.ingredient_aliases a
               where a.alias_normalized = new.normalized_name) then
      raise exception 'ingredient "%" collides with an existing alias', new.inci_name
        using errcode = 'CI409';
    end if;
  end if;
  return new;
end;
$$;

create trigger ingredient_aliases_no_shadow
  before insert or update on public.ingredient_aliases
  for each row execute function private.guard_alias_shadowing();

create trigger ingredients_no_shadow
  before insert or update of normalized_name on public.ingredients
  for each row execute function private.guard_alias_shadowing();

-- ---------------------------------------------------------------------------
-- Append-only audit log
-- ---------------------------------------------------------------------------
create or replace function private.audit_log_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit_log is append-only (% rejected)', lower(tg_op) using errcode = 'CI403';
end;
$$;

create trigger audit_log_no_update_delete
  before update or delete on public.audit_log
  for each row execute function private.audit_log_append_only();

create trigger audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function private.audit_log_append_only();

create or replace function private.write_audit(
  p_action text,
  p_entity text,
  p_entity_id text,
  p_product_id bigint,
  p_diff jsonb default '{}',
  p_context jsonb default '{}'
)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
  v_ctx jsonb := coalesce(nullif(current_setting('catalog.audit_context', true), '')::jsonb, '{}');
begin
  insert into public.audit_log (actor_id, actor_kind, action, entity, entity_id, product_id, diff, context)
  values (private.actor_id(), private.caller_kind(), p_action, p_entity, p_entity_id, p_product_id,
          coalesce(p_diff, '{}'), v_ctx || coalesce(p_context, '{}'))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Hash of an ordered ingredient list (identity + order; provenance excluded).
-- ---------------------------------------------------------------------------
create or replace function private.list_hash(p_ids bigint[])
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(array_to_string(p_ids, ','))
$$;

create or replace function private.product_list_hash(p_product_id bigint)
returns text
language sql
stable
set search_path = ''
as $$
  select private.list_hash(array_agg(ingredient_id order by position))
  from public.product_ingredients
  where product_id = p_product_id
$$;

-- ---------------------------------------------------------------------------
-- Validate + resolve a proposed list. Returns the resolved ordered list as
-- jsonb, or raises CI400 with every problem listed in DETAIL (JSON).
-- Elements: "Glycerin" | {"inci_name": "..."} | {"ingredient_id": 12}
--           (+ optional raw_name, confidence, source_url)
-- ---------------------------------------------------------------------------
create or replace function private.resolve_ingredient_list(
  p_ingredients jsonb,
  p_provenance public.provenance_kind,
  p_source_domain text
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_settings private.settings%rowtype;
  v_errors jsonb;
  v_list jsonb;
begin
  select * into v_settings from private.settings;

  if p_ingredients is null or jsonb_typeof(p_ingredients) <> 'array' then
    raise exception 'ingredients must be a JSON array' using errcode = 'CI400';
  end if;
  if jsonb_array_length(p_ingredients) = 0 then
    raise exception 'ingredient list must not be empty' using errcode = 'CI400';
  end if;
  if jsonb_array_length(p_ingredients) > v_settings.max_ingredients_per_product then
    raise exception 'ingredient list has % entries (max %)',
      jsonb_array_length(p_ingredients), v_settings.max_ingredients_per_product using errcode = 'CI400';
  end if;

  with input as (
    select t.ord::int as pos, t.e, jsonb_typeof(t.e) as kind
    from jsonb_array_elements(p_ingredients) with ordinality as t (e, ord)
  ),
  parsed as (
    select
      pos, kind,
      case when kind = 'object' and jsonb_typeof(e -> 'ingredient_id') = 'number'
                and (e ->> 'ingredient_id') ~ '^[0-9]{1,18}$'
           then (e ->> 'ingredient_id')::bigint end as id_in,
      case when kind = 'string' then public.normalize_inci(e #>> '{}')
           when kind = 'object' and jsonb_typeof(e -> 'inci_name') = 'string'
           then public.normalize_inci(e ->> 'inci_name') end as name_key,
      case when kind = 'object' then e -> 'ingredient_id' end as id_raw,
      case when kind = 'string' then e #>> '{}'
           when kind = 'object' then coalesce(e ->> 'raw_name', e ->> 'inci_name') end as raw_name,
      case when kind = 'object' then e -> 'confidence' end as conf_raw,
      case when kind = 'object' then e ->> 'source_url' end as source_url
    from input
  ),
  resolved as (
    select
      p.*,
      coalesce(
        (select i.id from public.ingredients i where i.id = p.id_in),
        (select i.id from public.ingredients i where p.id_in is null and i.normalized_name = p.name_key),
        (select a.ingredient_id from public.ingredient_aliases a where p.id_in is null and a.alias_normalized = p.name_key)
      ) as ingredient_id,
      case when jsonb_typeof(p.conf_raw) = 'number' then (p.conf_raw #>> '{}')::numeric end as confidence
    from parsed p
  ),
  ranked as (
    select r.*, min(r.pos) over (partition by r.ingredient_id) as first_pos
    from resolved r
  ),
  problems as (
    select pos, jsonb_build_object('position', pos, 'error', err) || extra as problem
    from ranked
    cross join lateral (
      values
        (kind not in ('object', 'string'), 'invalid_element', '{}'::jsonb),
        (kind in ('object', 'string') and id_in is null and name_key is null, 'missing_ingredient', '{}'::jsonb),
        (id_raw is not null and id_in is null and jsonb_typeof(id_raw) <> 'null', 'invalid_ingredient_id', '{}'::jsonb),
        ((id_in is not null or name_key is not null) and ingredient_id is null, 'unknown_ingredient',
           jsonb_build_object('name', coalesce(raw_name, id_in::text))),
        (ingredient_id is not null and pos > first_pos, 'duplicate_ingredient',
           jsonb_build_object('ingredient_id', ingredient_id, 'first_position', first_pos)),
        (conf_raw is not null and jsonb_typeof(conf_raw) <> 'null'
           and (confidence is null or confidence < 0 or confidence > 1), 'invalid_confidence', '{}'::jsonb),
        (p_provenance in ('scraped', 'ai_suggested') and kind = 'object' and confidence is null
           and (conf_raw is null or jsonb_typeof(conf_raw) = 'null'), 'confidence_required', '{}'::jsonb),
        (p_provenance in ('scraped', 'ai_suggested') and kind = 'string', 'confidence_required', '{}'::jsonb),
        (p_provenance = 'scraped' and confidence is not null and confidence between 0 and 1
           and confidence < v_settings.min_scraped_confidence, 'confidence_below_threshold',
           jsonb_build_object('confidence', confidence, 'min', v_settings.min_scraped_confidence)),
        (p_provenance = 'scraped' and coalesce(source_url, '') = '', 'source_url_required', '{}'::jsonb),
        (coalesce(source_url, '') <> '' and (
            source_url !~ '^https://'
            or p_source_domain is null
            or not (
              lower(substring(source_url from '^https://([^/:?#]+)')) = p_source_domain
              or lower(substring(source_url from '^https://([^/:?#]+)')) like '%.' || p_source_domain
            )), 'source_url_mismatch', jsonb_build_object('source_url', source_url, 'source', p_source_domain))
    ) as checks (failed, err, extra)
    where failed
  )
  select
    (select jsonb_agg(problem order by pos) from problems),
    (select jsonb_agg(
              jsonb_build_object(
                'position', r.pos,
                'ingredient_id', r.ingredient_id,
                'inci_name', i.inci_name,
                'raw_name', r.raw_name,
                'confidence', r.confidence,
                'source_url', nullif(r.source_url, '')
              ) order by r.pos)
       from ranked r join public.ingredients i on i.id = r.ingredient_id)
  into v_errors, v_list;

  if v_errors is not null then
    raise exception 'ingredient list rejected: % problem(s)', jsonb_array_length(v_errors)
      using errcode = 'CI400', detail = v_errors::text;
  end if;

  return v_list;
end;
$$;

-- ---------------------------------------------------------------------------
-- The canonical write path.
-- ---------------------------------------------------------------------------
create or replace function public.repair_product_ingredients(
  p_product_id bigint,
  p_ingredients jsonb,
  p_provenance public.provenance_kind,
  p_source text default null,
  p_reason text default null,
  p_expected_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller text := private.caller_kind();
  v_product public.products%rowtype;
  v_source public.sources%rowtype;
  v_list jsonb;
  v_new_ids bigint[];
  v_old_ids bigint[];
  v_new_hash text;
  v_old_hash text;
  v_hash_changed boolean;
  v_old_max public.provenance_kind;
  v_diff jsonb;
  v_upgrades int;
  v_material boolean := false;
  v_invalidated int := 0;
  v_quarantined int := 0;
  v_audit_id bigint;
  v_now timestamptz := now();
begin
  if v_caller not in ('admin', 'service', 'system') then
    raise exception 'repair_product_ingredients requires an admin or the service role' using errcode = 'CI403';
  end if;
  if p_provenance is null then
    raise exception 'provenance is required' using errcode = 'CI400';
  end if;
  if v_caller = 'service' and p_provenance <> 'scraped' then
    raise exception 'the service role may only apply scraped lists; % lists go through repair drafts', p_provenance
      using errcode = 'CI403';
  end if;

  -- Row lock serialises concurrent repairs of the same product.
  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'product % not found', p_product_id using errcode = 'CI404';
  end if;
  if v_product.status = 'archived' then
    raise exception 'product % is archived', p_product_id using errcode = 'CI400';
  end if;

  if p_source is not null then
    select * into v_source from public.sources where domain = lower(btrim(p_source));
    if not found then
      raise exception 'unknown source %', p_source using errcode = 'CI400';
    end if;
    if v_source.trust_level = 'blocked' then
      raise exception 'source % is blocked', v_source.domain using errcode = 'CI423';
    end if;
  end if;
  if p_provenance = 'scraped' then
    if v_source.id is null then
      raise exception 'scraped lists must name their source' using errcode = 'CI400';
    end if;
    if v_source.trust_level = 'suspect' and v_caller = 'service' then
      raise exception 'source % is suspect; its lists need admin review', v_source.domain using errcode = 'CI423';
    end if;
  end if;

  if p_expected_hash is not null and v_product.ingredients_hash is distinct from p_expected_hash then
    raise exception 'ingredient list changed since this repair was prepared'
      using errcode = 'CI409',
            detail = jsonb_build_object('expected', p_expected_hash, 'actual', v_product.ingredients_hash)::text;
  end if;

  v_list := private.resolve_ingredient_list(p_ingredients, p_provenance, v_source.domain);

  select array_agg((e ->> 'ingredient_id')::bigint order by (e ->> 'position')::int)
    into v_new_ids from jsonb_array_elements(v_list) e;
  select array_agg(ingredient_id order by position), max(provenance_kind)
    into v_old_ids, v_old_max
  from public.product_ingredients where product_id = p_product_id;

  v_new_hash := private.list_hash(v_new_ids);
  v_old_hash := v_product.ingredients_hash;
  v_hash_changed := v_new_hash is distinct from v_old_hash;

  -- Never let an automated source overwrite human-reviewed data.
  if v_hash_changed and v_caller = 'service' and v_old_max > p_provenance then
    raise exception 'list has % rows; a % list cannot replace it automatically', v_old_max, p_provenance
      using errcode = 'CI412', hint = 'Create a repair draft for admin review instead.';
  end if;

  select count(*) into v_upgrades
  from public.product_ingredients pi
  join jsonb_to_recordset(v_list) as n (ingredient_id bigint, position int) on n.ingredient_id = pi.ingredient_id
  where pi.product_id = p_product_id and pi.position = n.position and pi.provenance_kind < p_provenance;

  if not v_hash_changed and v_upgrades = 0 then
    return jsonb_build_object('status', 'unchanged', 'changed', false, 'product_id', p_product_id, 'hash', v_new_hash);
  end if;

  with old as (
    select pi.ingredient_id, pi.position, pi.provenance_kind
    from public.product_ingredients pi where pi.product_id = p_product_id
  ),
  new as (
    select n.ingredient_id, n.position, n.inci_name
    from jsonb_to_recordset(v_list) as n (ingredient_id bigint, position int, inci_name text)
  )
  select jsonb_build_object(
    'added', coalesce((
      select jsonb_agg(jsonb_build_object('ingredient_id', n.ingredient_id, 'inci_name', n.inci_name,
                                          'position', n.position) order by n.position)
      from new n where not exists (select 1 from old o where o.ingredient_id = n.ingredient_id)), '[]'),
    'removed', coalesce((
      select jsonb_agg(jsonb_build_object('ingredient_id', o.ingredient_id, 'inci_name', i.inci_name,
                                          'position', o.position) order by o.position)
      from old o join public.ingredients i on i.id = o.ingredient_id
      where not exists (select 1 from new n where n.ingredient_id = o.ingredient_id)), '[]'),
    'moved', coalesce((
      select jsonb_agg(jsonb_build_object('ingredient_id', n.ingredient_id, 'inci_name', n.inci_name,
                                          'from', o.position, 'to', n.position) order by n.position)
      from new n join old o on o.ingredient_id = n.ingredient_id where o.position <> n.position), '[]'),
    'provenance_upgraded', coalesce((
      select jsonb_agg(jsonb_build_object('ingredient_id', n.ingredient_id, 'inci_name', n.inci_name,
                                          'from', o.provenance_kind, 'to', p_provenance) order by n.position)
      from new n join old o on o.ingredient_id = n.ingredient_id
      where o.position = n.position and o.provenance_kind < p_provenance), '[]')
  ) into v_diff;

  -- Material change => previously served narratives may now be wrong.
  if v_old_hash is not null and v_hash_changed then
    v_material :=
      jsonb_array_length(v_diff -> 'removed') > 0
      or (v_old_ids[1:5] is distinct from v_new_ids[1:5])
      or exists (
        select 1 from jsonb_array_elements(v_diff -> 'added') a
        join public.ingredients i on i.id = (a ->> 'ingredient_id')::bigint
        where i.is_allergen);
  end if;

  perform private.open_catalog_write();

  delete from public.product_ingredients pi
  where pi.product_id = p_product_id
    and pi.ingredient_id <> all (v_new_ids);

  insert into public.product_ingredients as pi
    (product_id, ingredient_id, position, raw_name, provenance_kind, source_id, source_url, scraped_at,
     confidence, updated_at)
  select p_product_id, n.ingredient_id, n.position, n.raw_name, p_provenance, v_source.id, n.source_url,
         case when p_provenance = 'scraped' then v_now end, n.confidence, v_now
  from jsonb_to_recordset(v_list) as n (ingredient_id bigint, position int, raw_name text, confidence numeric,
                                        source_url text)
  on conflict (product_id, ingredient_id) do update
    set position = excluded.position,
        raw_name = excluded.raw_name,
        provenance_kind = excluded.provenance_kind,
        source_id = excluded.source_id,
        source_url = excluded.source_url,
        scraped_at = excluded.scraped_at,
        confidence = excluded.confidence,
        updated_at = excluded.updated_at
    where pi.position <> excluded.position
       or pi.provenance_kind < excluded.provenance_kind;

  update public.products
     set ingredients_hash = v_new_hash,
         ingredient_count = cardinality(v_new_ids)
   where id = p_product_id;

  perform private.close_catalog_write();

  if v_old_hash is not null and v_hash_changed then
    if v_material then
      -- Narratives may have made claims about what is (no longer) in the product.
      update public.analysis_cache
         set quarantined = true,
             quarantined_at = v_now,
             quarantine_reason = 'ingredients_changed',
             invalidated_at = v_now,
             invalidated_reason = 'ingredients_changed'
       where product_id = p_product_id
         and invalidated_at is null
         and analysis_kind <> 'ingredient_score';
      get diagnostics v_quarantined = row_count;
    end if;
    update public.analysis_cache
       set invalidated_at = v_now,
           invalidated_reason = 'ingredients_changed'
     where product_id = p_product_id
       and invalidated_at is null;
    get diagnostics v_invalidated = row_count;
  end if;

  v_audit_id := private.write_audit(
    'repair_product_ingredients', 'product', p_product_id::text, p_product_id,
    v_diff || jsonb_build_object(
      'from_hash', v_old_hash, 'to_hash', v_new_hash,
      'provenance', p_provenance, 'source', v_source.domain,
      'material', v_material,
      'cache', jsonb_build_object('invalidated', v_invalidated, 'quarantined', v_quarantined)),
    jsonb_build_object('reason', p_reason));

  return jsonb_build_object(
    'status', 'applied',
    'changed', true,
    'product_id', p_product_id,
    'hash', v_new_hash,
    'previous_hash', v_old_hash,
    'added', jsonb_array_length(v_diff -> 'added'),
    'removed', jsonb_array_length(v_diff -> 'removed'),
    'moved', jsonb_array_length(v_diff -> 'moved'),
    'provenance_upgraded', jsonb_array_length(v_diff -> 'provenance_upgraded'),
    'material', v_material,
    'cache_invalidated', v_invalidated,
    'cache_quarantined', v_quarantined,
    'audit_id', v_audit_id);
end;
$$;

comment on function public.repair_product_ingredients(bigint, jsonb, public.provenance_kind, text, text, text) is
  'The only write path for product ingredient lists. Validates, upserts idempotently, audits the diff and invalidates/quarantines dependent analysis_cache rows.';

-- ---------------------------------------------------------------------------
-- Repair drafts
-- ---------------------------------------------------------------------------
create or replace function public.create_repair_draft(
  p_product_id bigint,
  p_proposed jsonb,
  p_provenance public.provenance_kind,
  p_reason text,
  p_source text default null,
  p_created_via text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller text := private.caller_kind();
  v_product public.products%rowtype;
  v_source public.sources%rowtype;
  v_list jsonb;
  v_id bigint;
  v_via text;
begin
  if v_caller not in ('admin', 'service', 'system') then
    raise exception 'create_repair_draft requires an admin or the service role' using errcode = 'CI403';
  end if;
  v_via := coalesce(p_created_via, case when v_caller = 'service' then 'pipeline' else 'admin' end);
  if v_caller = 'service' and v_via = 'admin' then
    raise exception 'the service role cannot create admin drafts' using errcode = 'CI403';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if not found then
    raise exception 'product % not found', p_product_id using errcode = 'CI404';
  end if;
  if p_source is not null then
    select * into v_source from public.sources where domain = lower(btrim(p_source));
    if not found then
      raise exception 'unknown source %', p_source using errcode = 'CI400';
    end if;
  end if;

  -- Same validation as the apply path, so a draft that exists is a draft that can apply.
  v_list := private.resolve_ingredient_list(p_proposed, p_provenance, v_source.domain);

  insert into public.repair_drafts (product_id, proposed, provenance, source_id, reason, base_hash, created_via, created_by)
  values (p_product_id, v_list, p_provenance, v_source.id, p_reason, v_product.ingredients_hash, v_via, private.actor_id())
  on conflict (product_id, md5(proposed::text)) where status = 'pending' do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.repair_drafts
    where product_id = p_product_id and md5(proposed::text) = md5(v_list::text) and status = 'pending';
    return v_id;
  end if;

  perform private.write_audit('repair_draft_created', 'repair_draft', v_id::text, p_product_id,
    jsonb_build_object('provenance', p_provenance, 'entries', jsonb_array_length(v_list), 'base_hash', v_product.ingredients_hash),
    jsonb_build_object('reason', p_reason, 'created_via', v_via));
  return v_id;
end;
$$;

create or replace function public.approve_repair_draft(p_draft_id bigint, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.repair_drafts%rowtype;
  v_current_hash text;
  v_result jsonb;
  v_source_domain text;
begin
  if not private.is_admin() then
    raise exception 'approving repair drafts requires an admin' using errcode = 'CI403';
  end if;

  select * into v_draft from public.repair_drafts where id = p_draft_id for update;
  if not found then
    raise exception 'repair draft % not found', p_draft_id using errcode = 'CI404';
  end if;
  if v_draft.status <> 'pending' then
    raise exception 'repair draft % is already %', p_draft_id, v_draft.status using errcode = 'CI409';
  end if;

  select ingredients_hash into v_current_hash from public.products where id = v_draft.product_id for update;
  if v_current_hash is distinct from v_draft.base_hash then
    update public.repair_drafts
       set status = 'stale', reviewed_by = private.actor_id(), reviewed_at = now(),
           review_note = coalesce(p_note, 'product list changed after this draft was created')
     where id = p_draft_id;
    perform private.write_audit('repair_draft_stale', 'repair_draft', p_draft_id::text, v_draft.product_id,
      jsonb_build_object('base_hash', v_draft.base_hash, 'current_hash', v_current_hash));
    return jsonb_build_object('status', 'stale', 'draft_id', p_draft_id);
  end if;

  select domain into v_source_domain from public.sources where id = v_draft.source_id;

  perform set_config('catalog.audit_context', jsonb_build_object('draft_id', p_draft_id)::text, true);
  v_result := public.repair_product_ingredients(
    v_draft.product_id, v_draft.proposed, v_draft.provenance, v_source_domain,
    'repair draft #' || p_draft_id || ': ' || v_draft.reason, v_draft.base_hash);
  perform set_config('catalog.audit_context', '', true);

  update public.repair_drafts
     set status = 'applied', reviewed_by = private.actor_id(), reviewed_at = now(), review_note = p_note,
         applied_audit_id = (v_result ->> 'audit_id')::bigint
   where id = p_draft_id;

  perform private.write_audit('repair_draft_approved', 'repair_draft', p_draft_id::text, v_draft.product_id,
    jsonb_build_object('result', v_result - 'product_id'), jsonb_build_object('note', p_note));

  return v_result || jsonb_build_object('draft_id', p_draft_id, 'draft_status', 'applied');
end;
$$;

create or replace function public.reject_repair_draft(p_draft_id bigint, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.repair_drafts%rowtype;
begin
  if not private.is_admin() then
    raise exception 'rejecting repair drafts requires an admin' using errcode = 'CI403';
  end if;
  if coalesce(length(btrim(p_note)), 0) < 3 then
    raise exception 'a rejection note is required' using errcode = 'CI400';
  end if;
  select * into v_draft from public.repair_drafts where id = p_draft_id for update;
  if not found then
    raise exception 'repair draft % not found', p_draft_id using errcode = 'CI404';
  end if;
  if v_draft.status <> 'pending' then
    raise exception 'repair draft % is already %', p_draft_id, v_draft.status using errcode = 'CI409';
  end if;
  update public.repair_drafts
     set status = 'rejected', reviewed_by = private.actor_id(), reviewed_at = now(), review_note = p_note
   where id = p_draft_id;
  perform private.write_audit('repair_draft_rejected', 'repair_draft', p_draft_id::text, v_draft.product_id,
    '{}', jsonb_build_object('note', p_note));
  return jsonb_build_object('status', 'rejected', 'draft_id', p_draft_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- AI cache writes: refused for a list that is no longer current.
-- ---------------------------------------------------------------------------
create or replace function public.cache_put(
  p_product_id bigint,
  p_analysis_kind text,
  p_provider text,
  p_model text,
  p_prompt_version text,
  p_ingredients_hash text,
  p_output jsonb,
  p_ttl interval default '30 days'
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current text;
  v_id bigint;
begin
  if private.caller_kind() not in ('service', 'system') then
    raise exception 'cache_put requires the service role' using errcode = 'CI403';
  end if;
  select ingredients_hash into v_current from public.products where id = p_product_id;
  if not found then
    raise exception 'product % not found', p_product_id using errcode = 'CI404';
  end if;
  if v_current is distinct from p_ingredients_hash then
    raise exception 'output was generated for a superseded ingredient list' using errcode = 'CI409',
      detail = jsonb_build_object('current', v_current, 'given', p_ingredients_hash)::text;
  end if;
  insert into public.analysis_cache (product_id, analysis_kind, provider, model, prompt_version, ingredients_hash, output, expires_at)
  values (p_product_id, p_analysis_kind, p_provider, p_model, p_prompt_version, p_ingredients_hash, p_output, now() + p_ttl)
  on conflict (product_id, analysis_kind, provider, input_hash) where invalidated_at is null
  do update set output = excluded.output, expires_at = excluded.expires_at, created_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.review_quarantined_cache(p_cache_id bigint, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.analysis_cache%rowtype;
begin
  if not private.is_admin() then
    raise exception 'reviewing quarantined output requires an admin' using errcode = 'CI403';
  end if;
  select * into v_row from public.analysis_cache where id = p_cache_id and quarantined for update;
  if not found then
    raise exception 'quarantined cache row % not found', p_cache_id using errcode = 'CI404';
  end if;
  update public.analysis_cache
     set quarantined = false, quarantined_at = null,
         quarantine_reason = quarantine_reason || ' (reviewed)'
   where id = p_cache_id;
  perform private.write_audit('cache_quarantine_reviewed', 'analysis_cache', p_cache_id::text, v_row.product_id,
    jsonb_build_object('reason', v_row.quarantine_reason), jsonb_build_object('note', p_note));
  return jsonb_build_object('status', 'reviewed', 'cache_id', p_cache_id);
end;
$$;
