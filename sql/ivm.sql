
drop function if exists v1_to_record(jsonb);
create or replace function v1_to_record(change jsonb) returns jsonb
language sql
strict immutable parallel safe leakproof
begin atomic
    select jsonb_object_agg(key, value)
    from unnest(
    array(select jsonb_array_elements_text(
        case change->>'kind'
            when 'delete' then change->'oldkeys'->'keynames'
            else change->'columnnames'
        end
    )),
    array(select jsonb_array_elements(
        case change->>'kind'
            when 'delete' then change->'oldkeys'->'keyvalues'
            else change->'columnvalues'
        end
    ))) _ (key, value);
end;

with change (change) as (
    select change
    from pg_logical_slot_peek_changes('test', null, null),
    jsonb_array_elements(data::jsonb->'change') change
)
select change->>'kind', a.*
from change, jsonb_populate_record(null::blog.comment, v1_to_record(change)) a;
