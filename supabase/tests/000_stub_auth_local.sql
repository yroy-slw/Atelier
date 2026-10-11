-- =============================================================================
--  UNIQUEMENT pour tester en local sur un Postgres « nu ».
--  Simule ce que Supabase fournit déjà : rôles anon/authenticated et auth.uid().
--  Ne PAS lancer sur un projet Supabase.
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin;          end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema if not exists auth;

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema auth to authenticated, anon;
