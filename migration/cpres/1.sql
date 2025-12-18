
\set ON_ERROR_STOP on
\timing on

set search_path to cpres;
set lock_timeout to '50ms';

select coalesce((select (
    position('POSITION' in pg_get_constraintdef(oid, true)) = 0
    or not convalidated
)
from pg_constraint
where conname = 'person_name_check'
and connamespace = to_regnamespace('cpres')
limit 1), true) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    alter table person drop constraint if exists person_name_check;
    alter table person add constraint person_name_check  check (trim(name) <> '' and position('@' in name) = 0) not valid;

    alter table person drop constraint if exists person_email_check;
    alter table person add constraint person_email_check  check (trim(email) <> '' and position('@' in email) <> 0) not valid;
    commit;
\endif

do $$ begin
perform 1;
while FOUND loop
    with r as materialized (
        select person_id from person
        where position('@' in name) <> 0
        for no key update skip locked
        limit 100
    ),
    u as (
        update person
        set name = replace(name, '@', '-at-')
        from r
        where person.person_id = r.person_id
    )
    select true into FOUND from r;
    raise info '%', FOUND;
    commit;
end loop;
end $$;

\if :needs_work
    begin;
    alter table person validate constraint person_name_check;
    commit;

    begin;
    alter table person validate constraint person_email_check;
    commit;
\endif

