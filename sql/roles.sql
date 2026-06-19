\set ON_ERROR_STOP on

do $$ begin
    create role anon noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;
do $$ begin
    create role person;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

\if :{?password}
select format('create user httpg with password %L noinherit', :'password')
\gexec
\endif

grant person to httpg;
grant anon to httpg;

alter role httpg set statement_timeout to "500ms"; -- only at login time, so we set on http user, not person role
alter role httpg set transaction_timeout to "500ms";
alter role httpg set lock_timeout to "500ms";
alter role httpg set idle_in_transaction_session_timeout to "500ms";
