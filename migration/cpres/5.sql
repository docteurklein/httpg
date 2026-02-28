\timing on

set search_path to cpres;
set lock_timeout to '50ms';

select not exists (
    select from pg_constraint
    where conname = 'person_detail_person_id_fkey'
    and connamespace = to_regnamespace('cpres')
    limit 1
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    alter table person_detail add constraint person_detail_person_id_fkey foreign key (person_id)
        references person (person_id)
            on delete cascade
        not valid
    ;
    commit;

    begin;
    delete from person_detail pd where not exists (select from person p where p.person_id = pd.person_id);

    alter table person_detail validate constraint person_detail_person_id_fkey;
    commit;
\endif

