set "auto_explain.log_min_duration" = 10000;
create schema if not exists ivm;
set search_path to ivm, pg_catalog, public;

select * from pg_create_logical_replication_slot(:'slot_name', 'wal2json')
where not exists (select from pg_replication_slots where slot_name = :'slot_name');

-- drop function if exists debug;
create or replace function debug(a anyelement, msg text default '', cond bool default true, with_stack bool default false) returns anyelement
language plpgsql
stable parallel safe
security definer
as $$
declare
    stack text;
begin
    if cond then
        raise notice '% (%) -- %', a, pg_typeof(a), msg;
        if with_stack then
            get diagnostics stack = pg_context;
            raise notice '%', stack;
        end if;
    end if;

    return a;
end
$$;

-- drop function if exists wal2json_v1(jsonb) cascade;
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

create or replace procedure maintain_ts_stat(current_lsn pg_lsn, changes jsonb)
security definer
begin atomic
    with diff (word, incr) as (
        select coalesce(n.lexeme, o.lexeme), sum(coalesce(cardinality(n.positions), 0) - coalesce(cardinality(o.positions), 0))
        from jsonb_array_elements(changes) change,
        wal2json_v1(change),
        jsonb_populate_record(null::blog.post, old) old,
        jsonb_populate_record(null::blog.post, new) new
        left join lateral unnest(new.fts) n on true
        full outer join lateral unnest(old.fts) o using (lexeme)
        where (change->>'schema', change->>'table') = ('blog', 'post')
        and change->>'kind' in ('insert', 'update', 'delete')
        and cardinality(n.positions) is distinct from cardinality(o.positions)
        group by 1
    )
    merge into blog.ts_stat
    using diff
    on diff.word = ts_stat.word
    when matched and ts_stat.lsn >= current_lsn then do nothing
    when matched and nentry + incr <= 0 then delete
    when matched and incr <> 0 then update set
        nentry = nentry + incr,
        lsn = current_lsn
    when not matched and incr > 0 then insert
        (word, nentry, lsn) values
        (word, incr, current_lsn)
    ;
end;

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
    when matched and ncomments + incr <= 0 then delete
    when matched and incr <> 0 then update
        set ncomments = ncomments + incr,
        lsn = current_lsn
    when not matched and incr > 0 then insert
        (post_id, ncomments, lsn) values
        (post_id, incr, current_lsn)
    ;
end;

create or replace procedure maintain_total_stat(current_lsn pg_lsn, changes jsonb)
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

-- drop procedure if exists populate;
create or replace procedure populate(slot text, lock_duration text default '1s')
language plpgsql
as $$
begin
    perform set_config('lock_timeout', lock_duration, false);
    lock table blog.ts_stat, blog.stat, blog.total_stat, blog.comment, blog.post
    in share row exclusive mode; -- block app writes for a while

    truncate blog.ts_stat;
    insert into blog.ts_stat
    select word, nentry
    from ts_stat('select fts from blog.post');

    truncate blog.stat; -- block exclusive
    insert into blog.stat (post_id, ncomments)
    select *
    from blog.stat_view;

    truncate blog.total_stat;
    insert into blog.total_stat (id, ncomments)
    select 'ncomments', coalesce(sum(ncomments), 0)
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
            -- 'include-empty-transaction', 'false',
            'include-lsn', 'true',
            'include-types', 'false',
            'add-tables', 'blog.comment,blog.stat,blog.post,cpres.osm_auvergne'
        ) c
    loop
        call maintain_gis_network(lsn, changes);
        call maintain_comment_stat(lsn, changes);
        call maintain_total_stat(lsn, changes);
        call maintain_ts_stat(lsn, changes);
    end loop;

    if lsn is not null then
        commit;
        -- perform 1 / random(0, 50); -- chaos testing
        perform pg_replication_slot_advance(slot, lsn);
        raise notice 'advanced to %', lsn;
    else
        rollback;
        perform pg_sleep(1);
    end if;

end loop;
end;
$$;

-- drop table if exists network_iv;
create table if not exists network_iv (
    id bigint primary key generated by default as identity,
    osm_id bigint not null,
    geog geography not null,
    startpoint geometry(point) not null,
    endpoint geometry(point) not null,
    duration int not null,
    distance int not null,
    lsn pg_lsn not null default '0/0'
);

-- insert into network_edge_iv
-- select id, osm_id, geog, startpoint, endpoint, duration, st_length(geog::geometry) from auvergne_network_edge;

create or replace procedure maintain_gis_network(current_lsn pg_lsn, changes jsonb)
security definer
begin atomic
    with way (osm_id, geog, speed) as (
        select new.osm_id, new.geog, coalesce(
            nullif(json_value(new.tags, '$.maxspeed' returning numeric null on error), 0),
            case new.tags->>'highway'
                when 'motorway'
                    then 130
                when 'motorway_link'
                    then 70
                when 'trunk'
                    then 110
                when 'trunk_link'
                    then 50
                when 'primary'
                    then 90
                when 'primary_link'
                    then 50
                when 'secondary'
                    then 70
                when 'secondary_link'
                    then 50
                when 'tertiary'
                    then 50
                when 'tertiary_link'
                    then 50
                when 'residential'
                    then 25
                when 'service'
                    then 15
                when 'unclassified'
                    then 25
                when 'living_street'
                    then 10
                else 30
            end
        )
        from jsonb_array_elements(changes) change,
        wal2json_v1(change),
        jsonb_populate_record(null::cpres.osm_auvergne, old) old,
        jsonb_populate_record(null::cpres.osm_auvergne, new) new
        where (change->>'schema', change->>'table') = ('cpres', 'osm_auvergne')
        and change->>'kind' in ('insert', 'update', 'delete')
        and new.osm_type = 'way'
        -- and new.tags->>'highway' in ( -- https://wiki.openstreetmap.org/wiki/Key:highway#Highway
        --     'motorway',
        --     'motorway_link',
        --     'trunk',
        --     'trunk_link',
        --     'primary',
        --     'primary_link',
        --     'secondary',
        --     'secondary_link',
        --     'tertiary',
        --     'tertiary_link',
        --     -- 'track', --keep ?
        --     'unclassified',
        --     'service',
        --     'living_street',
        --     'residential'
        -- )
        -- and geometrytype(new.geog) = 'LINESTRING'
    ),
    crossing (osm_id, geog, speed, point) as (
        select e1.osm_id, e1.geog, e1.speed, st_intersection(e1.geog, e2.geog)::geometry
        from way e1
        join cpres.network_iv e2 on st_intersects(e1.geog, e2.geog)
        where e1.osm_id <> e2.osm_id
        -- or e2 is null
        -- and e1.geog && ST_MakeEnvelope(3.51, 46.01, 3.78, 46.15, 4326)
    ),
    edge as (
        select
            osm_id,
            geog,
            st_startpoint(geog::geometry),
            st_endpoint(geog::geometry),
            speed,
            st_length(geog) / (speed / 3.6),
            st_length(geog)
        from way
    ),
    split (osm_id, geog, startpoint, endpoint, speed, duration, distance) as (
        select
            osm_id,
            split.geom::geography,
            st_startpoint(split.geom),
            st_endpoint(split.geom),
            speed,
            st_length(split.geom::geography) / (speed / 3.6),
            st_length(split.geom::geography)
        from crossing, st_dump(
            st_split(
                st_snap(geog::geometry, point, .1),
                point
            )
        ) split
        where st_startpoint(split.geom) <> st_endpoint(split.geom)
    )
    merge into ivm.network_iv
    using (
        table split union table edge
    ) diff
    on debug(diff.geog = network_iv.geog)
    when matched and network_iv.lsn >= current_lsn then do nothing
    -- when matched and nentry +  then delete
    -- when matched and incr <> 0 then update set
    --     nentry = nentry + incr,
    --     lsn = current_lsn
    when not matched then insert
        (osm_id, geog, startpoint, endpoint, duration, distance, lsn) values
        (osm_id, geog, startpoint, endpoint, duration, distance, debug(current_lsn))
    ;
    -- select
    --     osm_id,
    --     row_number() over (order by geog),
    --     geog,
    --     st_startpoint(geog::geometry),
    --     st_endpoint(geog::geometry),
    --     st_length(geog) / (speed / 3.6)
    --     -- st_length(geog)
    -- from split
    ;
    -- select osm_id, edge.id, edge.geog, source.id, target.id, edge.duration, edge.duration r
    -- from auvergne_network_edge edge
    -- join auvergne_network_node source on edge.startpoint = source.geom
    -- join auvergne_network_node target on edge.endpoint = target.geom
end;


call ivm(:'slot_name');
