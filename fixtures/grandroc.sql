set local search_path to grandroc, pg_catalog, public;

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into admin (name, password, salt)
select 'admin', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;


insert into place (place, taxe_sejour, dog_price_unit, cgv) values
('grand gite', 1.25, 0, 'bla bla'),
('camping', 1.25, 3.50, 'bla bla')
on conflict (place) do nothing;

truncate table occupant cascade;
insert into occupant (occupant) values ('georges')
on conflict (occupant) do nothing;

truncate table booking;
insert into booking (place, occupant, price, period, with_cleaning, nb_adults, nb_children, nb_babies, nb_horses, food_price_unit, with_draps, with_serviette, is_early, is_late)
select
    (select place from place order by random() limit 1),
    (select occupant from occupant order by random() limit 1),
    900,
    daterange(i::date, (i + format('%s days', random(2, 8))::interval)::date, '[)'),
    true,
    4,
    2,
    1,
    2,
    20,
    true,
    true,
    true,
    false
from (
    select generate_series(now() - interval '3 weeks', now() + interval '1 week', '3 days')
    union all 
    select generate_series(now() + interval '3 weeks', now() + interval '6 weeks', '5 days')
    union all 
    select generate_series(now() + interval '8 weeks', now() + interval '5 months', '8 days')
) i (i);
