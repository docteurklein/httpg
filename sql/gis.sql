\set ON_ERROR_STOP on

set search_path to cpres, url, pg_catalog, public;

-- drop materialized view if exists auvergne_boundary cascade;
create materialized view if not exists auvergne_boundary (geom, id) as
    select st_boundary(ST_Union(ST_Multi(geog::geometry))), 'auvergne'
    from osm_auvergne
    where osm_type = 'relation'
    and tags->>'boundary' = 'administrative'
    and tags->>'admin_level' in ('6') -- https://wiki.openstreetmap.org/wiki/Tag:boundary%3Dadministrative#admin_level=*_Country_specific_values
;

grant select on table auvergne_boundary to person;

-- drop materialized view if exists auvergne_highway cascade;
create materialized view if not exists auvergne_highway (osm_id, geog, speed) as
    select osm_id, geog, coalesce(
        nullif(json_value(tags, '$.maxspeed' returning numeric null on error), 0),
        case tags->>'highway'
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
    from osm_auvergne
    where osm_type = 'way'
    and tags->>'highway' in ( -- https://wiki.openstreetmap.org/wiki/Key:highway#Highway
        'motorway',
        'motorway_link',
        'trunk',
        'trunk_link',
        'primary',
        'primary_link',
        'secondary',
        'secondary_link',
        'tertiary',
        'tertiary_link',
        -- 'track', --keep ?
        'unclassified',
        'service',
        'living_street',
        'residential'
    )
    and geometrytype(geog) = 'LINESTRING'
;

create unique index if not exists auvergne_highway_pkey on auvergne_highway (osm_id);
-- create index if not exists auvergne_highway_geom on auvergne_highway using gist ((geog::geometry));
create index if not exists auvergne_highway_geog on auvergne_highway using gist (geog);

grant select on table auvergne_highway to person;

vacuum analyze auvergne_highway;

-- select current_setting('neon.project_id', true) is not null as is_neon
-- \gset

drop materialized view if exists auvergne_network_edge cascade;
\timing on
create materialized view if not exists auvergne_network_edge (osm_id, id, geog, startpoint, endpoint, duration) as
with crossing as (
    select e1.osm_id, e1.geog, e1.speed, st_intersection(e1.geog, e2.geog)::geometry point
    from auvergne_highway e1
    join auvergne_highway e2
    on st_intersects(e1.geog, e2.geog)
    and e1.osm_id <> e2.osm_id
    -- \if :is_neon
    and e1.geog && ST_MakeEnvelope(3.51, 46.01, 3.78, 46.15, 4326)
    -- \endif
),
split as (
    select osm_id, split.geom, speed
    from crossing, st_dump(
        st_split(
            st_snap(geog::geometry, point, .1),
            point
        )
    ) split
)
select
    osm_id,
    row_number() over (order by geog),
    geog,
    st_startpoint(geog::geometry),
    st_endpoint(geog::geometry),
    st_length(geog) / (speed / 3.6)
from (
    select osm_id, geom::geography, speed from split
    -- union all
    -- select osm_id, geog, speed from auvergne_highway
    -- where not exists (select from split where split.osm_id = auvergne_highway.osm_id)
    -- and auvergne_highway.geog && ST_MakeEnvelope(3.51, 46.01, 3.78, 46.15, 4326)
) _ (osm_id, geog)
where st_startpoint(geog::geometry) <> st_endpoint(geog::geometry)
;

create unique index if not exists auvergne_network_edge_pkey on auvergne_network_edge (id);
create index if not exists auvergne_network_edge_geog on auvergne_network_edge using gist (geog);

vacuum analyze auvergne_network_edge;

drop materialized view if exists auvergne_network_node cascade;
create materialized view if not exists auvergne_network_node (id, geom) as
with node (geom) as (
    select unnest(array[startpoint, endpoint])
    from auvergne_network_edge
)
select row_number() over (order by geom), geom
from node
group by geom;

grant select on table auvergne_network_node to person;

create unique index if not exists auvergne_network_node_pkey on auvergne_network_node (id);
create index if not exists auvergne_network_node_geom on auvergne_network_node using gist (geom);

vacuum analyze auvergne_network_node;

drop materialized view if exists auvergne_network cascade;
create materialized view if not exists auvergne_network (osm_id, id, geog, source, target, cost, reverse_cost) as
select osm_id, edge.id, edge.geog, source.id, target.id, edge.duration, edge.duration r
    -- st_x(source.geom),
    -- st_y(source.geom),
    -- st_x(target.geom),
    -- st_y(target.geom)
from auvergne_network_edge edge
join auvergne_network_node source on edge.startpoint = source.geom
join auvergne_network_node target on edge.endpoint = target.geom
;

grant select on table auvergne_network to person;

create index if not exists auvergne_network_geog on auvergne_network using gist (geog);
create index if not exists auvergne_network_source on auvergne_network (source);
create index if not exists auvergne_network_target on auvergne_network (target);
create unique index if not exists auvergne_network_pkey on auvergne_network (id);

vacuum analyze auvergne_network;
