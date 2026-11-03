begin;
select plan(20);

select results_eq(
  $q$select jobname::text, schedule::text from cron.job where jobname like 'hygiene-%' order by schedule$q$,
  $q$values ('hygiene-url-trust', '0 2 * * *'), ('hygiene-stale-cache', '15 2 * * *'),
            ('hygiene-cleanup-orphans', '30 2 * * *'), ('hygiene-quality-report', '45 2 * * *')$q$,
  'four nightly hygiene jobs are scheduled');
select ok((select bool_and(command like 'select private.run_hygiene_job(%') from cron.job where jobname like 'hygiene-%'),
  'each job runs through the logging wrapper');

-- 1. URL trust (mocked probes in private.url_check_mock)
update public.sources set trust_checked_at = null;
select is((private.run_hygiene_job('url_trust') ->> 'downgraded')::int >= 2, true, 'failing probes downgrade sources');
select is((select trust_level::text from public.sources where domain = 'beautyaisle.example'), 'suspect',
  'off-domain redirect: unverified -> suspect');
select is((select trust_level::text from public.sources where domain = 'hollowreed.example'), 'unverified',
  'TLS failure: trusted -> unverified');
select ok(exists (select 1 from public.audit_log where action = 'source_trust_changed' and diff ->> 'domain' = 'beautyaisle.example'),
  'trust changes are audited');
select is((private.hygiene_recheck_url_trust() ->> 'checked')::int, 0, 'sources checked in the last 20h are skipped');

-- 2. stale cache
create temp table c as select id from public.analysis_cache where invalidated_at is null order by id limit 1;
update public.analysis_cache set ingredients_hash = 'drifted' where id = (select id from c);
create temp table s as select private.run_hygiene_job('stale_cache') as r;
select ok((select (r ->> 'expired')::int from s) > 0, 'expired cache rows invalidated');
select is((select (r ->> 'hash_drift')::int from s), 1, 'a live row whose hash drifted from its product is caught');
select is((select invalidated_reason from public.analysis_cache where id = (select id from c)), 'hash_drift', 'drifted row invalidated');
select ok(exists (select 1 from public.audit_log where action = 'cache_hash_drift'), 'drift raises an audit alarm');

-- 3. orphan cleanup
insert into public.ingredients (inci_name, normalized_name, origin, created_at)
values ('Unused Learned Extract', 'unused learned extract', 'verification_queue', now() - interval '60 days'),
       ('Fresh Learned Extract', 'fresh learned extract', 'verification_queue', now());
update public.analysis_cache set invalidated_at = now() - interval '40 days' where id in (
  select id from public.analysis_cache where invalidated_at is not null and not quarantined order by id limit 5);
insert into private.source_rate_windows values ((select id from public.sources limit 1), now() - interval '1 hour', 3);
create temp table o as select private.run_hygiene_job('cleanup_orphans') as r;
select ok((select (r ->> 'cache_rows_purged')::int from o) >= 5, 'old invalidated cache rows purged');
select ok(not exists (select 1 from public.ingredients where normalized_name = 'unused learned extract'),
  'unused learned ingredient past its grace period removed');
select ok(exists (select 1 from public.ingredients where normalized_name = 'fresh learned extract'),
  'recently learned ingredient kept');
select ok((select count(*) from public.analysis_cache where quarantined) > 0, 'quarantined rows are kept for review');
select is((select count(*)::int from private.source_rate_windows where window_start < now() - interval '10 minutes'), 0,
  'expired rate-limit windows removed');

-- 4. quality report
create temp table q as select private.run_hygiene_job('quality_report') as r;
select ok((select missing_ingredients from public.data_quality_reports order by id desc limit 1) >= 1,
  'report counts published products missing ingredients');
select ok((select duplicate_groups from public.data_quality_reports order by id desc limit 1) >= 1, 'report finds duplicates');
select ok((select low_provenance_products from public.data_quality_reports order by id desc limit 1) >= 1,
  'report finds low-provenance products');

select private.run_hygiene_job('nope');
select is((select ok from public.hygiene_runs where job = 'nope' order by id desc limit 1), false,
  'a failing job is recorded as ok=false instead of aborting the nightly run');
select * from finish();
rollback;
