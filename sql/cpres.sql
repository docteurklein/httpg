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
create extension if not exists moddatetime;

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
    email text not null unique,
    login_challenge uuid default null,
    location point default null
);

grant select, insert, delete, update on table person to person;

alter table person enable row level security;
create policy "owner" on person for all to person using (true) with check (
    person_id = current_person_id()
);

create table good (
    good_id uuid primary key default uuidv7(),
    title text not null check (title <> ''),
    description text not null,
    tags text[] not null default '{}',
    medias text[] not null default '{}',
    location point not null,
    giver uuid not null default current_person_id()
        references person (person_id)
            on delete cascade,
    given_to uuid default null
        references person (person_id)
            on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz default null,
    given_at timestamptz default null
);

create trigger updated_at
before update on good
for each row
execute procedure moddatetime (updated_at);

grant select, delete,
    insert(good_id, title, description, tags, medias, location, given_to, given_at),
    update(good_id, title, description, tags, medias, location, given_to, given_at)
on table good to person;

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
    at timestamptz not null default now(),
    primary key (good_id, person_id)
);

grant select, insert, delete, update on table interest to person;

alter table interest enable row level security;
create policy "owner" on interest for all to person using (true) with check (
    person_id = current_person_id()
);

create table message (
    message_id uuid primary key default uuidv7(),
    good_id uuid not null
        references good (good_id)
            on delete cascade,
    person_id uuid not null
        references person (person_id)
            on delete cascade,
    author uuid not null default current_person_id()
        references person (person_id)
            on delete cascade,
    content text not null check (content <> ''),
    at timestamptz not null default now(),
    foreign key (good_id, person_id) references interest (good_id, person_id)
        on delete cascade
);

grant select, insert, delete, update on table message to person;

alter table message enable row level security;
create policy "owner" on message for all to person
using (
    true
    -- author = current_person_id()
    -- or exists (select from good where message.good_id = good.good_id and giver = current_person_id())
)
with check (author = current_person_id());

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
    where given_to is null
)
select geojson(base.location, jsonb_build_object(
    'description', xmlconcat(
        xmlelement(name h3, base.title),
        xmlelement(name p, base.description),
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
            and current_person_id() is not null
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
            and current_person_id() is not null
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

create function good_form(params jsonb, sql text) returns xml
security invoker
immutable parallel safe
language sql
begin atomic
with query (redirect, errors) as (
    select coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}')->>'redirect',
    coalesce(nullif(current_setting('httpg.errors', true), '')::jsonb, '{}')
)
select xmlelement(name form, xmlattributes(
        'POST' as method,
        '/query' as action
    ),
    xmlelement(name fieldset, xmlattributes('grid' as class),
        xmlelement(name div, coalesce(errors->>'error', '')),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'redirect' as name,
            coalesce(redirect, 'referer') as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            sql as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'table cpres.head union all table cpres."my goods"' as value
        )),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[]' as name,
            'title' as placeholder,
            true as required,
            params->>0 as value
        )),
        xmlelement(name textarea, xmlattributes(
            'params[]' as name,
            'description' as placeholder
        ), coalesce(params->>1, '')),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[]' as name,
            'location: (lat,lng)' as placeholder,
            'location' as class,
            '\(.+,.+\)' as pattern,
            true as required,
            params->>2 as value
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type
        ))
    )
)
from query;
end;

alter function good_form owner to person;
grant execute on function good_form to person;

create view "my goods"
with (security_invoker)
as
select xmlelement(name div, xmlattributes('new' as class),
    good_form(
        coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}')->'body'->'params',
        'insert into cpres.good (title, description, location) values ($1::text, $2::text, $3::text::point)'
    )
)::text
union all (
select
xmlconcat(
    xmlelement(name hr),
    case when receiver.name is not null then xmltext(format('Given to %s', receiver.name)) end,
    good_form(
        jsonb_build_array(title, description, good.location),
        format('update cpres.good set title = $1::text, description = $2::text, location = $3::text::point where good_id = %L', good_id)
    ),
    (
        select xmlagg(xmlconcat(
            xmlelement(name img, xmlattributes(value as src, 'lazy' as loading)),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                '/query' as action
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'redirect' as name,
                    'referer' as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'params[]' as name,
                     value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    format($$
                        update cpres.good
                        set medias = array_remove(medias, $1)
                        where good_id = %L
                    $$, good_id) as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'Remove' as value
                ))
            )
        ))
        from unnest(medias) as _(value)
    ),
    xmlelement(name form, xmlattributes(
        'POST' as method,
        '/query' as action,
        'multipart/form-data' as enctype
    ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'redirect' as name,
            'referer' as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            format($$
                with upload (upload) as (
                    select array_agg('data:image/svg+xml;base64,' || value)
                    from jsonb_each_text(
                        current_setting('httpg.query')::jsonb->'files'
                    )
                )
                update cpres.good
                set medias = medias || upload
                from upload
                where good_id = %L
            $$, good_id) as value
        )),
        xmlelement(name input, xmlattributes(
            'file' as type,
            'file' as name,
            true as multiple
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'Add images' as value
        ))
    )
)::text
from good
left join person receiver on (given_to = receiver.person_id)
where giver = current_person_id()
order by updated_at desc nulls last, title);

grant select on table "my goods" to person;

create view "activity"
with (security_invoker)
as select xmlelement(name div,
    format('%s is interested by %s', receiver.name, good.title),
    (
        with message as (
            select *
            from message
            where good_id = interest.good_id
            and person_id = interest.person_id
            order by at asc
        )
        select xmlagg(xmlelement(name div,
            'by ' || person.name || ': ',
            content
        ))
        from message
        join person on (person.person_id = author)
    ),
    xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/query', jsonb_build_object(
            'redirect', 'referer'
        )) as action),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            format('insert into cpres.message (good_id, person_id, content) values(%L, %L, $1)', interest.good_id, interest.person_id) as value
        )),
        xmlelement(name textarea, xmlattributes(
            'params[]' as name,
            'message' as placeholder
        ), ''),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'Send message' as value
        ))
    ),
    xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/query', jsonb_build_object(
            'sql', format('call cpres.give(%L, %L)', interest.good_id, interest.person_id),
            'redirect', 'referer'
        )) as action),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'Give' as value
        ))
    )
)::text
from interest
join person receiver using (person_id)
join good using (good_id)
where giver = current_person_id()
or interest.person_id = current_person_id()
order by (select max(at) from message where message.good_id = interest.good_id and message.person_id = interest.person_id) desc, interest.at desc;

grant select on table "activity" to person;

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
set given_to = receiver,
given_at = now()
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

alter procedure unwant(uuid) owner to person;
grant execute on procedure unwant to person;

create procedure send_login_email(text)
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with info (challenge, email) as (
        select uuidv4(), $1
    ),
    response (res) as (
        select http(('POST', 'https://send.api.mailtrap.io/api/send',
            array[('Api-Token', current_setting('mailtrap.api_token', true))]::http_header[],
            'application/json',
            jsonb_build_object(
                'from', jsonb_build_object(
                    'email', 'flo@example.org',
                    'name', 'Flo'
                ),
                'to', jsonb_build_array(jsonb_build_object(
                    'email', 'florian.klein@free.fr',
                    'name', 'Florian Klein'
                )),
                'subject', 'test from postgres!',
                'html', format($html$
                    <form method="POST" action="/login?redirect=referer">
                        <input type="hidden" name="sql" value="" />
                        <input type="hidden" name="challenge" value="%s" />
                        <input type="submit" value="Login as %s" />
                    </form>
                $html$, challenge, email)
            )
        )::http_request)
        from info
    )
    insert into person (name, email, login_challenge)
    select email, email, challenge
    from response, info
    -- where response.status = 200
    on conflict (email) do update
        set login_challenge = excluded.login_challenge
        -- name = excluded.name
    ;
end;

alter procedure send_login_email(text) owner to florian;
grant execute on procedure send_login_email(text) to person;

create function login() returns setof text
volatile strict parallel safe
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with "user" as (
        update person set login_challenge = login_challenge
        where login_challenge = (current_setting('httpg.query', true)::jsonb->'body'->>'challenge')::uuid
        returning person_id
    )
    select format($sql$set local "cpres.person_id" to %L$sql$, person_id)
    from "user";
end;

alter function login owner to florian;
grant execute on function login to person;

create view head as
select $html$<!DOCTYPE html>
<html>
<head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css" />
    <link rel="stylesheet" href="/cpres/index.css" crossorigin="" />
</head>
<body>
  <script type="module" src="/cpres.js"></script>
  <main class="container">
    <form method="POST" action="/query?redirect=referer">
      <fieldset class="grid">
        <input type="hidden" name="sql" value="call cpres.send_login_email($1::text)" />
        <input type="text" name="params[]" placeholder="email" />
        <input type="submit" value="Send login challenge" />
      </fieldset>
    </form>
$html$
union all (select format($html$
    <form method="POST" action="/login?redirect=referer">
        <input type="hidden" name="sql" value="" />
        <input type="hidden" name="challenge" value="%s" />
        <input type="submit" value="Login as %s" />
    </form>
$html$, login_challenge, name)
from person
where login_challenge is not null
order by name)
union all select xmlelement(name div,
    (select format('Welcome %s!', name) from person where person_id = current_person_id()),
    xmlelement(name ul,
        xmlelement(name li, xmlelement(name a, xmlattributes('/query?sql=table cpres.head union all table cpres.map' as href), 'map')),
        (
            select xmlelement(name li, xmlelement(name a, xmlattributes('/query?sql=table cpres.head union all table cpres."activity"' as href), 'activity'))
            where current_person_id() is not null),
        (
            select xmlelement(name li, xmlelement(name a, xmlattributes('/query?sql=table cpres.head union all table cpres."my goods"' as href), 'my goods'))
            where current_person_id() is not null
        )
    )
)::text
;
grant select on table head to person;

create view map as
select $html$
  </main>
  <div id="map"></div>
  <script type="module" src="/cpres/map.js"></script>
</body>
$html$;
grant select on table map to person;

commit;

begin;
insert into person (person_id, name, email, location, login_challenge) values
    ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'p1', 'p1@example.org', '(46.0734411, 3.666724)', uuidv4()),
    (uuidv7(), 'p2', 'p2@example.org', '(56.073448, 2.666524)', uuidv4()),
    (uuidv7(), 'p3', 'p3@example.org', '(26.073448, 5.666524)', uuidv4());

insert into good (title, description, location, giver, medias)
select format('good %s %s', name, i), format('good %s %s', name, i), format('(%s, %s)', random(46.000, 46.200), random(3.600, 3.700))::point, person_id, array[format('https://lipsum.app/id/%s/800x900', i)]
from generate_series(1, 100) i, person
where name <> 'p3';

insert into interest (good_id, person_id, price)
select good_id, person_id, random(1, 10)
from person, good
where person.person_id <> good.giver;

insert into message (good_id, person_id, author, content)
select interest.good_id, interest.person_id, person.person_id, i::text || ' ' || random(1, 10)
from interest, person, generate_series(1, 3) i
where person.person_id = interest.person_id;
-- on conflict do nothing;
commit;
