set "auto_explain.log_min_duration" = 10000;
create schema if not exists ivm;
set search_path to ivm, pg_catalog, public;

select * from pg_create_logical_replication_slot(:'slot_name', 'wal2json')
where not exists (select from pg_replication_slots where slot_name = :'slot_name');

-- drop function if exists debug;
create or replace function debug(a anyelement, msg text default '', cond bool default true) returns anyelement
language plpgsql
stable parallel safe
security definer
as $$
declare
    stack text;
begin
    if cond then
        raise notice '% (%) -- %', a, pg_typeof(a), msg;
        get diagnostics stack = pg_context;
        raise notice '%', stack;
    end if;
    return a;
end
$$;

drop function if exists wal2json_v1(jsonb) cascade;
create or replace function wal2json_v1(change jsonb)
returns table (old jsonb, new jsonb)
language sql
immutable parallel safe leakproof
security definer
begin atomic
    select case when change->>'kind' in ('update', 'delete') then
        jsonb_object(
            array(select jsonb_array_elements_text(change->'oldkeys'->'keynames')),
            array(select jsonb_array_elements_text(change->'oldkeys'->'keyvalues'))
        )
    end,
    case when change->>'kind' in ('insert', 'update') then
        jsonb_object(
            array(select jsonb_array_elements_text(change->'columnnames')),
            array(select jsonb_array_elements_text(change->'columnvalues'))
        )
    end;
end;

-- drop view if exists blog.stat_view;
create or replace view blog.stat_view as
select post_id, count(comment_id) ncomments
from blog.post
join blog.comment using (post_id)
group by 1;

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

set session characteristics as transaction isolation level serializable;

create or replace procedure maintain_comment_stat(current_lsn pg_lsn, changes jsonb)
security definer
begin atomic
    with diff (post_id, incr) as (
        select post_id, count(1) filter (where change->>'kind' = 'insert') - count(1) filter (where change->>'kind' = 'delete')
        from jsonb_array_elements(changes) change,
        wal2json_v1(change),
        jsonb_populate_record(null::blog.comment, coalesce(new, old)) comment
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
end;

create or replace procedure maintain_blog_stat(current_lsn pg_lsn, changes jsonb)
security definer
begin atomic
    with diff (incr) as (
        select sum(coalesce(new.ncomments, 0) - coalesce(old.ncomments, 0))
        from jsonb_array_elements(changes) change,
        wal2json_v1(change),
        jsonb_populate_record(null::blog.stat, old) old,
        jsonb_populate_record(null::blog.stat, new) new
        where (change->>'schema', change->>'table') = ('blog', 'stat')
        and change->>'kind' in ('insert', 'update', 'delete')
    )
    merge into blog.total_stat t
    using diff
    on t.id = 'ncomments'
    when matched and t.lsn >= current_lsn then do nothing
    when matched and incr <> 0 then update
        set ncomments = ncomments + incr,
        lsn = current_lsn
    when not matched and incr is not null then insert
        (id, ncomments, lsn) values
        ('ncomments', incr, current_lsn)
    ;
end;

-- drop procedure if exists backfill;
create or replace procedure backfill(slot text, lock_duration text default '1s')
language plpgsql
as $$
begin
    perform set_config('lock_timeout', lock_duration, false);
    lock table blog.stat, blog.total_stat, blog.comment in share row exclusive mode; -- block app writes for a while

    truncate blog.stat; -- block exclusive
    insert into blog.stat (post_id, ncomments)
    select *
    from blog.stat_view;

    truncate blog.total_stat;
    insert into blog.total_stat (id, ncomments)
    select 'ncomments', sum(ncomments)
    from blog.stat;

    commit;
    perform pg_replication_slot_advance(slot, pg_current_wal_lsn());
end $$;

-- drop procedure if exists ivm;
create or replace procedure ivm(slot text)
language plpgsql
as $$
declare
    lsn pg_lsn;
    changes jsonb;
begin
-- set log_min_messages to fatal; -- unfortunate but pg_logical_slot_peek_changes floods server logs
loop
    for lsn, changes in
        select c.lsn, data::jsonb->'change'
        from pg_logical_slot_peek_changes(slot, null, null,
            'format-version', '1',
            'include-empty-transaction', 'false',
            'include-lsn', 'true',
            'include-types', 'false',
            'add-tables', 'blog.comment,blog.stat'
        ) c
    loop
        call maintain_comment_stat(lsn, changes);
        call maintain_blog_stat(lsn, changes);
    end loop;

    if lsn is not null then
        commit;
        -- perform 1 / random(0, 50); -- chaos testing
        perform pg_replication_slot_advance(slot, lsn);
    else
        rollback;
        perform pg_sleep(1);
    end if;

end loop;
end;
$$;

call ivm(:'slot_name');
