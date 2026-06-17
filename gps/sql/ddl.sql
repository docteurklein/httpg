\set ON_ERROR_STOP on

set local search_path to gps, pg_catalog, public;

set neon.allow_unstable_extensions='true';
-- drop extension if exists vector cascade;
-- drop extension if exists rag cascade;
-- drop extension if not exists rag_bge_small_en_v15 cascade; 
-- drop extension if not exists rag_jina_reranker_v1_tiny_en cascade; 

select current_setting('neon.project_id', true) is not null as is_neon
\gset

-- create extension if not exists vector cascade;
-- create extension if not exists fuzzystrmatch cascade;
create extension if not exists postgis with schema public cascade;
create extension if not exists h3 with schema public cascade;
create extension if not exists h3_postgis with schema public cascade;
-- create extension if not exists cube schema public;
-- create extension if not exists earthdistance schema public;
create extension if not exists pgcrypto schema public;
create extension if not exists hstore schema public;
\if :is_neon
-- create extension if not exists rag cascade;
-- create extension if not exists rag_bge_small_en_v15 cascade;
-- create extension if not exists rag_jina_reranker_v1_tiny_en cascade;
\else
-- create extension if not exists http schema public;
\endif

create schema if not exists gps;

grant usage on schema gps, url, pg_catalog to httpg;
grant usage on schema gps, url, pg_catalog to anon;

-- revoke usage on language plpgsql from runner;
-- revoke usage on language sql from runner;

-- grant usage on schema gps to anon;


create or replace function current_runner_id() returns uuid
volatile strict parallel safe -- leakproof
language sql
security invoker
set search_path to gps, pg_catalog
begin atomic
    select nullif((nullif(current_setting('httpg.query', true), '')::jsonb->'cookies'->>'gps.current_runner_id'), '')::uuid;
end;

grant execute on function current_runner_id to anon;

create table runner (
    runner_id uuid primary key default uuidv7(),
    name text not null unique check (trim(name) <> '' and position('@' in name) = 0),
    password text not null,
    salt text not null
);
alter table runner enable row level security;
create policy "owner" on runner for all to anon
using (runner_id = current_runner_id());

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into gps.runner
select '5456a81d-356a-48a1-b3ab-17857ee840cb', 'flopi', crypt('flopi', salt), salt
from salt;

create table run (
    run_id uuid primary key default uuidv7(),
    name text default to_char(now(), 'TMDay DD/MM/YY, HH24:MI'),
    starts_at timestamptz not null default now(),
    ends_at timestamptz default null,
    runner_id uuid not null references runner (runner_id) default current_runner_id(),
    geom geometry(linestring, 4326) default null
);

alter table run enable row level security;
create policy "owner" on run for all to anon
using (runner_id = current_runner_id());

create table ping (
    location geometry(point, 4326) not null,
    run_id uuid not null references run (run_id),
    at timestamptz not null default now(),
    primary key (run_id, location, at)
) partition by range (at);

alter table ping enable row level security;
create policy "owner" on ping for all to anon
using (exists(
    select from run
    where run.runner_id = current_runner_id()
    and run.run_id = ping.run_id
));

alter table ping enable row level security;
create policy "recent" on ping
as restrictive
for select to anon
using (at >= now() - interval '1 month');
