-- set "ivm.slot_name" to :'slot_name';

select * from pg_create_logical_replication_slot(:'slot_name', 'wal2json')
where not exists (select from pg_replication_slots where slot_name = :'slot_name');

-- drop function if exists debug;
create or replace function debug(a anyelement, msg text default '', cond bool default true) returns anyelement
language plpgsql
stable parallel safe
as $$
begin
    if cond then
        raise notice '% (%) -- %', a, pg_typeof(a), msg;
    end if;
    return a;
end
$$;
-- drop function if exists wal2json_v1(jsonb);
create or replace function wal2json_v1(change jsonb)
returns table (old hstore, new hstore)
language sql
strict immutable parallel safe leakproof
begin atomic
    select case when change->>'kind' in ('delete', 'update') then hstore(
        array(select jsonb_array_elements_text(change->'oldkeys'->'keynames')),
        array(select jsonb_array_elements_text(change->'oldkeys'->'keyvalues'))
    ) end,
    case when change->>'kind' in ('insert', 'update') then hstore(
        array(select jsonb_array_elements_text(change->'columnnames')),
        array(select jsonb_array_elements_text(change->'columnvalues'))
    ) end;
end;

-- drop view if exists blog.stat_view;
create or replace view blog.stat_view as
select post_id, count(comment_id) ncomments
from blog.post
join blog.comment using (post_id)
group by 1
;

-- drop table if exists blog.stat;
create table if not exists blog.stat (
    post_id uuid primary key, -- references blog.post (post_id) on delete cascade,
    ncomments int not null default 0,
    lsn pg_lsn not null default '0/0'
);
alter table blog.stat replica identity full;

-- drop table if exists blog.total_stat;
create table if not exists blog.total_stat (
    id text primary key,
    ncomments int not null default 0,
    lsn pg_lsn not null default '0/0'
);

-- begin;
-- truncate blog.stat;
-- insert into blog.stat (post_id, ncomments) -- DO NOT execute DML on a maintained table or advance lsn by hand like below
-- select *
-- from blog.stat_view
-- on conflict (post_id) do nothing;

-- truncate blog.total_stat;
-- with current (sum) as (
--     select sum(ncomments)
--     from blog.stat
-- )
-- insert into blog.total_stat (id, ncomments)
-- select 'ncomments', coalesce((
--     select sum from current
-- ), 0)
-- where not exists (select from blog.total_stat);

-- commit;
-- select pg_replication_slot_advance(current_setting('ivm.slot_name'), pg_current_wal_insert_lsn());



set session characteristics as transaction isolation level serializable;

create or replace procedure ivm(slot text, current_lsn pg_lsn)
language plpgsql
as $$
declare
    changes jsonb;
begin
set "auto_explain.log_min_duration" = 10000;
-- set log_min_messages to fatal; -- unfortunate but pg_logical_slot_peek_changes floods server logs
raise notice 'starting at %', current_lsn;
loop
    for current_lsn, changes in select lsn, data::jsonb->'change'
        from pg_logical_slot_peek_changes(slot, null, null,
            'format-version', '1',
            'include-empty-transaction', 'false',
            'include-lsn', 'true',
            'include-types', 'false',
            'add-tables', 'blog.comment,blog.stat'
        )
        -- order by lsn
    loop
        with diff (post_id, incr) as (
            select post_id, coalesce(count(1) filter (where change->>'kind' = 'insert'), 0) - coalesce(count(1) filter (where change->>'kind' = 'delete'), 0)
            from jsonb_array_elements(changes) change,
            wal2json_v1(change),
            jsonb_populate_record(null::blog.comment, case when change->>'kind' = 'delete' then old::jsonb else new::jsonb end) comment
            where (change->>'schema', change->>'table') = ('blog', 'comment')
            and change->>'kind' in ('insert', 'delete')
            group by post_id
        )
        merge into blog.stat
        using diff
        on diff.post_id = stat.post_id
        when matched and stat.lsn >= current_lsn then do nothing
        when matched and (ncomments + incr <= 0) then delete
        when matched and incr <> 0 then update
            set ncomments = ncomments + incr,
            lsn = current_lsn
        when not matched and incr > 0 then insert
            (post_id, ncomments, lsn) values
            (post_id, incr, current_lsn)
        ;

        with diff (incr) as (
            select sum(coalesce(new.ncomments, 0) - coalesce(old.ncomments, 0))
            from jsonb_array_elements(changes) change,
            wal2json_v1(change),
            jsonb_populate_record(null::blog.stat, old::jsonb) old,
            jsonb_populate_record(null::blog.stat, new::jsonb) new
            where (change->>'schema', change->>'table') = ('blog', 'stat')
            and change->>'kind' in ('insert', 'update', 'delete')
        )
        merge into blog.total_stat t
        using (
            select * from diff where incr is not null
        ) diff
        on t.id = 'ncomments'
        when matched and t.lsn >= current_lsn then do nothing
        when matched and incr <> 0 then update
            set ncomments = ncomments + incr,
            lsn = current_lsn
        when not matched then insert
            (id, ncomments, lsn) values
            ('ncomments', incr, current_lsn)
        ;
    end loop;

    if current_lsn is not null then
        commit;
        raise notice 'committed %', current_lsn;
        perform 1 / random(0, 5); -- chaos testing
        select end_lsn into current_lsn from pg_replication_slot_advance(slot, current_lsn);
        raise notice 'advanced slot % to %', slot, current_lsn;
    else
        perform pg_sleep(1);
        rollback;
    end if;

end loop;

end;
$$;

select confirmed_flush_lsn lsn
from pg_replication_slots
where slot_name = :'slot_name' \gset

call ivm(:'slot_name', :'lsn');
