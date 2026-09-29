create extension if not exists hstore schema public;

set "ivm.slot_name" to :'slot_name';

select * from pg_create_logical_replication_slot(:'slot_name', 'wal2json')
where not exists (select from pg_replication_slots where slot_name = :'slot_name');

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

-- drop table if exists blog.stat;
create table if not exists blog.stat (
    post_id uuid primary key references blog.post (post_id) on delete cascade,
    ncomments int default 0,
    lsn pg_lsn default '0/0'
);
insert into blog.stat (post_id, ncomments)
select post_id, count(comment_id)
from blog.comment
-- join blog.post using (post_id)
group by 1
on conflict (post_id) do nothing;

-- drop function if exists log_;
create or replace function log_(e anyelement, msg text default null) returns anyelement
language plpgsql as $$
begin
    raise notice '% %', msg, e;
    return e;
end;
$$;

-- create or replace procedure ivm()
-- language plpgsql
set session characteristics as transaction isolation level serializable;
do $$
declare
    lsn_ pg_lsn;
    change_ jsonb;
begin
set log_min_messages to fatal; -- unfortunate but pg_logical_slot_peek_changes floods server logs
select confirmed_flush_lsn
into lsn_
from pg_replication_slots
where slot_name = current_setting('ivm.slot_name');
raise notice 'starting at %', lsn_;
loop
    with change (lsn, change) as (
        select lsn, value
        from pg_logical_slot_peek_changes(current_setting('ivm.slot_name'), null, null, 'include-types', 'false'), --, 'add-tables', 'blog.post'),
        jsonb_array_elements(data::jsonb->'change')
    ),
    blog_stat as (
        with sum (post_id, ins, del) as (
            select post_id, count(1) filter (where change->>'kind' = 'insert'), count(1) filter (where change->>'kind' = 'delete')
            from change,
            wal2json_v1_to_record(change),
            jsonb_populate_record(null::blog.comment, case when change->>'kind' = 'delete' then old::jsonb else new::jsonb end)
            join blog.post using (post_id)
            where (change->>'schema', change->>'table') = ('blog', 'comment')
            and change->>'kind' in ('insert', 'delete')
            group by 1
        )
        merge into blog.stat
        using sum
        on sum.post_id = stat.post_id
        -- and stat.lsn < sum.lsn
        when matched and ins - del <= 0 then delete
        when matched then update
            set ncomments = ncomments + ins - del
            -- lsn = sum.lsn
        when not matched then insert
            (post_id, ncomments) values
            (post_id, ins - del)
    )
    select lsn, jsonb_agg(change) into lsn_, change_
    from change
    group by 1;
    --, change_--, change, change->>'schema', change->>'table', change->>'kind', old, new, new - old diff into found, lsn, change_

    -- exception when serialization_failure then
    --     raise warning '%', sqlerrm;
    --     continue;
    -- end;
    commit;
    perform pg_replication_slot_advance(current_setting('ivm.slot_name'), lsn_);
    if lsn_ is not null then
        raise notice 'commited %', lsn_;
        -- raise notice '%', change_;
    else
        perform pg_sleep(1);
    end if;
end loop;

end;
$$;

-- call ivm();
