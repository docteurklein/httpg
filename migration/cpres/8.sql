
set search_path to cpres;
set lock_timeout to '50ms';

select not exists (
    select from pg_attribute
    join pg_class on (attrelid = oid)
    where relnamespace = to_regnamespace('cpres')
    and relname = 'search'
    and attname = 'at'
    limit 1
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    \timing on
    begin;
    alter table search add column at timestamptz not null default now();
    commit;
\endif

