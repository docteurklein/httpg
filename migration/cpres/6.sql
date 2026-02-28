\timing on

set search_path to cpres;
set lock_timeout to '50ms';

select not exists (
    select from pg_constraint
    where conname = 'search_person_id_fkey'
    and connamespace = to_regnamespace('cpres')
    limit 1
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    alter table search add constraint search_person_id_fkey foreign key (person_id)
        references person (person_id)
            on delete cascade
        not valid
    ;
    commit;

    begin;
    delete from search s where not exists (select from person p where p.person_id = s.person_id);

    alter table search validate constraint search_person_id_fkey;
    commit;
\endif

