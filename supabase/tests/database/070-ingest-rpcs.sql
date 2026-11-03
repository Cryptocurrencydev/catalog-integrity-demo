begin;
select plan(18);

select tests.as_service();
create temp table r as select x.e as res
from jsonb_array_elements(public.resolve_ingredient_names(array[
  'Glycerin', 'Glycerine', 'Tocopherol (Vitamin E)', 'Aqua/Water/Eau', 'Water (Aqua)', 'Squalene', 'Zzqx Unobtainium', 'SODIUM LAURYL SULPHATE'
])) as x (e);
grant select on r to public;

select is((select res ->> 'match_kind' from r where (res ->> 'idx')::int = 1), 'canonical', 'exact canonical match');
select is((select res ->> 'match_kind' from r where (res ->> 'idx')::int = 2), 'alias', 'glycerine -> alias of Glycerin');
select is((select res ->> 'inci_name' from r where (res ->> 'idx')::int = 3), 'Tocopherol', 'parenthetical stripped -> Tocopherol');
select is((select res ->> 'inci_name' from r where (res ->> 'idx')::int = 4), 'Aqua', 'Aqua/Water/Eau -> Aqua');
select is((select res ->> 'match_kind' from r where (res ->> 'idx')::int = 5), 'derived', 'Water (Aqua) -> derived candidate');
select is((select (res ->> 'accepted')::boolean from r where (res ->> 'idx')::int = 6), false, 'fuzzy matches are never auto-accepted');
select is((select res ->> 'inci_name' from r where (res ->> 'idx')::int = 6), 'Squalane', '...but carry a suggestion (Squalene -> Squalane)');
select is((select res ->> 'match_kind' from r where (res ->> 'idx')::int = 7), 'none', 'unknown names resolve to none');
select is((select res ->> 'inci_name' from r where (res ->> 'idx')::int = 8), 'Sodium Lauryl Sulfate', 'British spelling normalised');

-- rate limiter: petalwright allows 2/min
select is(public.ingest_take_token('petalwright.example') ->> 'allowed', 'true', 'token 1 of 2');
select is(public.ingest_take_token('petalwright.example') ->> 'allowed', 'true', 'token 2 of 2');
select is(public.ingest_take_token('petalwright.example') ->> 'reason', 'rate_limited', 'token 3 refused');
select is(public.ingest_take_token('unknown-brand.example') ->> 'reason', 'unknown_source', 'unknown sources get no token');

-- dead letter backoff
select public.ingest_record_failure('https://halcyra.example/x', 'halcyra.example', 'fetch', 'http 503', 503);
select public.ingest_record_failure('https://halcyra.example/x', 'halcyra.example', 'fetch', 'http 503', 503);
select tests.as_postgres();
select is((select attempts from public.ingest_dead_letter where url = 'https://halcyra.example/x'), 2, 'repeat failures share one open row');
select ok((select next_retry_at - last_failed_at between interval '1 minute' and interval '3 minutes'
           from public.ingest_dead_letter where url = 'https://halcyra.example/x'), 'second failure backs off ~2 minutes');
select tests.as_service();
select public.ingest_record_failure('https://halcyra.example/x', 'halcyra.example', 'fetch', 'http 503', 503)
from generate_series(1, 4);
select tests.as_postgres();
select is((select status from public.ingest_dead_letter where url = 'https://halcyra.example/x'), 'abandoned', 'abandoned after 6 attempts');

-- claim due rows
insert into public.ingest_dead_letter (url, stage, error, next_retry_at) values ('https://halcyra.example/due', 'fetch', 'x', now() - interval '1 minute');
select tests.as_service();
select is((select count(*)::int from public.ingest_claim_dead_letters(10) where url = 'https://halcyra.example/due'), 1, 'due rows are claimed');
select is((select status from public.ingest_dead_letter where url = 'https://halcyra.example/due'), 'retrying', 'claimed rows are marked retrying');

select * from finish();
rollback;
