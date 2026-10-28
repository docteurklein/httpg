
create schema if not exists httpg;

set local search_path to httpg, pg_catalog;

create or replace function query() returns jsonb
language sql
strict stable parallel safe
begin atomic
    select nullif(current_setting('httpg.query', true), '')::jsonb;
end;


grant usage on schema httpg to anon;
grant execute on function query to anon;
