\set ON_ERROR_STOP on

create schema if not exists grandroc;

set local search_path to grandroc, url, pg_catalog, public;
create extension if not exists btree_gist;

-- create type booking_status as enum ('in progress', 'confirmed', 'canceled');

-- drop table if exists booking cascade;
create table if not exists booking (
    room_id text not null,
    occupant text not null,
    period tstzrange not null,
    status booking_status not null default 'in progress',
    exclude using gist (
        room_id with =,
        period with &&
    ) where (status = 'confirmed')
);

create or replace function days(period tstzrange) returns int
language sql
immutable strict parallel safe leakproof
begin atomic
    select (date_trunc('day',upper(period))::date - date_trunc('day',lower(period))::date) + 1;
end;


-- drop view if exists head;
create or replace view head (body) as
    select '<!DOCTYPE html>'
    union all
    select xmlelement(name style, $$
        body {
            display: grid;
            grid-template-columns: repeat(7, 1fr);
            /* flex-wrap: wrap;*/
        }
        time {
            border: 1px solid;
            min-height: calc(95vh / 5);
        }
    $$)::text
;

create or replace view booking_html (body) as
    select xmlelement(name time, xmlattributes(
        d::date as timestamp,
        format('color: %s', case when count(room_id) > 0 then 'red' else 'green' end) as style
    ),
    format('%s: ', date_part('day', d)) || string_agg(case when room_id is null
        then 'N/A'
        else format('%s in %s', occupant ,room_id)
    end, ', '))
    from generate_series(
        date_trunc('week', date_trunc('month', now())),
        date_trunc('month', now()) + interval '1 month' - interval '1 day',
        '1 day'
    ) d
    left join booking on period @> d
    group by d
;

truncate table booking;
insert into booking (room_id, occupant, period)
select
    (array_sample(array['A', 'B', 'C'], 1))[1],
    (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
    tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
from generate_series(now(), now() + interval '1 year', '3 days') i
;
insert into booking (room_id, occupant, period)
select
    (array_sample(array['A', 'B', 'C'], 1))[1],
    (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
    tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
from generate_series(now(), now() + interval '1 year', '6 days') i
;
insert into booking (room_id, occupant, period)
select
    (array_sample(array['A', 'B', 'C'], 1))[1],
    (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
    tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
from generate_series(now(), now() + interval '1 year', '8 days') i
;

grant usage on schema grandroc to anon;
grant select on table head to anon;
grant select on table booking to anon;
grant select on table booking_html to anon;
grant execute on function days to anon;
