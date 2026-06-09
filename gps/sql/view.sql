\set ON_ERROR_STOP on

set  search_path to gps, url, pg_catalog, public;


create or replace view heatmap (hex, weight)
as select ST_CoverageClean(h3_cell_to_boundary_geometry(location @ 10)) over (), count(*)
from ping
group by location @ 10
order by 2;

grant select on table heatmap to anon;

-- drop view if exists head;
create or replace view head (html)
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
    select st_makeline(location order by at), run_id
    from ping
    group by run_id
),
geo (geom, style, popup) as (
    select hex, jsonb_build_object(
        'color', palette[width_bucket(weight + 1, 0, max(weight) over (), 0xff)],
        'stroke', false
    ), null
    from heatmap, palette
    union all
    select line, null, jsonb_build_object(
        'content', xmlelement(name div,
            xmlelement(name h3, name),
            xmlelement(name p, round((st_length(line::geography) / 1000)::numeric, 2) || ' km')
        )::text
    )
    from line
    join run using (run_id)
)
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
</style>
$html$
union all
(with new_run_id (new_run_id) as (
    select uuidv7()
)
select xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/gps/query', jsonb_build_object(
            'sql', 'insert into gps.run (run_id) values($1::uuid)',
            'params[]', new_run_id,
            'redirect', url('/gps/query', jsonb_build_object(
                'sql', 'table gps.head',
                'run_id', new_run_id
            ))
        )) as action
    ),
    xmlelement(name input, xmlattributes(
        'submit' as type,
        'new run' as value
    ))
)::text
from new_run_id)
union all
select xmlelement(name input, xmlattributes(
    'hidden' as type,
    null as readonly,
    'map' as id,
    'cpres-map' as is,
    -- 'watch' as geolocate,
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

grant usage on schema gps to anon;

grant select on table head to anon;
grant select, insert on table runner to anon;
grant select, insert on table run to anon;
grant select, insert on table ping to anon;
