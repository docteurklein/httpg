
drop function if exists v1_to_record(jsonb);
create or replace function v1_to_record(change jsonb)
returns table (key jsonb, new jsonb)
language sql
strict immutable parallel safe leakproof
begin atomic
    select jsonb_object_agg(key, id) filter (where key is not null), jsonb_object_agg(new_key, new_value)
    from unnest(
        array(select jsonb_array_elements_text(
            case when change->>'kind' in ('delete', 'update')
                then change->'oldkeys'->'keynames'
                else change->'columnnames'
            end
        )),
        array(select jsonb_array_elements(
            case when change->>'kind' in ('delete', 'update')
                then change->'oldkeys'->'keyvalues'
                else change->'columnvalues'
            end
        )),
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
        ))
    ) _ (key, id, new_key, new_value);
end;

with change (change) as (
    select change
    from pg_logical_slot_peek_changes('test', null, null),
    jsonb_array_elements(data::jsonb->'change') change
)
select change->>'kind', key, n.*
from change, v1_to_record(change), jsonb_populate_record(null::blog.comment, new) n;
