\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

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
\else
create extension if not exists http schema public;
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
, ('%s is %s', 'fr', '%s est %s')
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

create table person_detail (
    person_id uuid primary key default current_person_id(),
    location point default null,
    push_endpoint text default null
);

grant select (person_id, location, push_endpoint),
    insert (location, push_endpoint),
    update (location, push_endpoint),
    delete on table person_detail to person;

alter table person_detail enable row level security;
create policy "owner" on person_detail for all to person using (
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
    state text not null default 'in progress' check (state in ('in progress', 'late', 'approved', 'given')),
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

create procedure give(_good_id uuid, _receiver uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
with interest as (
    update interest
    set state = 'approved'
    where (good_id, person_id) = (_good_id, _receiver)
)
update good
set receiver = _receiver,
given_at = now()
where good_id = _good_id;
end;

grant execute on procedure give to person;

create procedure want(_good_id uuid, level interest_level)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id, origin, level) values (_good_id, current_person_id(), 'manual', level);
end;

grant execute on procedure want to person;

create procedure unwant(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    delete from interest where (good_id, person_id) = (_good_id, current_person_id());
end;
grant execute on procedure unwant to person;

-- alter function http parallel safe;

-- create procedure mark_late_interests()
-- language sql
-- security invoker
-- set search_path to cpres, pg_catalog
-- set parallel_setup_cost to 0
-- set parallel_tuple_cost to 0
-- begin atomic
--     with late as (
--         update cpres.interest
--         set
--             state = 'late',
--             at = now()
--         where at < now() - interval '3 days'
--         and state = 'approved'
--         returning good_id, person_id
--     ),
--     detail as (
--         select push_endpoint
--         from person_detail
--         join late using (person_id)
--         where push_endpoint is not null
--     )
--     select http(('POST', push_endpoint,
--         array[('TTL', 50000)]::http_header[],
--         'application/json',
--         jsonb_build_object()
--     )::http_request)
--     from detail;
-- end;
-- grant execute on procedure mark_late_interests to person;

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

grant execute on function login to person;
