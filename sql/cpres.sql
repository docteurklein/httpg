\set ON_ERROR_STOP on

set search_path to cpres, pg_catalog, public;

begin;

drop schema if exists cpres cascade;
commit;

\ir url.sql
begin;

set neon.allow_unstable_extensions='true';
-- drop extension if exists vector cascade;
-- drop extension if exists rag cascade;
-- drop extension if not exists rag_bge_small_en_v15 cascade; 
-- drop extension if not exists rag_jina_reranker_v1_tiny_en cascade; 

select current_setting('neon.project_id', true) is not null as is_neon \gset

create extension if not exists vector cascade;
create extension if not exists fuzzystrmatch cascade;
\if :is_neon
create extension if not exists rag cascade;
create extension if not exists rag_bge_small_en_v15 cascade;
create extension if not exists rag_jina_reranker_v1_tiny_en cascade;
\endif

create schema cpres;

create function cpres.embed_passage(content text)
returns vector
immutable parallel safe -- leakproof
security definer
language sql
begin atomic
    \if :is_neon
    select rag_bge_small_en_v15.embedding_for_passage(content);
    \else
    select array_fill(0.1, array[384])::vector(384);
    \endif
end;

create function cpres.embed_query(query text)
returns vector
immutable parallel safe -- leakproof
security definer
language sql
begin atomic
    \if :is_neon
    select rag_bge_small_en_v15.embedding_for_query(query);
    \else
    select array_fill(0.1, array[384])::vector(384);
    \endif
end;

create function cpres.rerank_distance(query text, content text)
returns real
immutable parallel safe -- leakproof
security definer
language sql
begin atomic
    \if :is_neon
    select rag_jina_reranker_v1_tiny_en.rerank_distance(query, content);
    \else
    select case when content ilike '%'||query||'%' then -1 else 1 end;
    \endif
end;

-- revoke all on schema pg_catalog, public from person;
-- drop role if exists httpg;
-- drop role if exists person;


\if :{?password}
select format('create user httpg with password %L noinherit', :'password')\gexec
\endif
do $$ begin
    create role person noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

grant person to httpg;

revoke usage on language plpgsql from public, httpg, person;
revoke usage on language sql from public, httpg, person;
revoke usage on language plv8 from public, httpg, person;

grant usage, create on schema cpres to person;
-- grant usage on schema pg_catalog, rag_bge_small_en_v15 to person;
-- grant execute on all functions in schema pg_catalog to person;

create extension if not exists cube schema public;
create extension if not exists earthdistance schema public;
create extension if not exists moddatetime schema public;
create extension if not exists vector schema public;

create or replace function current_person_id() returns uuid
volatile strict parallel safe -- leakproof
language plpgsql
security invoker
set search_path to cpres, pg_catalog
as $$
declare person_id uuid;
begin
    select person.person_id into person_id from person where person.person_id = current_setting('cpres.person_id', true)::uuid limit 1;
    return person_id;
exception when invalid_text_representation then
    -- raise warning '%', sqlerrm;
    return null;
end;
$$;

-- alter function current_person_id() owner to person;
grant execute on function current_person_id to person;

create table translation (
    id text not null,
    lang text not null,
    text text not null,
    primary key (id, lang)
);

create index on translation (id, lang);

insert into translation (id, lang, text) values
  ('Welcome %s!', 'fr', 'Bienvenue %s!')
, ('a little interested', 'fr', 'un peu intéressé')
, ('interested', 'fr', 'intéressé')
, ('highly interested', 'fr', 'très intéressé')
, ('Not interested anymore', 'fr', 'Plus intéressé')
, ('Send login challenge', 'fr', 'Envoyer un lien de login')
, ('map', 'fr', 'carte')
, ('search', 'fr', 'Rechercher')
, ('activity', 'fr', 'Notifications')
, ('Receiving activity', 'fr', 'Mes intérêts')
, ('Giving activity', 'fr', 'Dons en cours')
, ('my goods', 'fr', 'Gérer mes biens')
, ('By %s', 'fr', 'Par %s')
, ('%s at %s: ', 'fr', '%s le %s: ')
, ('HH24:MI, TMDay DD/MM', 'fr', 'TMDay DD/MM à HH24:MI')
, ('Search', 'fr', 'Chercher')
, ('query', 'fr', 'Requête')
, ('title', 'fr', 'Titre')
, ('Create alert', 'fr', 'Créer une alerte')
, ('Remove alert', 'fr', 'Supprimer cette alerte')
, (' from %s', 'fr', ' de %s')
, ('Send message', 'fr', 'Envoyer')
, ('New good', 'fr', 'Créér un nouveau bien')
, ('Existing goods', 'fr', 'Mes biens')
, ('Submit', 'fr', 'Enregistrer')
, ('Add file', 'fr', 'Ajouter ce fichier')
, ('Remove', 'fr', 'Supprimer')
, ('Are you sure?', 'fr', 'En êtes-vous sûr?')
, ('Give to %s', 'fr', 'Donner à %s')
, ('Given to %s', 'fr', 'Donné à %s')
, ('Check your emails', 'fr', 'Vérifiez vos emails et clickez sur le lien reçu.')
, ('Nothing yet.', 'fr', 'Rien à lister.')
;


create function cpres._(id_ text, lang_ text = null)
returns text
immutable parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
language sql
begin atomic
    select coalesce(
        (
            with a (accept_language) as (
                select substring(current_setting('httpg.query', true)::jsonb->>'accept_language' from '^(\w+)-\w+,.*')
            )
            select text
            from translation, a
            where (id, lang) = (id_, coalesce(lang_, coalesce(accept_language, 'fr')))
            limit 1
        ),
        id_
    );
end;

create table person (
    person_id uuid primary key default gen_random_uuid(),
    name text not null,
    email text not null unique,
    login_challenge uuid default null
);

grant select (person_id, name),
    insert (name, email),
    update (name, email),
    delete on table person to person;

alter table person enable row level security;
create policy "owner" on person for all to person using (true) with check (
    person_id = current_person_id()
);

create table person_location (
    person_id uuid primary key default gen_random_uuid(),
    location point not null
);

grant select (person_id, location),
    insert (location),
    update (location),
    delete on table person_location to person;

alter table person_location enable row level security;
create policy "owner" on person_location for all to person using (
    person_id = current_person_id()
);

create table good (
    good_id uuid primary key default gen_random_uuid(),
    title text not null check (title <> ''),
    description text not null,
    passage text not null generated always as (title || ': ' || description)
        \if :is_neon
         stored
        \else
        virtual
        \endif
    ,
    embedding vector(384) not null generated always as (embed_passage(title || ': ' || description)) stored,
    tags text[] not null default '{}',
    location point not null,
    giver uuid not null default current_person_id()
        references person (person_id)
            on delete cascade,
    receiver uuid default null
        references person (person_id)
            on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz default null,
    given_at timestamptz default null
);

create index on good using hnsw (embedding vector_cosine_ops);

create trigger updated_at
before update on good
for each row
execute procedure moddatetime (updated_at);

grant select, --(good_id, title, description, tags, location, giver, created_at, updated_at, given_at),
    insert(good_id, title, description, tags, location, receiver, given_at),
    update(good_id, title, description, tags, location, receiver, given_at),
    delete
on table good to person;

alter table good enable row level security;
create policy "owner" on good for all to person using (true) with check (
    giver = current_person_id()
);

create table good_media (
    good_id uuid not null references good (good_id) on delete cascade,
    content bytea not null,
    content_hash bytea primary key generated always as (sha256(content)) stored,
    content_type text not null,
    name text not null
);

grant select, insert, delete, update on table good_media to person;

alter table good_media enable row level security;
create policy "owner" on good_media for all to person
using (true)
with check (
    exists (
        select from good
        where good.giver = current_person_id()
        and good.good_id = good_media.good_id
    )
);

create function geojson(point point, props jsonb = '{}') returns jsonb
language sql 
immutable strict parallel safe -- leakproof
set search_path to cpres, pg_catalog
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

-- alter function geojson(point, jsonb) owner to person;
grant execute on function geojson to person;

create domain interest_level as text
default 'interested'
check (value = any (array['a little interested', 'interested', 'highly interested']));
    
create table interest (
    good_id uuid not null
        references good (good_id)
            on delete cascade,
    person_id uuid not null
        references person (person_id)
            on delete cascade,
    origin text not null check (origin in ('automatic', 'manual')),
    query text default null,
    level interest_level not null,
    price numeric default null,
    at timestamptz not null default now(),
    primary key (good_id, person_id)
);

grant select, insert, delete, update on table interest to person;

alter table interest enable row level security;
create policy "owner" on interest for all to person using (
    person_id = current_person_id()
    or exists (select from good where interest.good_id = good.good_id and giver = current_person_id())
);

create table message (
    message_id uuid primary key default gen_random_uuid(),
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
    author = current_person_id()
    or exists (
        select
        from interest
        where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
    )
)
with check (author = current_person_id());

create table search (
    person_id uuid not null default current_person_id(),
    query text not null,
    embedding vector(384) not null generated always as (embed_query(query)) stored,
    interest interest_level not null,
    primary key (person_id, query)
);

grant select, insert, delete, update on table search to person;

alter table search enable row level security;
create policy "owner" on search for all to person
using (
    person_id = current_person_id()
);

create function compare_search() returns trigger
volatile strict parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
as $$
begin
    with result (good_id, person_id, interest, query, rerank_distance) as (
        select new.good_id, person_id, interest, query, rerank_distance(query, new.passage)
        from search
        where person_id <> new.giver
        order by (new.embedding <=> search.embedding)
        limit 100
    )
    insert into interest (good_id, person_id, level, origin, query)
    select good_id, person_id, interest, 'automatic', query
    from result
    where rerank_distance < 0;

    return null;
end;
$$ language plpgsql;

create trigger compare_search
after insert or update of title, description on good
for each row
execute procedure compare_search();

create view "good_detail" (html, location, bird_distance_km, good_id, receiver)
with (security_invoker)
as with q (location) as (
    select (current_setting('httpg.query', true)::jsonb->'qs'->>'location')
),
base as (
    select good.*, giver.name as giver_name,
        case when q.location <> '' then (good.location <@> q.location::point) * 1.609347 end bird_distance_km
    from q, good
    join person giver on (good.giver = giver.person_id)
)
select xmlelement(name div, xmlattributes(
    geojson(good.location) as "data-geojson"
),
    xmlelement(name h2, xmlelement(name a, xmlattributes(
        url('/query', jsonb_build_object(
            'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
            'params[]', good.good_id,
            'location', q.location::text 
        )) as href
    ), good.title)),
    xmlelement(name span, format(_('By %s'), giver_name)),
    xmlelement(name p, good.description),
    case when bird_distance_km is not null then
        xmlelement(name div, format('distance: %s km', round(bird_distance_km::numeric, 2)))
    end,
    xmlelement(name div, xmlattributes('grid media' as class), coalesce((
        select xmlagg(xmlelement(name div,
            (
                with url (url) as (
                    select url('/query', jsonb_build_object(
                        'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                        'params[]', content_hash,
                        'accept', content_type
                    ))
                )
                select case
                    when starts_with(content_type, 'image/') then xmlelement(name a, xmlattributes(url as href),
                        xmlelement(name img, xmlattributes(url as src))
                    )
                    else xmlelement(name object, xmlattributes(url as data, content_type as type),
                        xmlelement(name a, xmlattributes(url as href), name)
                    )
                end
                from url
            )
        ))
        from good_media
        where good_id = good.good_id
    ), '')),
    (
        select xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object(
                'sql', format('call cpres.want(%L, $1)', good.good_id),
                'redirect', 'referer'
            )) as action,
            'grid' as class
        ),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'a little interested' as value,
                'submit' as type
            ), _('a little interested')),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'interested' as value,
                'submit' as type
            ), _('interested')),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'highly interested' as value,
                'submit' as type
            ), _('highly interested'))
        )
        where not exists (
            select from interest
            where good.good_id = interest.good_id
            and interest.person_id = current_person_id()
        )
        and current_person_id() is not null
        and current_person_id() <> good.giver
    ),
    (
        select xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
                'sql', format('call cpres.unwant(%L)', good.good_id),
                'redirect', 'referer'
            )) as action),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Not interested anymore') as value
            ))
        )
        where exists (
            select from interest
            where good.good_id = interest.good_id
            and interest.person_id = current_person_id()
        )
        and current_person_id() is not null
        and current_person_id() <> good.giver
    )
)::text, good.location, 0, good.good_id, good.receiver
from base good, q;

grant select on table "good_detail" to person;

create view nearby (geojson, bird_distance_km)
with (security_invoker)
as select geojson(location, jsonb_build_object(
    'description', html,
    'bird_distance_km', bird_distance_km
)) geojson, bird_distance_km
from "good_detail"
where receiver is null;
;

grant select on table nearby to person;

create function good_form(params jsonb, sql text) returns xml
security invoker
immutable parallel safe -- leakproof
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
            'table cpres.head union all table cpres."good admin"' as value
        )),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[]' as name,
            _('title') as placeholder,
            -- true as required,
            params->>0 as value
        )),
        xmlelement(name textarea, xmlattributes(
            'params[]' as name,
            'description' as placeholder
        ), coalesce(params->>1, '')),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'params[]' as name,
            _('location: (lat,lng)') as placeholder,
            'location' as class,
            '\(.+,.+\)' as pattern,
            true as required,
            params->>2 as value
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            _('Submit') as value
        ))
    )
)
from query;
end;

-- alter function good_form owner to person;
grant execute on function good_form to person;

create view "good admin" (html)
with (security_invoker)
as
select xmlelement(name div, xmlattributes('new' as class),
    xmlelement(name h2, _('New good')),
    good_form(
        coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}')->'body'->'params',
        'insert into cpres.good (title, description, location) values ($1::text, $2::text, $3::text::point)'
    ),
    xmlelement(name h2, _('Existing goods'))
)::text
union all (
with result as (
select
xmlconcat(
    xmlelement(name hr),
    case when receiver.name is not null then xmltext(format(_('Given to %s'), receiver.name)) end,
    good_form(
        jsonb_build_array(title, description, good.location),
        format('update cpres.good set title = $1::text, description = $2::text, location = $3::text::point where good_id = %L', good_id)
    ),
    xmlelement(name div, xmlattributes('grid media' as class), coalesce((
        select xmlagg(xmlelement(name div,
            (
                with url (url) as (
                    select url('/query', jsonb_build_object(
                        'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                        'params[]', content_hash,
                        'accept', content_type
                    ))
                )
                select case
                    when starts_with(content_type, 'image/') then xmlelement(name a, xmlattributes(url as href),
                        xmlelement(name img, xmlattributes(url as src))
                    )
                    else xmlelement(name object, xmlattributes(url as data, content_type as type),
                        xmlelement(name a, xmlattributes(url as href), name)
                    )
                end
                from url
            ),
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
                     encode(content_hash, 'base64') as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    format($$
                        delete from cpres.good_media
                        where content_hash = decode($1::text, 'base64')
                    $$, good_id) as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'pico-background-red' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Remove') as value
                ))
            )
        ))
        from good_media
        where good_id = good.good_id
    ), '')),
    xmlelement(name form, xmlattributes(
        'POST' as method,
        '/upload' as action,
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
                with f (f) as (
                    select $1::bytea[]
                    -- where array_length($1, 1) is not null
                )
                insert into cpres.good_media (good_id, name, content, content_type)
                select %L, convert_from(f[3], 'UTF8'), f[1], convert_from(f[2], 'UTF8')
                from f
                where f[1] <> ''
                on conflict (content_hash) do nothing
            $$, good_id) as value
        )),
        xmlelement(name input, xmlattributes(
            'file' as type,
            'file' as name,
            true as required
            -- true as multiple
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            _('Add file') as value
        ))
    ),
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
            'sql' as name,
            'delete from cpres.good where good_id = $1::uuid' as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'params[]' as name,
            good_id as value
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            'pico-background-red' as class,
            format('return confirm(%L)', _('Are you sure?')) as onclick,
            _('Remove') as value
        ))
    )
)::text
from good
left join person receiver on (good.receiver = receiver.person_id)
where giver = current_person_id()
order by coalesce(updated_at, created_at) desc, title
)
select * from result
union all select _('Nothing yet.') where not exists (select from result limit 1)
);

grant select on table "good admin" to person;

create view "giving activity" (html)
with (security_invoker)
as with data (good_id, title) as (
    select good_id, title
    from good
    -- join interest using (good_id)
    where giver = current_person_id()
    and exists (select from interest where good_id = good.good_id)
    order by
        coalesce(good.updated_at, good.created_at) desc
),
html (html) as (
    select xmlelement(name div, xmlattributes('grid good' as class), xmlagg(xmlelement(name card,
        xmlelement(name h2, xmlelement(name a, xmlattributes(
            url('/query', jsonb_build_object(
                'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
                'params[]', good_id
            )) as href
        ), title)),
        xmlelement(name div, xmlattributes('grid interest' as class), (
            select xmlagg(xmlelement(name card,
            xmlelement(name div, format(_('%s is %s'), receiver.name, _(interest.level))),
            (
                with message as (
                    select *
                    from message
                    where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
                    order by at asc
                )
                select xmlagg(xmlelement(name div,
                    format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))) || content
                ))
                from message
                join person author on (author.person_id = message.author)
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
                    _('Send message') as value
                ))
            ),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'sql', format('call cpres.give(%L, %L)', interest.good_id, interest.person_id),
                    'redirect', 'referer'
                )) as action
            ),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    format(_('Give to %s'), receiver.name) as value
                ))
            )))
            from interest
            join person receiver on (interest.person_id = receiver.person_id)
            left join person_location receiver_location on (receiver_location.person_id = receiver.person_id)
            where interest.good_id = data.good_id
        ))))
    )::text
    from data
)
select xmlelement(name h1, _('Giving activity'))::text
union all select html::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "giving activity" to person;

create view "receiving activity" (html)
with (security_invoker)
as with data (good, giver_name, receiver_location, interest) as (
    select good, giver.name, receiver_location, interest
    from interest
    join good using (good_id)
    join person giver on (good.giver = giver.person_id)
    left join person_location receiver_location on (receiver_location.person_id = interest.person_id)
    where interest.person_id = current_person_id()
    order by
        coalesce(good.updated_at, good.created_at) desc
),
html (html) as (
    select xmlelement(name div,
        xmlelement(name a, xmlattributes(
            url('/query', jsonb_build_object(
                'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
                'params[]', (good).good_id,
                'location', (receiver_location).location
            )) as href
        ), (good).title),
        xmlelement(name div, format(_('By %s'), giver_name)),
        (
            with message as (
                select *
                from message
                where (message.good_id, message.person_id) = ((interest).good_id, (interest).person_id)
                order by at asc
            )
            select xmlagg(xmlelement(name div,
                format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))) || content
            ))
            from message
            join person author on (author.person_id = message.author)
        ),
        xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object(
                'redirect', 'referer'
            )) as action),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                format('insert into cpres.message (good_id, person_id, content) values(%L, %L, $1)', (interest).good_id, (interest).person_id) as value
            )),
            xmlelement(name textarea, xmlattributes(
                'params[]' as name,
                'message' as placeholder
            ), ''),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Send message') as value
            ))
        )
    )::text
    from data
)
select xmlelement(name h1, _('Receiving activity'))::text
union all select html::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "receiving activity" to person;

create view "activity" (html)
with (security_invoker)
as with result (html) as (
    select xmlelement(name div, xmlattributes('grid' as class),
        xmlelement(name div, (select xmlagg(html::xml) from "giving activity")),
        xmlelement(name div, (select xmlagg(html::xml) from "receiving activity"))
    )
)
select html::text from result;

grant select on table "activity" to person;

create view "findings" (html)
with (security_invoker)
as with q (qs) as (
    select current_setting('httpg.query', true)::jsonb->'qs'
),
map (html) as (
    select $html$
        <div id="map-container">
            <div id="map"></div>
        </div>
        <script type="module" src="/cpres/map.js"></script>
    $html$::xml
),
head (html) as (
    select xmlelement(name div,
        xmlelement(name h2, _('Search')),
        xmlelement(name nav, xmlelement(name ul, (
            select xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
                url('/query', qs || jsonb_build_object(
                    'q', query
                )) as href
            ), query)))
            from search
        ))),
        xmlelement(name form, xmlattributes(
            'GET' as method,
            '/query' as action),
            xmlelement(name input, xmlattributes(
                'q' as name,
                'text' as type,
                _('query') as placeholder,
                qs->>'q' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                qs->>'sql' as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Search') as value
            ))
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'redirect', 'referer'
                )) as action),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'insert into cpres.search (query) values ($1)' as value
                )),
                xmlelement(name input, xmlattributes(
                    'params[]' as name,
                    'hidden' as type,
                    qs->>'q' as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    _('Create alert') as value
                ))
            )
            where qs->>'q' <> ''
            and not exists (select from search where query = qs->>'q')
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'redirect', 'referer'
                )) as action),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'delete from cpres.search where query = $1' as value
                )),
                xmlelement(name input, xmlattributes(
                    'params[]' as name,
                    'hidden' as type,
                    qs->>'q' as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'pico-background-red' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Remove alert') as value
                ))
            )
            where exists (select from search where query = qs->>'q')
        )
    )
    from q
),
list (html) as (
    select xmlelement(name div,
        coalesce((
            with result as (
                select good_id, rerank_distance(qs->>'q', passage)
                from good
                order by embedding <=> embed_query(qs->>'q')
                limit 100
            )
            select xmlagg(html::xml)
            from result
            join "good_detail" using (good_id)
            where case when qs->>'q' <> '' then rerank_distance < 0 else true end
        ), _('Nothing yet.')::xml)
    )
    from q
)
select xmlconcat(
    (select html from head),
    xmlelement(name div, xmlattributes('grid search-results' as class),
        xmlelement(name div, xmlattributes('list' as class), (select html from list)),
        xmlelement(name div, (select html from map))
    )
)::text
;

grant select on table "findings" to person;

create procedure give(_good_id uuid, _receiver uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
with interest as (
    delete from interest
    where good_id = _good_id
)
update good
set receiver = _receiver,
given_at = now()
where good_id = _good_id;
end;

-- alter procedure give(uuid, uuid) owner to person;
grant execute on procedure give to person;

create procedure want(_good_id uuid, level interest_level)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id, origin, level) values (_good_id, current_person_id(), 'manual', level);
end;

-- alter procedure want(uuid) owner to person;
grant execute on procedure want to person;

create procedure unwant(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    delete from interest where (good_id, person_id) = (_good_id, current_person_id());
end;

-- alter procedure unwant(uuid) owner to person;
grant execute on procedure unwant to person;

create function send_login_email(email_ text)
returns table (sender text, "to" text, subject text, plain text, html text)
language sql
volatile parallel safe not leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
    with inserted as (
        insert into cpres.person (name, email, login_challenge)
        values ($1, $1, gen_random_uuid())
        on conflict (email) do update
            set login_challenge = excluded.login_challenge
        returning *
    ),
    url as (
        select inserted.*, url(format('https://%s/login', current_setting('httpg.query', true)::jsonb->>'host'), jsonb_build_object(
            'redirect', url('/query', jsonb_build_object(
                'sql', 'table cpres.head union all table cpres.findings'
            )),
            'login_challenge', login_challenge,
            'sql', 'select'
        )) as url
        from inserted
    )
    select 'florian.klein@free.fr', email, 'cpres: login', url,
        xmlelement(name a, xmlattributes(url as href), format(_('Login as %s'), name))
    from url;
end;

-- alter procedure send_login_email(text) owner to person;
grant execute on function send_login_email(text) to person;

create function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with "user" as (
        update person
        set login_challenge = null
        where login_challenge = (current_setting('httpg.query', true)::jsonb->'qs'->>'login_challenge')::uuid
        returning person_id
    )
    select 'set local role to person'
    union all select format('set local "cpres.person_id" to %L', person_id)
    from "user";
end;

-- alter function login owner to person;
grant execute on function login to person;

create view head (html)
with (security_invoker)
as with q (q) as (
    select current_setting('httpg.query', true)::jsonb
)
select $html$<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="color-scheme" content="light dark" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" />
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.colors.min.css" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css" />
    <link rel="stylesheet" href="/cpres/index.css" crossorigin="" />
</head>
<body>
  <script type="module" src="/cpres.js"></script>
  <main class="container-fluid">
$html$
union all (select format(_('Welcome %s!'), name) from person where person_id = current_person_id())
union all (
    with m (color, m) as (select m.* from q, jsonb_each_text(q->'qs'->'flash') m)
    select xmlelement(name div, xmlattributes(
        true as open,
        'pico-background-' || color as class
    ), m)::text
    from m
    where m is not null
)
union all (
    select xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/email', jsonb_build_object(
            'redirect', url('/query', jsonb_build_object(
                'sql', q->>'sql',
                'flash[green]', _('Check your emails')
            ))
        )) as action
    ),
        xmlelement(name fieldset, xmlattributes('group' as role),
            xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, 'select * from cpres.send_login_email($1)' as value)),
            xmlelement(name input, xmlattributes('text' as type, 'params[]' as name, 'email' as placeholder)),
            xmlelement(name input, xmlattributes('submit' as type, _('Send login challenge') as value))

        )
    )::text
    from q
)
union all (
    select $html$
        <form method="GET" action="/login">
            <input type="text" name="login_challenge" placeholder="login_challenge" />
            <input type="hidden" name="redirect" value="referer" />
            <input type="submit" value="Login" />
        </form>
    $html$
    from q
    where (q->'qs'->>'debug') is not null
)
union all select xmlelement(name div,
    xmlelement(name nav,
        xmlelement(name ul, (
            with menu (name, sql, visible) as (values
                (_('search'), 'table cpres.head union all table cpres."findings"', current_person_id() is not null),
                (_('Giving activity'), 'table cpres.head union all table cpres."giving activity"', current_person_id() is not null),
                (_('Receiving activity'), 'table cpres.head union all table cpres."receiving activity"', current_person_id() is not null),
                (_('my goods'), 'table cpres.head union all table cpres."good admin"', current_person_id() is not null)
            )
            select xmlagg(
                xmlelement(name li,
                    xmlelement(name a, xmlattributes(
                        url('/query', jsonb_build_object(
                            'sql', sql,
                            'location', coalesce(
                                nullif(q->'qs'->>'location', ''),
                                (select location::text from person_location where person_id = current_person_id() limit 1)
                            )
                        )) as href
                    ), name)
                )
            )
            from menu, q
            where visible
        ))
    )
)::text
;
grant select on table head to person;

commit;
