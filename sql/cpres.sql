set search_path to cpres, pg_catalog, public;

begin;

drop schema if exists cpres cascade;
create schema cpres;

-- drop role if exists person;
-- create role person;

grant usage on schema cpres, pg_catalog to person;
grant execute on all functions in schema pg_catalog to person;

create extension if not exists cube;
create extension if not exists earthdistance;

create function current_person_id() returns uuid
immutable strict parallel safe
language plpgsql
security invoker
set search_path to cpres, pg_catalog
as $$
begin
    return current_setting('cpres.person_id', true)::uuid;
exception when invalid_text_representation then
    return null;
end;
$$;
alter function current_person_id() owner to person;
grant execute on function current_person_id to person;

create table person (
    person_id uuid primary key default uuidv7(),
    name text not null,
    location point not null
);

grant select, insert, delete, update on table person to person;



alter table person enable row level security;
create policy "owner" on person for all to person using (true) with check (
    person_id = current_person_id()
);

create table good (
    good_id uuid primary key default uuidv7(),
    description text not null,
    tags text[] not null default '{}',
    medias text[] not null default '{}',
    location point not null,
    giver uuid not null
        references person (person_id)
            on delete cascade,
    given_to uuid default null
        references person (person_id)
            on delete cascade,
    created_at timestamptz not null default now(),
    given_at timestamptz default null
);

grant select, insert, delete, update on table good to person;

alter table good enable row level security;
create policy "owner" on good for all to person using (true) with check (
    giver = current_person_id()
);

create function geojson(point point, props jsonb = '{}') returns jsonb
language sql 
immutable strict leakproof
begin atomic;
    select jsonb_build_object(
        'type', 'Feature',
        'properties', props,
        'geometry', jsonb_build_object(
            'type', 'Point',
            'coordinates', array[point[1], point[0]]
        )
    );
end;

alter function geojson(point, jsonb) owner to person;
grant execute on function geojson to person;

create table interest (
    good_id uuid not null
        references good (good_id)
            on delete cascade,
    person_id uuid not null
        references person (person_id)
            on delete cascade,
    price numeric default null,
    primary key (good_id, person_id)
);

grant select, insert, delete, update on table interest to person;

alter table interest enable row level security;
create policy "owner" on interest for all to person using (true) with check (
    person_id = current_person_id()
);

create view nearby
with (security_invoker)
as with base as (
    select good.*, interest,
    (location <@> (current_setting('httpg.query', true)::jsonb->'qs'->>'location')::point) * 1.609347 as bird_distance_km
    from good
    left join interest on (
        good.good_id = interest.good_id
        and interest.person_id = current_person_id()
    )
    where given_at is null
)
select geojson(base.location, jsonb_build_object(
    'description', xmlconcat(
        (
            select xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
                    'sql', format('call cpres.want(%L)', base.good_id),
                    'redirect', 'referer'
                )) as action),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'Interested!' as value
                ))
            )
            where (interest).good_id is null 
        ),
        (
            select xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
                    'sql', format('call cpres.unwant(%L)', base.good_id),
                    'redirect', 'referer'
                )) as action),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'Not interested anymore!' as value
                ))
            )
            where (interest).good_id is not null 
        ),
        xmlelement(name div, format('by %s', giver.name)),
        xmlelement(name div, format('distance %s km', round(bird_distance_km::numeric, 2))),
        (select xmlagg(
            xmlelement(name a, xmlattributes(media as href),
                xmlelement(name img, xmlattributes(media as src))
            )
        ) from unnest(medias) media)
    ),
    'bird_distance_km', bird_distance_km
)) geojson
from base
join person giver on (base.giver = giver.person_id)
where bird_distance_km < 100;

grant select on table nearby to person;

create view "my goods"
with (security_invoker)
as select xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
        'sql', format('call cpres.want(%L)', good_id),
        'redirect', 'referer'
    )) as action),
    xmlelement(name input, xmlattributes(
        'submit' as type,
        'Interested!' as value
    ))
)::text
from good
where giver = current_person_id();

grant select on table nearby to person;

create procedure give(_good_id uuid, receiver uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
with interest as (
    delete from interest
    where good_id = _good_id
)
update good
set given_to = receiver
where good_id = _good_id;
end;

alter procedure give(uuid, uuid) owner to person;
grant execute on procedure give to person;

create procedure want(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id) values (_good_id, current_person_id());
end;

alter procedure want(uuid) owner to person;
grant execute on procedure want to person;

create procedure unwant(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    delete from interest where (good_id, person_id) = (_good_id, current_person_id());
end;

alter procedure want(uuid) owner to person;
grant execute on procedure want to person;

create function login() returns setof text
immutable strict parallel safe
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    with "user" as (
        select person_id from person where name = (current_setting('httpg.query', true)::jsonb->'params'->>0)
    )
    select format($sql$set local "cpres.person_id" to %L$sql$, person_id)
    from "user"
    where person_id is not null;
end;

alter function login owner to person;
grant execute on function login to person;

create view html as
select $html$<!DOCTYPE html>
<html>
<head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="" />
    <link rel="stylesheet" href="/cpres/index.css" crossorigin="" />
</head>
<body>
$html$
union all select xmlelement(name div, format('Welcome %s!', name))::text
from person
where person_id = current_person_id()
union all select $html$
    <form method="POST" action="/login">
      <fieldset class="grid">
        <input type="hidden" name="sql" value="select $1" />
        <input type="text" name="params[]" placeholder="identifier" />
        <input type="submit" value="login" />
      </fieldset>
    </form>
    <div id="map"></div>
    <script type="module" src="/cpres.js"></script>
</body>
$html$;
grant select on table html to person;

commit;

begin;
insert into person (person_id, name, location) values
    ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'p1', '(46.0734411, 3.666724)'),
    (uuidv7(), 'p2', '(56.073448, 2.666524)');

insert into interest (good_id, person_id, price)
select good_id, person_id, random(1, 10) from person, good;

insert into good (description, location, giver, medias)
select 'mayet', format('(%s, %s)', random(44.000, 49.000), random(2.500, 5.800))::point, person_id, array[format('https://lipsum.app/id/%s/800x900', i)]
from generate_series(1, 1000) i, person;

commit;
