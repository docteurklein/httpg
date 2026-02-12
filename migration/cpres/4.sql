\timing on

set search_path to cpres;
set lock_timeout to '50ms';

select not exists (
    select from pg_constraint
    where conname = 'good_media_content_check'
    and connamespace = to_regnamespace('cpres')
    limit 1
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    alter table good_media add constraint good_media_content_check check (length(content) < 1024 * 1000) not valid;
    commit;

    begin;
    alter table good_media validate constraint good_media_content_check;
    commit;
\endif

