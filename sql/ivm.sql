
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
    id int primary key default 1,
    nposts int default 0,
    lsn pg_lsn default '0/0'
);
insert into blog.stat (id, nposts)
select 1, count(post_id)
from blog.post
on conflict (id) do nothing;

set session characteristics as transaction isolation level serializable;

do $$
declare
    lsn_ pg_lsn;
    change_ jsonb;
begin
select confirmed_flush_lsn
into lsn_
from pg_replication_slots
where slot_name = 'test';
raise notice '%', lsn_;
loop
    with change (lsn, change) as (
        select lsn, change
        from pg_logical_slot_peek_changes('test', null, null, 'include-types', 'false', 'add-tables', 'blog.post'),
        jsonb_array_elements(data::jsonb->'change') change
    ),
    stat as (
        update blog.stat
        set nposts = nposts + case when change->>'kind' = 'insert' then 1 else -1 end,
        lsn = change.lsn
        from change
        where (change->>'schema', change->>'table') = ('blog', 'post')
        and id = 1
        and stat.lsn < change.lsn
        and change->>'kind' in ('insert', 'delete')
    )
    select lsn, change
    into lsn_, change_
    from change;
    --, change_--, change, change->>'schema', change->>'table', change->>'kind', old, new, new - old diff into found, lsn_, change_
    --, wal2json_v1_to_record(change), jsonb_populate_record(null::blog.post, new::jsonb) n;

    raise notice '%', change_;
    commit;
    perform pg_replication_slot_advance('test', lsn_);
    if lsn_ is not null then
        raise notice '%', lsn_;
    end if;
    perform pg_sleep(1);
end loop;

end;
$$;
