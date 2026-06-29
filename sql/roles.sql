\set ON_ERROR_STOP on

do $$ begin
    create role anon noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;
do $$ begin
    create role person noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;
do $$ begin
    create role runner noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;
do $$ begin
    create role gieze_admin noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

\if :{?password}
select format('create user httpg with password %L noinherit', :'password')
\gexec
\endif

grant anon to httpg;
grant person to anon;
grant gieze_admin to anon;

alter default privileges revoke all on tables from public, anon;
alter default privileges revoke all on sequences from public, anon;
alter default privileges revoke all on routines from public, anon;
alter default privileges revoke all on types from public, anon;
alter default privileges revoke all on schemas from public, anon;

revoke create on schema public, pg_catalog from public, anon;

alter default privileges grant all on types to public, anon;
grant usage on schema public, pg_catalog to public, anon;


alter role httpg set statement_timeout to "500ms"; -- only at login time, so we set on http user, not person role
alter role httpg set transaction_timeout to "500ms";
alter role httpg set lock_timeout to "500ms";
alter role httpg set idle_in_transaction_session_timeout to "500ms";
