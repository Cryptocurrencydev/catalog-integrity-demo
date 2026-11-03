-- Test helpers (committed, test databases only): role switching + error capture.
create extension if not exists pgtap with schema extensions;
create schema if not exists tests;

create or replace function tests.as_role(p_role text, p_claims jsonb default null)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', coalesce(p_claims::text, ''), true);
  perform set_config('role', p_role, true);
end;
$$;

create or replace function tests.as_anon() returns void language sql
as $$ select tests.as_role('anon', '{"role":"anon"}') $$;

create or replace function tests.as_user() returns void language sql
as $$ select tests.as_role('authenticated',
  '{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000000a1","app_metadata":{}}') $$;

create or replace function tests.as_admin() returns void language sql
as $$ select tests.as_role('authenticated',
  '{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000000ad","app_metadata":{"role":"admin"}}') $$;

create or replace function tests.as_service() returns void language sql
as $$ select tests.as_role('service_role', '{"role":"service_role"}') $$;

create or replace function tests.as_postgres() returns void language sql
as $$ select tests.as_role('postgres', null) $$;

-- Runs a statement and returns {"state","message","detail"} of the error (or null).
create or replace function tests.err(p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v_state text; v_msg text; v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('state', v_state, 'message', v_msg, 'detail', v_detail);
end;
$$;

grant usage on schema tests to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;

begin;
select plan(1);
select has_schema('tests');
select * from finish();
commit;
