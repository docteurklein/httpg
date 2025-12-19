\timing on

set search_path to cpres, pg_catalog;
set lock_timeout to '50ms';

select coalesce((
    select format_type(atttypid, atttypmod) <> 'jsonb'
    from pg_attribute a
    join pg_class c on (c.oid = a.attrelid)
    where c.relname = 'person_detail'
    and a.attname = 'push_endpoint'
    and c.relnamespace = to_regnamespace('cpres')
), true) needs_work;
\gset

select :'needs_work';

\if :needs_work
    begin;
    drop function if exists send_login_email (text, text);
    drop function if exists send_login_email (text, text, text);
    drop function if exists web_push (uuid);
    alter table person_detail alter column push_endpoint type jsonb using (
        case when push_endpoint is not null
        then jsonb_build_object('endpoint', push_endpoint) end
    );
    commit;
\endif

