\timing on

set search_path to cpres, pg_catalog;
set lock_timeout to '50ms';

select not exists(
    select from pg_attribute a
    join pg_class c on (c.oid = a.attrelid)
    where c.relnamespace = to_regnamespace('cpres')
    and c.relname = 'person'
    and a.attname = 'challenge_used_at'
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    alter table person add column challenge_used_at timestamptz default null;
    commit;
\endif

