\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog;

truncate person, good, person_detail cascade;

insert into person (person_id, name, email, login_challenge) values
    ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'p1', 'p1@example.org', gen_random_uuid()),
    ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffb', 'p2', 'p2@example.org', gen_random_uuid()),
    ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffc', 'p3', 'p3@example.org', gen_random_uuid());

insert into person (person_id, name, email, login_challenge)
select gen_random_uuid(), 'p'||i, format('p%s@example.org', i), gen_random_uuid()
from generate_series(4, 100) i;

-- insert into person_detail (person_id, location) values
--     ('13a00cef-59d8-4849-b33f-6ce5af85d3d2','(46.0734411, 3.666724)'),
--     ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffb','(56.073448, 2.666524)')
-- ;

insert into person_detail (person_id, location)
select person_id, format('(%s, %s)', random(44.000, 48.200), random(1.600, 5.700))::point
from person p;

insert into search (person_id, query, interest) values
    ('13a00cef-59d8-4849-b33f-6ce5af85d3d2', 'chaise en bois', 'highly interested'),
    ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffb', 'chaise en metal', 'interested'),
    ('3f1ba7e6-fd55-4de3-92f7-555d4e1aeffc', 'table', 'interested');

insert into search (person_id, query, interest)
select person_id, 'search '||i, 'interested'
from generate_series(1, 5) i, person;

create or replace function random_string(int)
returns text
as $$ 
    select array_to_string(array(
        select substring('0123456789abcdefghijklmnopqrstuvwxyz ' from (random() * 37)::int for 1)
        from generate_series(1, $1)
    ), '')
$$ language sql;

insert into good (title, description, location, giver)
select
    random_string(random(5, 10)),
    random_string(random(50, 100)),
    location,
    person_id
from generate_series(1, 5) i, person
join person_detail using (person_id);

insert into interest (good_id, person_id, price, origin, level)
select good_id, person.person_id, random(1, 10), 'manual', 'interested'
from person, good tablesample system (20)
where person.person_id <> good.giver;

insert into message (good_id, person_id, author, content)
select interest.good_id, interest.person_id, person.person_id, i::text || ' ' || random(1, 10)
from interest, person, generate_series(1, 3) i
where person.person_id = interest.person_id;

