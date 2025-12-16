\set ON_ERROR_STOP on

set local search_path to desired_cpres, pg_catalog, public;

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

create schema desired_cpres;

create function desired_cpres.embed_passage(content text)
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

create function desired_cpres.embed_query(query text)
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

create function desired_cpres.rerank_distance(query text, content text)
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

grant usage on schema desired_cpres, url, pg_catalog to httpg;
grant usage on schema desired_cpres, url, pg_catalog to person;
alter role person set search_path to desired_cpres, url, pg_catalog;
alter role httpg set search_path to desired_cpres, url, pg_catalog;

revoke usage on language plpgsql from public, httpg, person;
revoke usage on language sql from public, httpg, person;
revoke usage on language plv8 from public, httpg, person;

grant usage, create on schema desired_cpres to person;
-- grant usage on schema pg_catalog, rag_bge_small_en_v15 to person;
-- grant execute on all functions in schema pg_catalog to person;

create extension if not exists cube schema public;
create extension if not exists earthdistance schema public;
create extension if not exists moddatetime schema public;
create extension if not exists vector schema public;

-- create or replace function current_person_id() returns uuid
-- volatile strict parallel safe -- leakproof
-- language plpgsql
-- security invoker
-- set search_path to desired_cpres, pg_catalog
-- as $$
-- declare person_id uuid;
-- begin
--     select person.person_id into person_id from person where person.person_id = current_setting('cpres.person_id', true)::uuid limit 1;
--     return person_id;
-- exception when invalid_text_representation then
--     -- raise warning '%', sqlerrm;
--     return null;
-- end;
-- $$;

create or replace function current_person_id() returns uuid
volatile strict parallel safe -- leakproof
language sql
security invoker
set search_path to desired_cpres, pg_catalog
begin atomic
    select nullif(current_setting('cpres.person_id', true), '')::uuid;
end;

grant execute on function current_person_id to person;

create table translation (
    id text not null,
    lang text not null,
    text text not null,
    primary key (id, lang)
);

create index on translation (id, lang);

create table person (
    person_id uuid primary key default gen_random_uuid(),
    name text not null unique check (trim(name) <> '' and position('@' in name) = 0),
    email text not null unique check (trim(email) <> '' and position('@' in email) <> 0),
    phone text default null unique check (trim(phone) <> ''),
    login_challenge uuid default null
);

grant select (person_id, name, phone),
    insert (name, email, phone),
    update (name, email, phone),
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
    title text not null check (trim(title) <> ''),
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
    content_hash bytea not null generated always as (sha256(content)) stored,
    content_type text not null,
    name text not null,
    primary key (good_id, content_hash)
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
    content text not null check (trim(content) <> ''),
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
