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
create extension if not exists postgis cascade;
create extension if not exists pgrouting cascade;
\if :is_neon
-- create extension if not exists rag cascade;
-- create extension if not exists rag_bge_small_en_v15 cascade;
-- create extension if not exists rag_jina_reranker_v1_tiny_en cascade;
\else
-- create extension if not exists http schema public;
\endif

create schema if not exists gps;

do $$ begin
    create role runner noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;
do $$ begin
    create role runner;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

grant anon to httpg;
grant runner to httpg;

grant usage on schema gps, url, pg_catalog to httpg;
grant usage on schema gps, url, pg_catalog to anon;
alter role runner set search_path to gps, url, pg_catalog, public;

revoke usage on language plpgsql from runner;
revoke usage on language sql from runner;
revoke usage on language plv8 from runner;

grant usage on schema gps to runner;

create extension if not exists cube schema public;
create extension if not exists earthdistance schema public;

create or replace function current_runner_id() returns uuid
volatile strict parallel safe -- leakproof
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    select coalesce(nullif(current_setting('gps.runner_id', true), ''), '5456a81d-356a-48a1-b3ab-17857ee840ca')::uuid;
end;

grant execute on function current_runner_id to person;

create table runner (
    runner_id uuid primary key default uuidv7(),
    name text not null unique check (trim(name) <> '' and position('@' in name) = 0)
);

create table run (
    run_id uuid primary key default uuidv7(),
    name text default null,
    runner_id uuid not null references runner (runner_id) default current_runner_id() 
);

create table ping (
    location geometry(point, 4326) not null,
    run_id uuid not null references run (run_id),
    at timestamptz not null default now(),
    primary key (run_id, location, at)
);

alter table ping enable row level security;
create policy "owner" on ping for all to anon
using (exists(
    select from run
    where run.runner_id = current_runner_id()
    and run.run_id = ping.run_id
));
