\set ON_ERROR_STOP on

set local search_path to cpres, url, pg_catalog, public;

create or replace procedure want(_good_id uuid, level interest_level, price_ text)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id, origin, level, price)
    values (_good_id, current_person_id(), 'manual', level, nullif(price_, '')::numeric)
    on conflict (good_id, person_id) do update
        set level = excluded.level,
        price = excluded.price
    ;
end;

grant execute on procedure want(uuid, interest_level, text) to person;
