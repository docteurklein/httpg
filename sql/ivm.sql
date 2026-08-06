
-- drop function if exists wal2json_v1_to_record(jsonb);
create or replace function wal2json_v1_to_record(change jsonb)
returns table (old hstore, new hstore)
language sql
strict immutable parallel safe leakproof
begin atomic
    select hstore(
        array(select jsonb_array_elements_text(case when change->>'kind' in ('delete', 'update')
            then change->'oldkeys'->'keynames'
            else change->'columnnames'
        end)),
        array(select jsonb_array_elements_text(case when change->>'kind' in ('delete', 'update')
            then change->'oldkeys'->'keyvalues'
            else change->'columnvalues'
        end))
    ),
    hstore(
        array(select jsonb_array_elements_text(case change->>'kind'
            when 'delete' then change->'oldkeys'->'keynames'
            else change->'columnnames'
        end)),
        array(select jsonb_array_elements_text(case change->>'kind'
            when 'delete' then change->'oldkeys'->'keyvalues'
            else change->'columnvalues'
        end))
    );
end;

with change (change) as (
    select change
    from pg_logical_slot_get_changes('test', null, null),
    jsonb_array_elements(data::jsonb->'change') change
)
select change->>'schema', change->>'table', change->>'kind', old, new, new - old diff
from change, wal2json_v1_to_record(change), jsonb_populate_record(null::blog.post, new::jsonb) n;
