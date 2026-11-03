-- Nightly hygiene, scheduled with pg_cron. Every job is a plain function
-- (testable with pgTAP) wrapped by private.run_hygiene_job() which records a
-- row in hygiene_runs with timing and the job's result.

-- 1. URL trust re-check (mocked probe: private.url_check_mock).
create or replace function private.hygiene_recheck_url_trust(p_batch int default 500)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_src record;
  v_ok boolean;
  v_new public.trust_level;
  v_checked int := 0;
  v_downgraded int := 0;
begin
  for v_src in
    select s.*, m.http_status, m.tls_ok, m.final_domain
    from public.sources s
    left join private.url_check_mock m on m.domain = s.domain
    where s.trust_level <> 'blocked'
      and (s.trust_checked_at is null or s.trust_checked_at < now() - interval '20 hours')
    order by s.trust_checked_at nulls first
    limit p_batch
    for update of s skip locked
  loop
    v_checked := v_checked + 1;
    v_ok := coalesce(v_src.http_status, 200) between 200 and 399
            and coalesce(v_src.tls_ok, true)
            and coalesce(v_src.final_domain, v_src.domain) = v_src.domain;
    v_new := case
               when v_ok then v_src.trust_level
               when v_src.trust_level = 'trusted' then 'unverified'
               else 'suspect'
             end;
    update public.sources
       set trust_checked_at = now(),
           trust_level = v_new,
           trust_note = case when v_ok then null
                             else format('probe failed: http=%s tls=%s final=%s', coalesce(v_src.http_status, 200),
                                         coalesce(v_src.tls_ok, true), coalesce(v_src.final_domain, v_src.domain)) end
     where id = v_src.id;
    if v_new is distinct from v_src.trust_level then
      v_downgraded := v_downgraded + 1;
      perform private.write_audit('source_trust_changed', 'source', v_src.id::text, null,
        jsonb_build_object('domain', v_src.domain, 'from', v_src.trust_level, 'to', v_new),
        jsonb_build_object('job', 'url_trust'));
    end if;
  end loop;
  return jsonb_build_object('checked', v_checked, 'downgraded', v_downgraded);
end;
$$;

-- 2. Orphan / expiry cleanup. Never touches audit_log.
create or replace function private.hygiene_cleanup_orphans()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings private.settings%rowtype;
  v_windows int;
  v_cache int;
  v_archived_cache int;
  v_stale_drafts int;
  v_ingredients int;
  v_dead int;
begin
  select * into v_settings from private.settings;

  delete from private.source_rate_windows where window_start < now() - interval '10 minutes';
  get diagnostics v_windows = row_count;

  delete from public.analysis_cache
  where invalidated_at < now() - v_settings.cache_invalidated_retention and not quarantined;
  get diagnostics v_cache = row_count;

  update public.analysis_cache c
     set invalidated_at = now(), invalidated_reason = 'product_archived'
    from public.products p
   where p.id = c.product_id and p.status = 'archived' and c.invalidated_at is null;
  get diagnostics v_archived_cache = row_count;

  update public.repair_drafts d
     set status = 'stale', reviewed_at = now(), review_note = 'hygiene: product list changed since draft'
    from public.products p
   where p.id = d.product_id and d.status = 'pending' and d.base_hash is distinct from p.ingredients_hash;
  get diagnostics v_stale_drafts = row_count;

  -- Ingredients learned from the queue that nothing uses any more.
  with gone as (
    delete from public.ingredients i
    where i.origin = 'verification_queue'
      and i.created_at < now() - v_settings.learned_ingredient_grace
      and not exists (select 1 from public.product_ingredients pi where pi.ingredient_id = i.id)
      and not exists (select 1 from public.verification_queue q where q.resolved_ingredient_id = i.id)
      and not exists (select 1 from public.repair_drafts d
                      where d.status = 'pending' and d.proposed @> jsonb_build_array(jsonb_build_object('ingredient_id', i.id)))
    returning i.id, i.inci_name
  )
  select count(*) into v_ingredients from gone;

  delete from public.ingest_dead_letter
  where status in ('resolved', 'abandoned') and last_failed_at < now() - interval '30 days';
  get diagnostics v_dead = row_count;

  return jsonb_build_object('rate_windows', v_windows, 'cache_rows_purged', v_cache,
                            'archived_cache_invalidated', v_archived_cache, 'drafts_marked_stale', v_stale_drafts,
                            'orphan_ingredients', v_ingredients, 'dead_letters_purged', v_dead);
end;
$$;

-- 3. Stale cache detection. "drift" should always be 0: a live row whose
--    snapshot hash differs from the product means something bypassed the RPC.
create or replace function private.hygiene_detect_stale_cache()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_expired int;
  v_drift int;
begin
  update public.analysis_cache
     set invalidated_at = now(), invalidated_reason = 'expired'
   where invalidated_at is null and expires_at < now();
  get diagnostics v_expired = row_count;

  update public.analysis_cache c
     set invalidated_at = now(), invalidated_reason = 'hash_drift'
    from public.products p
   where p.id = c.product_id and c.invalidated_at is null
     and c.ingredients_hash is distinct from p.ingredients_hash;
  get diagnostics v_drift = row_count;

  if v_drift > 0 then
    perform private.write_audit('cache_hash_drift', 'analysis_cache', null, null,
      jsonb_build_object('rows', v_drift), jsonb_build_object('job', 'stale_cache'));
  end if;
  return jsonb_build_object('expired', v_expired, 'hash_drift', v_drift);
end;
$$;

-- 4. Data-quality report.
create or replace function private.hygiene_quality_report()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_id bigint;
  r public.data_quality_reports%rowtype;
begin
  with
  prod as (
    select count(*) as total, count(*) filter (where status = 'published') as published,
           count(*) filter (where status = 'published' and ingredient_count = 0) as missing
    from public.products
  ),
  dup as (
    select p.brand_id, p.name_key, p.ingredients_hash, count(*) as n, array_agg(p.id order by p.id) as ids
    from public.products p
    where p.status <> 'archived' and p.ingredients_hash is not null
    group by p.brand_id, p.name_key, p.ingredients_hash
    having count(*) > 1
  ),
  mix as (
    select pi.product_id,
           count(*) as n,
           count(*) filter (where pi.provenance_kind in ('verified', 'manual')) as reviewed,
           count(*) filter (where pi.provenance_kind = 'ai_suggested') as ai
    from public.product_ingredients pi
    group by pi.product_id
  ),
  low as (
    select m.product_id from mix m where m.ai::numeric / m.n >= 0.30 and m.reviewed = 0
  ),
  untrusted as (
    select count(distinct pi.product_id) as n
    from public.product_ingredients pi
    join public.sources s on s.id = pi.source_id
    where pi.provenance_kind = 'scraped' and s.trust_level in ('suspect', 'blocked')
  ),
  overall as (
    select jsonb_object_agg(provenance_kind, n) as j
    from (select provenance_kind, count(*) as n from public.product_ingredients group by provenance_kind) x
  )
  insert into public.data_quality_reports (
    duration_ms, products_total, published_total, missing_ingredients, duplicate_groups, low_provenance_products,
    stale_cache_rows, quarantined_cache_rows, untrusted_source_products, pending_queue, oldest_pending_hours,
    stale_drafts, provenance_mix, samples)
  select
    0,
    prod.total, prod.published, prod.missing,
    (select count(*) from dup),
    (select count(*) from low),
    (select count(*) from public.analysis_cache c join public.products p on p.id = c.product_id
      where c.invalidated_at is null and c.ingredients_hash is distinct from p.ingredients_hash),
    (select count(*) from public.analysis_cache where quarantined),
    (select n from untrusted),
    (select count(*) from public.verification_queue where status = 'pending'),
    (select round((extract(epoch from now() - min(created_at)) / 3600)::numeric, 1)
       from public.verification_queue where status = 'pending'),
    (select count(*) from public.repair_drafts where status = 'stale'),
    coalesce((select j from overall), '{}'),
    jsonb_build_object(
      'missing_ingredients', coalesce((
        select jsonb_agg(jsonb_build_object('product_id', id, 'name', name))
        from (select id, name from public.products
              where status = 'published' and ingredient_count = 0 order by id limit 10) s), '[]'),
      'duplicates', coalesce((
        select jsonb_agg(jsonb_build_object('product_ids', ids, 'name', name_key, 'count', n))
        from (select * from dup order by n desc, ids[1] limit 10) s), '[]'),
      'low_provenance', coalesce((
        select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', p.name))
        from (select product_id from low order by product_id limit 10) l
        join public.products p on p.id = l.product_id), '[]'))
  from prod
  returning id into v_id;

  update public.data_quality_reports
     set duration_ms = (extract(epoch from clock_timestamp() - v_started) * 1000)::int
   where id = v_id
  returning * into r;

  return jsonb_build_object('report_id', r.id, 'duration_ms', r.duration_ms, 'missing_ingredients', r.missing_ingredients,
                            'duplicate_groups', r.duplicate_groups, 'low_provenance_products', r.low_provenance_products);
end;
$$;

-- data_quality_reports is otherwise read-only; allow the job to fill in its own duration.
-- (No triggers needed: only definer code and the owner can write this table.)

create or replace function private.run_hygiene_job(p_job text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_run_id bigint;
  v_result jsonb;
  v_err text;
begin
  insert into public.hygiene_runs (job) values (p_job) returning id into v_run_id;
  begin
    v_result := case p_job
      when 'url_trust' then private.hygiene_recheck_url_trust()
      when 'cleanup_orphans' then private.hygiene_cleanup_orphans()
      when 'stale_cache' then private.hygiene_detect_stale_cache()
      when 'quality_report' then private.hygiene_quality_report()
    end;
    if v_result is null then
      raise exception 'unknown hygiene job %', p_job;
    end if;
    update public.hygiene_runs set finished_at = clock_timestamp(), ok = true, details = v_result where id = v_run_id;
  exception when others then
    get stacked diagnostics v_err = message_text;
    update public.hygiene_runs set finished_at = clock_timestamp(), ok = false,
           details = jsonb_build_object('error', v_err) where id = v_run_id;
    v_result := jsonb_build_object('error', v_err);
  end;
  return v_result;
end;
$$;

-- Schedules (UTC). cron.schedule(name, ...) upserts by name, so re-running is safe.
select cron.schedule('hygiene-url-trust', '0 2 * * *', $$select private.run_hygiene_job('url_trust')$$);
select cron.schedule('hygiene-stale-cache', '15 2 * * *', $$select private.run_hygiene_job('stale_cache')$$);
select cron.schedule('hygiene-cleanup-orphans', '30 2 * * *', $$select private.run_hygiene_job('cleanup_orphans')$$);
select cron.schedule('hygiene-quality-report', '45 2 * * *', $$select private.run_hygiene_job('quality_report')$$);
