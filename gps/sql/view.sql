\set ON_ERROR_STOP on

set  search_path to gps, url, pg_catalog, public;


create or replace view heatmap (hex, weight)
as select ST_CoverageClean(h3_cell_to_boundary_geometry(location @ 10)) over (), count(*)
from ping
group by location @ 10
order by 2;

grant select on table heatmap to anon;

create or replace view head (html)
with (security_invoker)
as
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>GPS</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <link rel="stylesheet" href="/cpres/index.css?v=1" />
    <script type="module" src="/cpres/webcomponent/map.js?v=1"></script>
    <script type="module" src="/gps/index.js?v=1"></script>
</head>
<style>
#map + .leaflet-container {
    height: 90vh;
}
.list {
    overflow: auto;
    max-height: 90vh;
}

</style>
$html$;

grant select on table head to anon;

create or replace view stat (html, run_id)
with (security_invoker)
as
select xmlelement(name div,
    xmlelement(name h3, name),
    xmlelement(name p, round((st_length(st_makeline(location order by ping.at)::geography) / 1000)::numeric, 2) || ' km'),
    xmlelement(name p, 'first ping at: ', to_char(min(ping.at), 'HH24:MI:SS')),
    xmlelement(name p, 'last ping at: ', to_char(max(ping.at), 'HH24:MI:SS'))
), run_id
from run
left join ping using (run_id)
group by run_id;

grant select on table stat to anon;

-- drop view if exists head;
create or replace view map (html)
with (security_invoker)
as
with q (run_id) as (
    select current_setting('httpg.query', true)::jsonb->'qs'->>'run_id'
),
palette (palette) as (
    select array_agg(format(
        '#%s00%s',
        lpad(to_hex(c), 2, '0'),
        lpad(to_hex(0xff - c), 2, '0')
    ))
    from generate_series(0, 0xff) c
),
line (line, run_id) as (
    select st_makeline(location order by at), ping.run_id
    from ping, q
    where case when q.run_id is null then true else ping.run_id = q.run_id::uuid end
    group by ping.run_id
),
geo (geom, style, popup) as (
    select hex, jsonb_build_object(
        'color', palette[width_bucket(weight + 1, 0, max(weight) over (), 0xff)],
        'stroke', false
    ), null
    from heatmap, palette
    union all
    select line, null, jsonb_build_object(
        'content', stat.html::text
    )
    from line
    join run using (run_id)
    join stat using (run_id)
)
select xmlelement(name a, xmlattributes(
        url('/gps/query', jsonb_build_object(
            'sql', 'table gps.list'
        )) as href
    ),
    'back to list'
)::text
from q
where q.run_id is not null
union all
select xmlelement(name input, xmlattributes(
    'hidden' as type,
    nullif(q.run_id is null, false) as readonly,
    -- true as readonly,
    'map' as id,
    'cpres-map' as is,
    case when q.run_id is null then null else 'watch' end as geolocate,
    url('/gps/query', jsonb_build_object(
        'sql', $sql$
        insert into gps.ping (run_id, location) values ($1::uuid, $2::point::geometry)
        on conflict (run_id, location, at) do nothing
        returning st_asgeojson(location)::text
        $sql$
    )) as href,
    (
        select coalesce(jsonb_agg(feature), '[]')::text
        from (
            select st_asgeojson(geo)::jsonb
            from geo
        ) _ (feature)
    ) as "data-geojson"
))::text
from q;

grant select on table map to anon;

create or replace view list (html)
with (security_invoker)
as
with q (run_id) as (
    select current_setting('httpg.query', true)::jsonb->'qs'->>'run_id'
),
form (html) as (
    select xmlelement(name form, xmlattributes(
            'POST' as method,
            '/gps/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            $sql$
                insert into gps.run (run_id, name) values($1::uuid, nullif($2, ''))
                on conflict (run_id) do update
                set name = excluded.name
                returning hstore('Location', url('/gps/query', jsonb_build_object(
                    'sql', 'table gps.head union all table gps.map',
                    'run_id', run_id
                ))) header, 303 status
            $sql$ as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'params[0]' as name,
            coalesce(q.run_id, uuidv7()::text) as value
        )),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[1]' as name,
            (
                select coalesce(run.name, new.name)
                from (select to_char(now(), 'TMDay DD/MM/YY, HH24:MI') name) new
                left join run on run_id = q.run_id::uuid
            ) as value
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'new run' as value
        ))
    )
    from q
),
list (html, at) as (
    select xmlelement(name a, xmlattributes(
            url('/gps/query', jsonb_build_object(
                'sql', 'table gps.head union all table gps.map',
                'run_id', run_id
            )) as href
        ),
        xmlelement(name h3, coalesce(name, run_id::text))
    ), at
    from run
)
select html from head
union all
select xmlelement(name div, xmlattributes('grid' as class),
    (select xmlelement(name div, xmlattributes('list' as class), (select html from form), xmlagg(html order by at desc)) from list),
    (select xmlelement(name div, xmlagg(html::xml)) from map)
)::text;

grant select on table list to anon;


grant usage on schema gps to anon;

grant select, insert on table runner to anon;
grant select, insert, update on table run to anon;
grant select, insert on table ping to anon;
