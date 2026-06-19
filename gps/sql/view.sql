\set ON_ERROR_STOP on

set  search_path to gps, url, pg_catalog, public;

-- alter role anon set search_path to gps, url, pg_catalog, public;
-- alter role httpg set search_path to gps, url, pg_catalog, public;

grant select, insert, update on table runner to anon;
grant select, insert, update on table run to anon;
grant select, insert, delete on table ping to anon;

create or replace view heatmap (hex, weight)
as select h3_cell_to_boundary_geometry(d.geom @ 10), count(*)
from run, ST_DumpPoints(geom) d
group by d.geom @ 10
order by 2;

grant select on table heatmap to anon;

drop view if exists login cascade;
create or replace view login (html)
with (security_invoker)
as
select xmlelement(name form, xmlattributes(
        'POST' as method,
        '/gps/query/res' as action
    ),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        'call gps.login($1, $2)' as value
    )),
    xmlelement(name input, xmlattributes(
        'text' as type,
        'params[0]' as name
    )),
    xmlelement(name input, xmlattributes(
        'password' as type,
        'params[1]' as name
    )),
    xmlelement(name input, xmlattributes(
        'submit' as type,
        'login' as value
    ))
)::text;

grant select on table login to anon;

create or replace view head (html)
with (security_invoker)
as
with httpg (error) as (
    select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>GPS</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <link rel="stylesheet" href="https://unpkg.com/charts.css/dist/charts.min.css" />
    <link rel="stylesheet" href="/cpres/index.css?v=1" />
    <script type="module" src="/cpres/webcomponent/map.js?v=1"></script>
    <script type="module" src="/gps/index.js?v=1"></script>
</head>
<style>
#map + .leaflet-container {
    height: 90vh;
}

.ended {
    text-decoration: line-through;
}

.list {
    overflow: auto;
    max-height: 90vh;
}

#elevation-chart {
    & tbody {
        max-height: 20vh;
    }
    max-width: 100vw;
    margin-bottom: 1vh;
}

@media (pointer: coarse), (hover: none) {
  [title] {
    position: relative;
    display: inline-flex;
    justify-content: center;
  }
  [title]:hover::after {
    content: attr(title);
    position: absolute;
    z-index: 10;
    top: 50%;
    left: 0;
    color: #000;
    background-color: #fff;
    border: 1px solid;
    width: max-content;
    padding: 3px;
    font-size: 10px;
  }
}
</style>
$html$
union all
select xmlelement(name p, error)::text
from httpg
where error is not null
union all
select format('Hello %s!', name)
from runner
where runner_id = current_runner_id()
union all
select html from login
where current_runner_id() is null;

grant select on table head to anon;


drop materialized view if exists gebco_geo cascade;
create materialized view if not exists gebco_geo (geom, rast) as
select st_setsrid(st_extent(st_envelope(rast)), 4326), rast
from gebco
group by rast;

grant select on table gebco_geo to anon;

create or replace view stat (html, run_id)
with (security_invoker)
as
select xmlelement(name div,
    xmlelement(name h1, name),
    xmlelement(name p, round((st_length(coalesce(geom, st_makeline(location order by at))::geography) / 1000)::numeric, 2) || ' km'),
    xmlelement(name p, 'started at: ', to_char(starts_at, 'HH24:MI:SS')),
    case when ends_at is not null then xmlelement(name p, 'ended at: ', to_char(ends_at, 'HH24:MI:SS')) end,
    xmlelement(name div, xmlattributes('elevation-chart' as id),
        xmlelement(name table, xmlattributes('charts-css column' as class), (
            with point (geom) as (
                select geom from ST_DumpPoints(run.geom)
                union all
                (select location
                from ping
                where ping.run_id = run.run_id
                order by at)
            ),
            elevation (altitude, size) as (
                select st_value(rast, p.geom), coalesce(st_value(rast, p.geom) / max(st_value(rast, p.geom)) over ()::decimal, 0)
                from point p
                left join gebco_geo on st_contains(gebco_geo.geom, p.geom)
            )
            select xmlagg(
                xmlelement(name tr,
                    xmlelement(name td, xmlattributes(
                        format('--size: %s', size) as style,
                         altitude ||'m' as title
                    ), '')
                )
            )
            from elevation
        ))
    )
), run_id
from run
left join ping using (run_id)
group by run_id;

grant select on table stat to anon;

drop function if exists geojson_ping cascade;
create or replace function geojson_ping(location geometry, run_id uuid, at timestamptz) returns record
language sql
immutable strict parallel safe
set search_path to gps, url, pg_catalog, public
begin atomic
    select location geom, jsonb_build_object(
        'content', xmlelement(name form, xmlattributes(
                'POST' as method,
                '/gps/query' as action
            ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'delete from gps.ping where location = $1::geometry and run_id = $2::uuid and at = $3::timestamptz' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'redirect' as name,
                'referer' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'params[0]' as name,
                location::text as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'params[1]' as name,
                run_id::text as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'params[2]' as name,
                at::text as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                'delete point' as value,
                'destructive' as class,
                format('return confirm(%L)', 'Are you sure?') as onclick
            ))
        )
    ) popup;
end;

grant execute on function geojson_ping to anon;

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
    select st_simplify(st_makeline(location order by at), .0001), ping.run_id
    from ping, q
    where case when q.run_id is null then true else ping.run_id = q.run_id::uuid end
    group by ping.run_id
    union all
    select geom, run.run_id
    from q, run
    where geom is not null
    and case when q.run_id is null then true else q.run_id::uuid = run.run_id end
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
    union all
    select g.geom, null, case when q.run_id is null then null else g.popup end
    from q, ping, geojson_ping(location, ping.run_id, at) as g (geom geometry, popup jsonb)
    where case when q.run_id is null then true else ping.run_id = q.run_id::uuid end
)
select xmlconcat(
    xmlelement(name a, xmlattributes(
        url('/gps/query', jsonb_build_object(
            'sql', 'table gps.list'
        )) as href
    ), 'back to list'),
    stat.html,
    case when ends_at is null then
        xmlelement(name form, xmlattributes(
                'POST' as method,
                '/gps/query/res' as action
            ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'call gps.end_run($1::uuid)' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'params[0]' as name,
                q.run_id as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                'end run' as value,
                'destructive' as class,
                format('return confirm(%L)', 'Are you sure?') as onclick
            ))
        )
    end
)::text
from q, run
join stat using (run_id)
where run.run_id = q.run_id::uuid
union all
select xmlelement(name input, xmlattributes(
    'hidden' as type,
    nullif(q.run_id is null, false) or run.ends_at is not null as readonly,
    'map' as id,
    'cpres-map' as is,
    case when q.run_id is null or ends_at is not null then null else 'watch' end as geolocate,
    url('/gps/query', jsonb_build_object(
        'sql', 'call gps.ping($1::uuid, $2::point::geometry)'
    )) as href,
    (
        select coalesce(jsonb_agg(feature), '[]')::text
        from (
            select st_asgeojson(geo)::jsonb
            from geo
            -- union all
            -- select st_asgeojson(t.*)::jsonb
            -- from (select geog geom, jsonb_build_object('content', z_min || '-' || z_max) popup from ta_rgealti_ppk_5m_wgs84g) t
            -- union all
            -- select st_asgeojson(t.*)::jsonb
            -- from (
            --     select
            --     geom
            --     -- jsonb_build_object(
            --     --     'color', palette[width_bucket(p.val + 1, 0, max(p.val) over (), 0xff)],
            --     --     'stroke', true
            --     -- ) style,
            --     -- jsonb_build_object('content', xmlelement(name p, p.val)) popup
            --     from gebco_geo
            --     limit 10000
            -- ) t
        ) _ (feature)
    ) as "data-geojson"
))::text
from q
left join run
on run.run_id = q.run_id::uuid;

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
                insert into gps.run (name) values (nullif($1, ''))
                returning hstore('Location', url('/gps/query', jsonb_build_object(
                    'sql', 'table gps.head union all table gps.map',
                    'run_id', run_id
                ))) header, 303 status
            $sql$ as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'table gps.list' as value
        )),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[0]' as name,
            to_char(now(), 'TMDay DD/MM/YY, HH24:MI') as value
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'new run' as value
        ))
    )
    from q
),
list (html, starts_at) as (
    select xmlelement(name a, xmlattributes(
            url('/gps/query', jsonb_build_object(
                'sql', 'table gps.head union all table gps.map',
                'run_id', run_id
            )) as href
        ),
        xmlelement(name h3, xmlattributes(case when ends_at is not null then 'ended' end as class), coalesce(name, run_id::text))
    ), starts_at
    from run
)
select html from head
union all
select xmlelement(name div, xmlattributes('grid' as class),
    (select xmlelement(name div, xmlattributes('list' as class), (select html from form), xmlagg(html order by starts_at desc)) from list),
    (select xmlelement(name div, xmlagg(html::xml)) from map)
)::text;

grant select on table list to anon;

grant usage on schema gps to anon;

drop procedure if exists end_run;
create or replace procedure end_run(run_id_ uuid, res inout refcursor default 'res')
language plpgsql
security invoker
set search_path to gps, url, pg_catalog, public
-- begin atomic
as $$
begin
    with deleted_ping (location, at) as (
        delete from ping
        where run_id = run_id_
        returning location, at
    ),
    line (geom) as (
        select st_simplify(st_makeline(location order by at), .0001)
        from deleted_ping
    )
    update run set
        ends_at = now(),
        geom = line.geom
    from line
    where run_id = run_id_;

    open res for select
        303 status,
        hstore('Location', url('/gps/query', jsonb_build_object(
            'run_id', run_id_,
            'sql', 'table gps.head union all table gps.map'
        ))) header
    ;
exception when others then
    perform set_config('httpg.errors', jsonb_build_object('error', sqlerrm)::text, true);
    open res for select
        400 status, null body
        union all
        select null, html from head
        union all
        select null, html from map
    ;
end;
$$;

grant execute on procedure end_run to anon;


drop procedure if exists login;
create or replace procedure login(name_ text, password_ text, res inout refcursor default 'res')
language plpgsql
security definer
set search_path to gps, url, pg_catalog, public
-- begin atomic
as $$
declare runner_id_ uuid;
begin
    with salt (salt) as (
        select gen_salt('bf')
    )
    insert into runner (name, password, salt)
    select name_, crypt(password_, salt), salt
    from salt
    on conflict (name) do
        nothing;
    -- update set
    --     password = crypt(password_, excluded.salt),
    --     salt = excluded.salt
    -- where runner.password = password_;

    select runner_id into runner_id_
    from runner
    where crypt(password_, salt) = password
    limit 1;

    open res for select
        303 status,
        hstore(array[
            ['Location', url('/gps/query', jsonb_build_object(
                'sql', 'table gps.list'
            ))],
            ['Set-Cookie', format('gps.current_runner_id=%s; HttpOnly; Secure; Path=/gps', runner_id_)]
        ]) header
    ;
exception when unique_violation then
    perform set_config('httpg.errors', jsonb_build_object('error', 'duplicate name')::text, true);
    open res for select
        400 status, null body
        union all
        select null, html from head
        union all
        select null, html from login
    ;
end;
$$;

grant execute on procedure end_run to anon;

drop procedure if exists ping;
create or replace procedure ping(run_id_ uuid, location_ geometry(point), inout status int default null, body inout text default null)
language plpgsql
security definer
set search_path to gps, url, pg_catalog, public
as $$
declare geo text;
begin
    insert into ping (run_id, location)
    values (run_id_, location_)
    on conflict (run_id, location, at) do nothing
    returning 200, st_asgeojson(geojson_ping(location, run_id, at))
    into status, body;
exception when check_violation then
    perform set_config('httpg.errors', jsonb_build_object('error', sqlerrm)::text, true);
    case sqlerrm
        when 'no partition of relation "ping" found for row' then
            execute format(
                $sql$
                create table if not exists gps.%I partition of gps.ping
                for values from (%L) to (%L)
                $sql$,
                'ping_' || to_char(now(), 'YYYY_MM'),
                date_trunc('month', now()),
                date_trunc('month', now()) + interval '1 month'
            );
            call ping(run_id_, location_, status, body);
    end case;
end;
$$;

grant execute on procedure ping to anon;
