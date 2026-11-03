-- Ingestion support for the scraping pipeline (service role only) and the
-- admin verification workflow that feeds unresolved names back into the
-- catalog via repair drafts.

-- ---------------------------------------------------------------------------
-- Name resolution: exact canonical -> exact alias -> derived candidates
-- (parenthetical stripped / inner / slash parts) -> fuzzy trigram suggestion.
-- Fuzzy matches are never auto-accepted; they become queue suggestions.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_ingredient_names(p_names text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_min numeric;
  v_out jsonb := '[]'::jsonb;
  v_raw text;
  v_norm text;
  v_idx int := 0;
  v_cand text;
  v_cands text[];
  v_cand_no int;
  v_id bigint;
  v_kind text;
  v_term text;
  v_sim real;
  v_conf numeric;
begin
  if private.caller_kind() not in ('service', 'admin', 'system') then
    raise exception 'resolve_ingredient_names requires the service role or an admin' using errcode = 'CI403';
  end if;
  if cardinality(p_names) > 300 then
    raise exception 'at most 300 names per call' using errcode = 'CI400';
  end if;
  select min_scraped_confidence into v_min from private.settings;

  foreach v_raw in array coalesce(p_names, '{}') loop
    v_idx := v_idx + 1;
    v_norm := public.normalize_inci(v_raw);
    v_id := null; v_kind := 'none'; v_term := null; v_sim := null; v_conf := 0;

    v_cands := array_remove(array[
      v_norm,
      nullif(btrim(regexp_replace(v_norm, '\s*\([^)]*\)\s*', ' ', 'g')), ''),
      nullif(btrim(substring(v_norm from '\(([^)]*)\)')), '')
    ] || coalesce(string_to_array(v_norm, '/'), '{}'), null);

    v_cand_no := 0;
    foreach v_cand in array v_cands loop
      v_cand_no := v_cand_no + 1;
      select i.id into v_id from public.ingredients i where i.normalized_name = btrim(v_cand);
      if v_id is not null then
        v_kind := case when v_cand_no = 1 then 'canonical' else 'derived' end;
      else
        select a.ingredient_id into v_id from public.ingredient_aliases a where a.alias_normalized = btrim(v_cand);
        if v_id is not null then
          v_kind := case when v_cand_no = 1 then 'alias' else 'derived' end;
        end if;
      end if;
      if v_id is not null then
        v_term := btrim(v_cand);
        exit;
      end if;
    end loop;

    if v_id is null and v_norm is not null then
      select t.ingredient_id, t.term, extensions.similarity(t.term, v_norm)
        into v_id, v_term, v_sim
      from (
        select i.id as ingredient_id, i.normalized_name as term
        from public.ingredients i
        where i.normalized_name operator(extensions.%) v_norm
        union all
        select a.ingredient_id, a.alias_normalized
        from public.ingredient_aliases a
        where a.alias_normalized operator(extensions.%) v_norm
      ) t
      where extensions.similarity(t.term, v_norm) >= 0.45
      order by extensions.similarity(t.term, v_norm) desc, t.ingredient_id
      limit 1;
      if v_id is not null then
        v_kind := 'fuzzy';
      end if;
    end if;

    v_conf := case v_kind
                when 'canonical' then 1.000
                when 'alias' then 0.970
                when 'derived' then 0.930
                when 'fuzzy' then round((v_sim * 0.85)::numeric, 3)
                else 0 end;

    v_out := v_out || jsonb_build_object(
      'idx', v_idx,
      'raw_name', v_raw,
      'normalized', v_norm,
      'match_kind', v_kind,
      'ingredient_id', case when v_kind <> 'fuzzy' then v_id end,
      'suggested_ingredient_id', case when v_kind = 'fuzzy' then v_id end,
      'inci_name', (select inci_name from public.ingredients where id = v_id),
      'matched_term', v_term,
      'similarity', v_sim,
      'confidence', v_conf,
      'accepted', v_kind in ('canonical', 'alias', 'derived') and v_conf >= v_min);
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Per-source fixed-window rate limiter (atomic upsert, no read-modify-write).
-- ---------------------------------------------------------------------------
create or replace function public.ingest_take_token(p_domain text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source public.sources%rowtype;
  v_window timestamptz := date_trunc('minute', clock_timestamp());
  v_used int;
begin
  if private.caller_kind() not in ('service', 'system') then
    raise exception 'ingest_take_token requires the service role' using errcode = 'CI403';
  end if;
  select * into v_source from public.sources where domain = lower(btrim(p_domain));
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'unknown_source');
  end if;
  if v_source.trust_level = 'blocked' then
    return jsonb_build_object('allowed', false, 'reason', 'blocked', 'source_id', v_source.id);
  end if;

  insert into private.source_rate_windows as w (source_id, window_start, used)
  values (v_source.id, v_window, 1)
  on conflict (source_id, window_start) do update
    set used = w.used + 1
    where w.used < v_source.rate_limit_per_min
  returning used into v_used;

  if v_used is null then
    return jsonb_build_object(
      'allowed', false, 'reason', 'rate_limited', 'source_id', v_source.id,
      'limit', v_source.rate_limit_per_min,
      'retry_after_ms', greatest(1, ceil(extract(epoch from (v_window + interval '1 minute' - clock_timestamp())) * 1000))::int);
  end if;
  return jsonb_build_object('allowed', true, 'source_id', v_source.id, 'trust_level', v_source.trust_level,
                            'used', v_used, 'limit', v_source.rate_limit_per_min);
end;
$$;

-- ---------------------------------------------------------------------------
-- Dead-letter queue with exponential backoff (1, 2, 4 ... min, capped at 6 h;
-- abandoned after 6 attempts).
-- ---------------------------------------------------------------------------
create or replace function public.ingest_record_failure(
  p_url text,
  p_domain text,
  p_stage text,
  p_error text,
  p_http_status int default null,
  p_payload jsonb default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.ingest_dead_letter%rowtype;
  v_source_id bigint;
begin
  if private.caller_kind() not in ('service', 'system') then
    raise exception 'ingest_record_failure requires the service role' using errcode = 'CI403';
  end if;
  select id into v_source_id from public.sources where domain = lower(btrim(p_domain));

  insert into public.ingest_dead_letter as d (url, source_id, stage, error, http_status, payload, next_retry_at)
  values (p_url, v_source_id, p_stage, left(p_error, 2000), p_http_status, coalesce(p_payload, '{}'),
          now() + interval '1 minute')
  on conflict (url) where status in ('pending', 'retrying') do update
    set attempts = d.attempts + 1,
        stage = excluded.stage,
        error = excluded.error,
        http_status = excluded.http_status,
        payload = excluded.payload,
        last_failed_at = now(),
        status = case when d.attempts + 1 >= 6 then 'abandoned' else 'pending' end,
        next_retry_at = case when d.attempts + 1 >= 6 then null
                             else now() + least(interval '1 minute' * power(2, d.attempts), interval '6 hours') end
  returning * into v_row;

  return jsonb_build_object('dead_letter_id', v_row.id, 'attempts', v_row.attempts, 'status', v_row.status,
                            'next_retry_at', v_row.next_retry_at);
end;
$$;

create or replace function public.ingest_claim_dead_letters(p_limit int default 20)
returns setof public.ingest_dead_letter
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.caller_kind() not in ('service', 'system') then
    raise exception 'ingest_claim_dead_letters requires the service role' using errcode = 'CI403';
  end if;
  return query
  update public.ingest_dead_letter d
     set status = 'retrying', last_failed_at = now()
   where d.id in (
     select x.id from public.ingest_dead_letter x
     where (x.status = 'pending' and x.next_retry_at <= now())
        or (x.status = 'retrying' and x.last_failed_at < now() - interval '15 minutes')
     order by x.next_retry_at nulls first
     limit least(greatest(p_limit, 1), 100)
     for update skip locked)
  returning d.*;
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification → repair draft
-- ---------------------------------------------------------------------------
create or replace function private.try_draft_from_ingest(p_page_id bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_page public.ingest_pages%rowtype;
  v_min numeric;
  v_list jsonb := '[]'::jsonb;
  v_seen bigint[] := '{}'::bigint[];
  v_entry jsonb;
  v_id bigint;
  v_conf numeric;
  v_domain text;
  v_draft bigint;
begin
  select * into v_page from public.ingest_pages where id = p_page_id for update;
  if not found or v_page.product_id is null or v_page.status <> 'held_for_verification' then
    return null;
  end if;
  if exists (select 1 from public.verification_queue where ingest_page_id = p_page_id and status = 'pending') then
    return null;
  end if;
  select min_scraped_confidence into v_min from private.settings;

  for v_entry in select e from jsonb_array_elements(v_page.parsed -> 'ingredients') e loop
    -- names an admin rejected ("not an ingredient") are dropped
    if exists (select 1 from public.verification_queue q
               where q.ingest_page_id = p_page_id and q.normalized_name = v_entry ->> 'normalized'
                 and q.status = 'rejected') then
      continue;
    end if;
    v_id := null;
    v_conf := (v_entry ->> 'confidence')::numeric;
    if (v_entry ->> 'ingredient_id') is not null and coalesce(v_conf, 0) >= v_min then
      v_id := (v_entry ->> 'ingredient_id')::bigint;
    else
      select q.resolved_ingredient_id into v_id from public.verification_queue q
      where q.ingest_page_id = p_page_id and q.normalized_name = v_entry ->> 'normalized' and q.status = 'resolved'
      order by q.resolved_at desc limit 1;
      if v_id is null then
        select a.ingredient_id into v_id from public.ingredient_aliases a where a.alias_normalized = v_entry ->> 'normalized';
      end if;
      if v_id is null then
        select i.id into v_id from public.ingredients i where i.normalized_name = v_entry ->> 'normalized';
      end if;
      v_conf := 1.0; -- a human confirmed this mapping
    end if;
    if v_id is null then
      return null;
    end if;
    if v_id = any (v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_id;
    v_list := v_list || jsonb_build_object('ingredient_id', v_id, 'raw_name', v_entry ->> 'raw_name',
                                           'confidence', v_conf, 'source_url', v_page.url);
  end loop;

  if jsonb_array_length(v_list) = 0 then
    return null;
  end if;
  select domain into v_domain from public.sources where id = v_page.source_id;
  v_draft := public.create_repair_draft(v_page.product_id, v_list, 'scraped',
    'scraped list held for verification; all names now resolved', v_domain, 'verification');
  update public.ingest_pages set status = 'drafted' where id = p_page_id;
  return v_draft;
end;
$$;

create or replace function public.resolve_verification_item(
  p_item_id bigint,
  p_ingredient_id bigint default null,
  p_new_inci_name text default null,
  p_add_alias boolean default true,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.verification_queue%rowtype;
  v_ing public.ingredients%rowtype;
  v_alias_added boolean := false;
  v_existing bigint;
  v_resolved int;
  v_drafts bigint[] := '{}'::bigint[];
  v_page bigint;
  v_draft bigint;
begin
  if not private.is_admin() then
    raise exception 'resolving verification items requires an admin' using errcode = 'CI403';
  end if;
  if (p_ingredient_id is null) = (nullif(btrim(p_new_inci_name), '') is null) then
    raise exception 'pass exactly one of p_ingredient_id or p_new_inci_name' using errcode = 'CI400';
  end if;

  select * into v_item from public.verification_queue where id = p_item_id for update;
  if not found then
    raise exception 'verification item % not found', p_item_id using errcode = 'CI404';
  end if;
  if v_item.status <> 'pending' then
    raise exception 'verification item % is already %', p_item_id, v_item.status using errcode = 'CI409';
  end if;

  if p_ingredient_id is not null then
    select * into v_ing from public.ingredients where id = p_ingredient_id;
    if not found then
      raise exception 'ingredient % not found', p_ingredient_id using errcode = 'CI404';
    end if;
  else
    select coalesce(
             (select id from public.ingredients where normalized_name = public.normalize_inci(p_new_inci_name)),
             (select ingredient_id from public.ingredient_aliases where alias_normalized = public.normalize_inci(p_new_inci_name)))
      into v_existing;
    if v_existing is not null then
      select * into v_ing from public.ingredients where id = v_existing;
    else
      insert into public.ingredients (inci_name, normalized_name, origin)
      values (btrim(p_new_inci_name), public.normalize_inci(p_new_inci_name), 'verification_queue')
      returning * into v_ing;
      perform private.write_audit('ingredient_created', 'ingredient', v_ing.id::text, null,
        jsonb_build_object('inci_name', v_ing.inci_name), jsonb_build_object('queue_item', p_item_id));
    end if;
  end if;

  if p_add_alias and v_item.normalized_name <> v_ing.normalized_name then
    select ingredient_id into v_existing from public.ingredient_aliases where alias_normalized = v_item.normalized_name;
    if v_existing is null then
      insert into public.ingredient_aliases (alias_normalized, alias, ingredient_id, origin)
      values (v_item.normalized_name, v_item.raw_name, v_ing.id, 'verification_queue');
      v_alias_added := true;
      perform private.write_audit('alias_learned', 'ingredient_alias', v_item.normalized_name, null,
        jsonb_build_object('alias', v_item.raw_name, 'ingredient_id', v_ing.id, 'inci_name', v_ing.inci_name),
        jsonb_build_object('queue_item', p_item_id));
    elsif v_existing <> v_ing.id then
      raise exception 'alias "%" already maps to ingredient %', v_item.raw_name, v_existing using errcode = 'CI409';
    end if;
  end if;

  -- A learned alias is global: every open item with the same name is resolved too.
  with done as (
    update public.verification_queue q
       set status = 'resolved', resolved_ingredient_id = v_ing.id, resolved_by = private.actor_id(),
           resolved_at = now(), resolution_note = coalesce(p_note, case when q.id = p_item_id then null else 'resolved via #' || p_item_id end)
     where q.status = 'pending'
       and (q.id = p_item_id or (v_alias_added and q.normalized_name = v_item.normalized_name))
    returning q.ingest_page_id
  )
  select count(*), array_agg(distinct ingest_page_id) filter (where ingest_page_id is not null)
    into v_resolved, v_drafts
  from done;

  perform private.write_audit('verification_resolved', 'verification_queue', p_item_id::text, v_item.product_id,
    jsonb_build_object('raw_name', v_item.raw_name, 'ingredient_id', v_ing.id, 'inci_name', v_ing.inci_name,
                       'items_resolved', v_resolved, 'alias_added', v_alias_added),
    jsonb_build_object('note', p_note));

  -- v_drafts currently holds page ids; turn them into draft ids.
  declare
    v_pages bigint[] := coalesce(v_drafts, '{}');
  begin
    v_drafts := '{}';
    foreach v_page in array v_pages loop
      v_draft := private.try_draft_from_ingest(v_page);
      if v_draft is not null then
        v_drafts := v_drafts || v_draft;
      end if;
    end loop;
  end;

  return jsonb_build_object('status', 'resolved', 'ingredient_id', v_ing.id, 'inci_name', v_ing.inci_name,
                            'items_resolved', v_resolved, 'alias_added', v_alias_added, 'drafts_created', to_jsonb(v_drafts));
end;
$$;

create or replace function public.reject_verification_item(p_item_id bigint, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.verification_queue%rowtype;
  v_draft bigint;
begin
  if not private.is_admin() then
    raise exception 'rejecting verification items requires an admin' using errcode = 'CI403';
  end if;
  if coalesce(length(btrim(p_note)), 0) < 3 then
    raise exception 'a rejection note is required' using errcode = 'CI400';
  end if;
  select * into v_item from public.verification_queue where id = p_item_id for update;
  if not found then
    raise exception 'verification item % not found', p_item_id using errcode = 'CI404';
  end if;
  if v_item.status <> 'pending' then
    raise exception 'verification item % is already %', p_item_id, v_item.status using errcode = 'CI409';
  end if;
  update public.verification_queue
     set status = 'rejected', resolved_by = private.actor_id(), resolved_at = now(), resolution_note = p_note
   where id = p_item_id;
  perform private.write_audit('verification_rejected', 'verification_queue', p_item_id::text, v_item.product_id,
    jsonb_build_object('raw_name', v_item.raw_name), jsonb_build_object('note', p_note));
  if v_item.ingest_page_id is not null then
    v_draft := private.try_draft_from_ingest(v_item.ingest_page_id);
  end if;
  return jsonb_build_object('status', 'rejected', 'drafts_created',
                            case when v_draft is null then '[]'::jsonb else jsonb_build_array(v_draft) end);
end;
$$;

-- ---------------------------------------------------------------------------
-- Transactional apply of one parsed product page.
-- p_page: {url, source_domain, content_hash,
--          product: {brand, name, category, product_type},
--          ingredients: [{raw_name, normalized, ingredient_id, confidence,
--                         match_kind, suggested_ingredient_id, similarity}]}
-- ---------------------------------------------------------------------------
create or replace function public.ingest_apply_page(p_page jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source public.sources%rowtype;
  v_min numeric;
  v_existing public.ingest_pages%rowtype;
  v_brand_id bigint;
  v_product_id bigint;
  v_page_id bigint;
  v_url text := p_page ->> 'url';
  v_hash text := p_page ->> 'content_hash';
  v_entries jsonb := p_page -> 'ingredients';
  v_unresolved int;
  v_queued int := 0;
  v_list jsonb;
  v_result jsonb;
  v_draft bigint;
  v_state text;
  v_msg text;
begin
  if private.caller_kind() not in ('service', 'system') then
    raise exception 'ingest_apply_page requires the service role' using errcode = 'CI403';
  end if;
  if v_url is null or v_url !~ '^https://' or coalesce(v_hash, '') = ''
     or jsonb_typeof(p_page -> 'product') <> 'object' or jsonb_typeof(v_entries) <> 'array'
     or jsonb_array_length(v_entries) = 0 then
    raise exception 'malformed page payload' using errcode = 'CI400';
  end if;

  select * into v_source from public.sources where domain = lower(btrim(p_page ->> 'source_domain'));
  if not found then
    raise exception 'unknown source %', p_page ->> 'source_domain' using errcode = 'CI400';
  end if;
  if v_source.trust_level = 'blocked' then
    raise exception 'source % is blocked', v_source.domain using errcode = 'CI423';
  end if;
  select min_scraped_confidence into v_min from private.settings;

  -- Idempotency: the same content for the same URL is a no-op.
  select * into v_existing from public.ingest_pages where url = v_url for update;
  if found and v_existing.content_hash = v_hash then
    update public.ingest_pages set ingest_count = ingest_count + 1, last_ingested_at = now() where id = v_existing.id;
    update public.ingest_dead_letter set status = 'resolved' where url = v_url and status in ('pending', 'retrying');
    return jsonb_build_object('status', 'unchanged', 'product_id', v_existing.product_id,
                              'page_id', v_existing.id, 'previous_status', v_existing.status);
  end if;

  insert into public.brands as b (name, slug)
  values (btrim(p_page #>> '{product,brand}'),
          btrim(regexp_replace(lower(p_page #>> '{product,brand}'), '[^a-z0-9]+', '-', 'g'), '-'))
  on conflict (name) do update set name = excluded.name
  returning id into v_brand_id;

  insert into public.products as p (brand_id, name, category, product_type, product_url, source_id, status)
  values (v_brand_id, btrim(p_page #>> '{product,name}'), p_page #>> '{product,category}',
          coalesce(p_page #>> '{product,product_type}', 'unknown'), v_url, v_source.id, 'draft')
  on conflict (product_url) do update
    set name = excluded.name, category = excluded.category, product_type = excluded.product_type,
        brand_id = excluded.brand_id
  returning id into v_product_id;

  insert into public.ingest_pages as g (url, source_id, product_id, content_hash, parsed, status)
  values (v_url, v_source.id, v_product_id, v_hash, p_page, 'held_for_verification')
  on conflict (url) do update
    set content_hash = excluded.content_hash, parsed = excluded.parsed, product_id = excluded.product_id,
        ingest_count = g.ingest_count + 1, last_ingested_at = now()
  returning id into v_page_id;

  select count(*) into v_unresolved
  from jsonb_array_elements(v_entries) e
  where (e ->> 'ingredient_id') is null or coalesce((e ->> 'confidence')::numeric, 0) < v_min;

  if v_unresolved > 0 then
    with ins as (
      insert into public.verification_queue
        (product_id, ingest_page_id, raw_name, normalized_name, reason, suggested_ingredient_id, similarity,
         source_id, source_url)
      select v_product_id, v_page_id, e ->> 'raw_name', coalesce(e ->> 'normalized', public.normalize_inci(e ->> 'raw_name')),
             case when (e ->> 'suggested_ingredient_id') is not null then 'low_confidence'::public.queue_reason
                  else 'unknown_ingredient'::public.queue_reason end,
             (e ->> 'suggested_ingredient_id')::bigint, (e ->> 'similarity')::real, v_source.id, v_url
      from jsonb_array_elements(v_entries) e
      where (e ->> 'ingredient_id') is null or coalesce((e ->> 'confidence')::numeric, 0) < v_min
      on conflict (coalesce(product_id, 0), normalized_name, reason) where status = 'pending' do nothing
      returning 1
    )
    select count(*) into v_queued from ins;
    update public.ingest_pages set status = 'held_for_verification' where id = v_page_id;
    update public.ingest_dead_letter set status = 'resolved' where url = v_url and status in ('pending', 'retrying');
    return jsonb_build_object('status', 'held_for_verification', 'product_id', v_product_id, 'page_id', v_page_id,
                              'unresolved', v_unresolved, 'queued', v_queued);
  end if;

  select jsonb_agg(jsonb_build_object('ingredient_id', (e ->> 'ingredient_id')::bigint, 'raw_name', e ->> 'raw_name',
                                      'confidence', (e ->> 'confidence')::numeric, 'source_url', v_url)
                   order by ord)
    into v_list
  from jsonb_array_elements(v_entries) with ordinality as t (e, ord);

  begin
    v_result := public.repair_product_ingredients(v_product_id, v_list, 'scraped', v_source.domain, 'ingest ' || v_url);
    v_state := case when v_result ->> 'status' = 'unchanged' then 'unchanged' else 'applied' end;
    if v_source.trust_level = 'trusted' then
      update public.products set status = 'published', published_at = coalesce(published_at, now())
      where id = v_product_id and status = 'draft';
    end if;
  exception when sqlstate 'CI412' or sqlstate 'CI423' then
    -- Higher-trust data or a suspect source: hand it to a human.
    get stacked diagnostics v_msg = message_text;
    v_draft := public.create_repair_draft(v_product_id, v_list, 'scraped',
      'pipeline: ' || v_msg, v_source.domain, 'pipeline');
    v_state := 'drafted';
    v_result := jsonb_build_object('status', 'drafted', 'draft_id', v_draft, 'reason', v_msg);
  end;

  update public.ingest_pages set status = v_state where id = v_page_id;
  update public.ingest_dead_letter set status = 'resolved' where url = v_url and status in ('pending', 'retrying');
  return v_result || jsonb_build_object('product_id', v_product_id, 'page_id', v_page_id);
end;
$$;
