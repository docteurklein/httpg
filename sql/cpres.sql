\set ON_ERROR_STOP on

begin;

set local search_path to cpres, pg_catalog, public;

drop schema if exists cpres cascade;

set neon.allow_unstable_extensions='true';
-- drop extension if exists vector cascade;
-- drop extension if exists rag cascade;
-- drop extension if not exists rag_bge_small_en_v15 cascade; 
-- drop extension if not exists rag_jina_reranker_v1_tiny_en cascade; 

select current_setting('neon.project_id', true) is not null as is_neon \gset

create extension if not exists vector cascade;
\if :is_neon
create extension if not exists rag cascade;
create extension if not exists rag_bge_small_en_v15 cascade; 
create extension if not exists rag_jina_reranker_v1_tiny_en cascade; 
\endif

create schema cpres;

create function cpres.embed_passage(content text)
returns vector
immutable parallel safe
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
immutable parallel safe
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
immutable parallel safe
security definer
language sql
begin atomic
    \if :is_neon
    select rag_jina_reranker_v1_tiny_en.rerank_distance(query, content);
    \else
    select 0;
    \endif
end;

-- revoke all on schema pg_catalog, public from person;
-- drop role if exists httpg;
-- drop role if exists person;

-- create role person noinherit;

-- select format('create user httpg with password %L noinherit', :'password')\gexec
-- -- do $$ begin
-- --     exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
-- -- end $$;

grant person to httpg;

grant usage, create on schema cpres to person;
-- grant usage on schema pg_catalog, rag_bge_small_en_v15 to person;
-- grant execute on all functions in schema pg_catalog to person;

create extension if not exists cube;
create extension if not exists earthdistance;
create extension if not exists moddatetime;
create extension if not exists vector;

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
, ('Interested!', 'fr', 'Intéressé!')
, ('Not interested anymore!', 'fr', 'Plus intéressé!')
, ('Send login challenge', 'fr', 'Envoyer un lien de login')
, ('map', 'fr', 'carte')
, ('search', 'fr', 'Rechercher')
, ('activity', 'fr', 'Notifications')
, ('my goods', 'fr', 'Mes biens')
, ('by %s', 'fr', 'Par %s')
, ('Search', 'fr', 'Chercher')
, ('query', 'fr', 'Requête')
, ('title', 'fr', 'Titre')
, ('Create alert', 'fr', 'Créer une alerte')
, ('Remove alert', 'fr', 'Supprimer cette alerte')
, ('%s is interested by ', 'fr', '%s est intéressé par ')
, (' from %s', 'fr', ' de %s')
, ('Send message', 'fr', 'Envoyer')
, ('New good', 'fr', 'Créér un nouveau bien')
, ('Existing goods', 'fr', 'Mes biens')
, ('Submit', 'fr', 'Enregistrer')
, ('Add image', 'fr', 'Ajouter cette image')
, ('Remove', 'fr', 'Supprimer')
, ('Are you sure?', 'fr', 'En êtes-vous sûr?')
, ('Give to %s', 'fr', 'Donner à %s')
;


create function cpres._(id_ text, lang_ text = null)
returns text
immutable parallel safe
security definer
set search_path to cpres, pg_catalog
language sql
begin atomic
    select coalesce(
        (
            select text
            from translation
            where (id, lang) = (id_, coalesce(lang_, coalesce(current_setting('cpres.accept_language', true), 'fr')))
            limit 1
        ),
        id_
    );
end;

create table person (
    person_id uuid primary key default gen_random_uuid(),
    name text not null,
    email text not null unique,
    login_challenge uuid default null,
    location point default null
);

grant select (person_id, name),
    insert (name, email, location),
    update (name, email, location),
    delete on table person to person;

alter table person enable row level security;
create policy "owner" on person for all to person using (true) with check (
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

grant select, delete,
    insert(good_id, title, description, tags, location, receiver, given_at),
    update(good_id, title, description, tags, location, receiver, given_at)
on table good to person;

alter table good enable row level security;
create policy "owner" on good for all to person using (true) with check (
    giver = current_person_id()
);

create table good_media (
    content_hash bytea primary key generated always as (sha256(content)) stored,
    good_id uuid not null references good (good_id) on delete cascade,
    content bytea not null,
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
immutable strict -- leakproof
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
default 'normal'
check (value = any (array['low', 'normal', 'high']));
    
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

create view nearby (geojson)
with (security_invoker)
as with base as (
    select good.*, interest,
    (location <@> (current_setting('httpg.query', true)::jsonb->'qs'->>'location')::point) * 1.609347 as bird_distance_km
    from good
    left join interest on (
        good.good_id = interest.good_id
        and interest.person_id = current_person_id()
    )
    where receiver is null
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
                    _('Interested!') as value
                ))
            )
            where (interest).good_id is null 
            and current_person_id() is not null
            and current_person_id() <> base.giver
        ),
        (
            select xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
                    'sql', format('call cpres.unwant(%L)', base.good_id),
                    'redirect', 'referer'
                )) as action),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    _('Not interested anymore!') as value
                ))
            )
            where (interest).good_id is not null 
            and current_person_id() is not null
            and current_person_id() <> base.giver
        ),
        xmlelement(name div, format(_('by %s'), giver.name)),
        xmlelement(name div, format('distance: %s km', round(bird_distance_km::numeric, 2))),
        (
            with url (url) as (
                -- select url('/raw', jsonb_build_object(
                --     'sql', format($$values (jsonb_build_object('header', array['content-type', %L])) union all select content::text from cpres.good_media where content_hash = $1 $$, content_type),
                --     'params[]', content_hash
                -- ))
                select url('/query', jsonb_build_object(
                    'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                    'params[]', content_hash,
                    'content_type', content_type
                ))
                from good_media
                where good_id = base.good_id
            )
            select xmlagg(
                xmlelement(name a, xmlattributes(url as href),
                    xmlelement(name img, xmlattributes(url as src))
                )
            )
            from url
        )
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
            _('title') as placeholder,
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


create view "goods" (html, good_id)
with (security_invoker)
as
select xmlelement(name div,
    xmlelement(name h2, good.title),
    xmlelement(name span, format(_('by %s'), giver.name)),
    xmlelement(name p, good.description),
    (
        with url (url) as (
            select url('/query', jsonb_build_object(
                'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                'params[]', content_hash,
                'content_type', content_type
            ))
            from good_media
            where good_media.good_id = good.good_id
        )
        select xmlagg(xmlelement(name a, xmlattributes(url as href),
            xmlelement(name img, xmlattributes(url as src))
        ))
        from url
    )
)::text, good_id
from good
join person giver on (good.giver = giver.person_id);

grant select on table "goods" to person;

create view "my goods" (html)
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
select
xmlconcat(
    xmlelement(name hr),
    case when receiver.name is not null then xmltext(format(_('Given to %s'), receiver.name)) end,
    good_form(
        jsonb_build_array(title, description, good.location),
        format('update cpres.good set title = $1::text, description = $2::text, location = $3::text::point where good_id = %L', good_id)
    ),
    (
        select xmlagg(xmlconcat(
            (
                with url (url) as (
                    select url('/query', jsonb_build_object(
                        'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                        'params[]', content_hash,
                        'content_type', content_type
                    ))
                )
                select xmlelement(name a, xmlattributes(url as href),
                    xmlelement(name img, xmlattributes(url as src))
                )
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
    ),
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
                insert into cpres.good_media (good_id, name, content, content_type)
                select %L, convert_from($2, 'UTF8'), $1, convert_from($3, 'UTF8')
                where $1 <> ''
                on conflict (content_hash) do nothing
            $$, good_id) as value
        )),
        xmlelement(name input, xmlattributes(
            'file' as type,
            'file' as name
            -- true as multiple
        )),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            _('Add image') as value
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
order by updated_at desc nulls last, title);

grant select on table "my goods" to person;

create view "activity"
with (security_invoker)
as select xmlelement(name div,
    format(_('%s is interested by '), receiver.name),
    xmlelement(name a, xmlattributes(
        url('/query', jsonb_build_object(
            'sql', 'table cpres.head union all select html from cpres."goods" where good_id = $1::uuid',
            'params[]', good.good_id
        )) as href
    ), good.title),
    format(_(' from %s'), giver.name),
    (
        with message as (
            select *
            from message
            where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
            order by at asc
        )
        select xmlagg(xmlelement(name div,
            format(_('by %s'), author.name) || ': ' || content
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
    (select xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/query', jsonb_build_object(
            'sql', format('call cpres.give(%L, %L)', interest.good_id, interest.person_id),
            'redirect', 'referer'
        )) as action),
        xmlelement(name input, xmlattributes(
            'submit' as type,
            format(_('Give to %s'), receiver.name) as value
        ))
    ) where interest.person_id <> current_person_id())
)::text
from interest
join good using (good_id)
join person receiver using (person_id)
join person giver on (giver.person_id = good.giver)
where giver = current_person_id()
or interest.person_id = current_person_id()
order by (
    select max(at)
    from message
    where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
) desc nulls last,
interest.at desc;

grant select on table "activity" to person;

create view "findings" (html)
with (security_invoker)
as with q (q) as (
    select current_setting('httpg.query', true)::jsonb->'qs'->>'q'
)
select xmlelement(name div,
    xmlelement(name h2, _('Search')),
    xmlelement(name nav, xmlelement(name ul, (
        select xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
            url('/query', jsonb_build_object(
                'q', query,
                'sql', current_setting('httpg.query', true)::jsonb->'qs'->>'sql'
            )) as href
        ), query)))
        from search
    ))),
    xmlelement(name form, xmlattributes(
        'GET' as method,
        url('/query') as action),
        xmlelement(name input, xmlattributes(
            'q' as name,
            'text' as type,
            _('query') as placeholder,
            q as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            current_setting('httpg.query', true)::jsonb->'qs'->>'sql' as value
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
                q as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Create alert') as value
            ))
        )
        where q <> ''
        and not exists (select from search where query = q)
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
                q as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                'pico-background-red' as class,
                'return confirm("Are you sure?")' as onclick,
                _('Remove alert') as value
            ))
        )
        where exists (select from search where query = q)
    ),
    (
        with result as (
            select q, good_id, title, passage
            from good
            where giver <> current_person_id()
            order by embedding <=> embed_query(q)
            limit 100
        )
        select xmlagg(html::xml) -- xmlagg(xmlelement(name div, format('%s: %s', title, rerank_distance(q, passage))) order by rerank_distance(q, passage))
        from result
        join "goods" using (good_id)
    )
)::text
from q;

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

create procedure want(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id, origin) values (_good_id, current_person_id(), 'manual');
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

create procedure send_login_email(text)
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with info (challenge, email) as (
        select gen_random_uuid(), $1
    ),
    response (res) as (
        select null
        -- select http(('POST', 'https://send.api.mailtrap.io/api/send',
        --     array[('Api-Token', current_setting('mailtrap.api_token', true))]::http_header[],
        --     'application/json',
        --     jsonb_build_object(
        --         'from', jsonb_build_object(
        --             'email', 'flo@example.org',
        --             'name', 'Flo'
        --         ),
        --         'to', jsonb_build_array(jsonb_build_object(
        --             'email', 'florian.klein@free.fr',
        --             'name', 'Florian Klein'
        --         )),
        --         'subject', 'test from postgres!',
        --         'html', format($html$
        --             <form method="POST" action="/login?redirect=referer">
        --                 <input type="hidden" name="sql" value="" />
        --                 <input type="hidden" name="challenge" value="%s" />
        --                 <input type="submit" value="Login as %s" />
        --             </form>
        --         $html$, challenge, email)
        --     )
        -- )::http_request)
        -- from info
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

-- alter procedure send_login_email(text) owner to person;
grant execute on procedure send_login_email(text) to person;

create function login() returns setof text
volatile strict parallel safe
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with "user" as (
        update person
        set login_challenge = login_challenge -- TODO: set login_challenge = null
        where login_challenge = (current_setting('httpg.query', true)::jsonb->'body'->>'challenge')::uuid
        returning person_id
    )
    select format($sql$set local role to person; set local "cpres.person_id" to %L$sql$, person_id)
    from "user";
end;

-- alter function login owner to person;
grant execute on function login to person;

create view head (html)
with (security_invoker)
as select $html$<!DOCTYPE html>
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
  <main class="container">
$html$
union all (
    select xmlelement(name form, xmlattributes('POST' as method, '/query?redirect=referer' as action),
        xmlelement(name fieldset, xmlattributes('group' as role),
            xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, 'call cpres.send_login_email($1::text)' as value)),
            xmlelement(name input, xmlattributes('text' as type, 'params[]' as name, 'email' as placeholder)),
            xmlelement(name input, xmlattributes('submit' as type, _('Send login challenge') as value))

        )
    )::text
)
union all (
    select format($html$
        <form method="POST" action="/login?redirect=referer">
            <input type="text" name="challenge" />
            <input type="submit" value="Login as %s" />
        </form>
    $html$, name)
    from person
    where true -- login_challenge is not null
    and (current_setting('httpg.query', true)::jsonb->'qs'->>'debug') is not null -- TODO remove
    order by name
)
union all select xmlelement(name div,
    (select format(_('Welcome %s!'), name) from person where person_id = current_person_id()),
    xmlelement(name nav,
        xmlelement(name ul, (
            with menu (name, sql, visible) as (values
                (_('map'), 'table cpres.head union all table cpres.map', true),
                (_('search'), 'table cpres.head union all table cpres."findings"', current_person_id() is not null),
                (_('activity'), 'table cpres.head union all table cpres."activity"', current_person_id() is not null),
                (_('my goods'), 'table cpres.head union all table cpres."my goods"', current_person_id() is not null)
            )
            select xmlagg(
                xmlelement(name li, xmlelement(name a, xmlattributes(url('/query', jsonb_build_object('sql', sql)) as href), name))
            )
            from menu
            where visible
        ))
    )
)::text
;
grant select on table head to person;

create view map (html) as
select $html$
  </main>
  <div id="map"></div>
  <script type="module" src="/cpres/map.js"></script>
</body>
$html$;

grant select on table map to person;

insert into person (person_id, name, email, location, login_challenge) values
    ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'p1', 'p1@example.org', '(46.0734411, 3.666724)', gen_random_uuid()),
    ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffb', 'p2', 'p2@example.org', '(56.073448, 2.666524)', gen_random_uuid()),
    (gen_random_uuid(), 'p3', 'p3@example.org', '(26.073448, 5.666524)', gen_random_uuid());

-- insert into search (person_id, query, tags, interest) values
--     ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'chaise en bois', '{}', 'high'),
--     ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffb', 'chaise en metal', '{}', 'high');

-- create or replace function random_string(int)
-- returns text
-- as $$ 
--   select array_to_string(
--     array (
--       select substring(
--         '0123456789abcdefghijklmnopqrstuvwxyz ' 
--         from (random() *37)::int for 1)
--       from generate_series(1, $1) ), '' ) 
-- $$ language sql;

-- insert into good (title, description, location, giver)
-- select
--     -- format('good %s %s', name, i),
--     random_string(random(5, 10)),
--     random_string(random(50, 100)),
--     format('(%s, %s)', random(46.000, 46.200), random(3.600, 3.700))::point,
--     person_id -- , array[format('https://lipsum.app/id/%s/800x900', i)]
-- from generate_series(1, 10) i, person
-- where name <> 'p3';

-- insert into interest (good_id, person_id, price, origin)
-- select good_id, person_id, random(1, 10), 'manual'
-- from person, good
-- where person.person_id <> good.giver;

-- insert into message (good_id, person_id, author, content)
-- select interest.good_id, interest.person_id, person.person_id, i::text || ' ' || random(1, 10)
-- from interest, person, generate_series(1, 3) i
-- where person.person_id = interest.person_id;
-- on conflict do nothing;
commit;
