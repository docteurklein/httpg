\set ON_ERROR_STOP on

-- drop schema if exists grandroc cascade;
create schema if not exists grandroc;

set local search_path to grandroc, url, pg_catalog, public;
create extension if not exists btree_gist;

do $$
begin
if not exists (select from pg_type where typname = 'booking_status' and typnamespace = to_regnamespace('grandroc')) then
    create type booking_status as enum ('in progress', 'confirmed', 'canceled');
end if;
end;
$$;

-- drop table if exists occupant cascade;
create table if not exists occupant (
    occupant text primary key,
    email text,
    tel text
);

do $$
begin
if not exists (select from pg_type where typname = 'amount' and typnamespace = to_regnamespace('grandroc')) then
    create domain amount as numeric(10, 2) check (value >= 0);
end if;
end;
$$;

-- drop table if exists place cascade;
create table if not exists place (
    place text primary key,
    price_1 amount not null,
    price_2 amount not null,
    price_other amount not null,
    taxe_sejour int not null,
    cleaning_price amount not null
);

insert into place (place, price_1, price_2, price_other, taxe_sejour, cleaning_price)
values ('grand gite', 900, 1100, 2000, 1.25, 20)
on conflict (place) do nothing;

-- drop table if exists booking cascade;
create table if not exists booking (
    booking_id uuid primary key default uuidv7(),
    place text not null references place (place) on delete cascade,
    occupant text not null references occupant (occupant) on delete cascade,
    period tstzrange not null,
    status booking_status not null default 'in progress',
    nb_adults int,
    nb_children int,
    nb_horses int,
    with_draps bool default false,
    with_serviette bool default false,
    food_price amount,
    exclude using gist (
        place with =,
        period with &&
    ) where (status = 'confirmed')
);

create or replace function days(period tstzrange) returns int
language sql
immutable strict parallel safe -- leakproof
begin atomic
    select (date_trunc('day', upper(period))::date - date_trunc('day', lower(period))::date);
end;

-- drop view if exists head;
create or replace view head (body)
with (security_invoker) as
    select '<!DOCTYPE html>'
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/cpres/index.css' as href))::text
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/grandroc/index.css' as href))::text
    union all select '<meta name="viewport" content="width=device-width">'
    union all select xmlelement(name h1, 'Le Grand Roc')::text
    union all select xmlelement(name form, xmlattributes(
        'grid' as class,
        'POST' as method,
        url('/grandroc/login', jsonb_build_object(
            'sql', 'select 1',
            'redirect', url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html'
            )),
            'params[0]', 'grandroc'
        )) as action
    ),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'name' as name,
            'name' as placeholder,
            'required' as required
        )),
        xmlelement(name input, xmlattributes(
            'password' as type,
            'password' as name,
            'password' as placeholder,
            'required' as required
        )),
        xmlelement(name input, xmlattributes('submit' as type, 'login' as value))
    )::text
    where current_role <> 'grandroc'
    union all select xmlelement(name nav,
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html'
            )) as href
        ), 'Bookings'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select occupant || ''<br>'' from grandroc.occupant'
            )) as href
        ), 'Occupants'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select place || ''<br>'' from grandroc.place'
            )) as href
        ), 'Places'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/logout', jsonb_build_object(
                'redirect', url('/grandroc/query', jsonb_build_object('sql', 'select * from grandroc.head'))
            )) as href
        ), 'Logout')
    )::text
    where current_role = 'grandroc'
;

-- drop procedure if exists book;
create or replace procedure book(uuid, text, text, int, int, int, int, date, date, inout status int default null, header inout jsonb default null)
language sql
begin atomic
    with httpg (body) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'
    ),
    occupant (occupant) as (
        insert into occupant (occupant) values ($3)
        on conflict (occupant) do nothing
        returning occupant
    )
    insert into grandroc.booking (booking_id, place, occupant, nb_adults, nb_children, nb_horses, with_draps, with_serviette, food_price, period)
    select coalesce($1, uuidv7()), $2, coalesce((select occupant from occupant), $3), $4, $5, $6, body->>'with_draps' = 'on', body->>'with_serviette' = 'on', $7, tstzrange($8, $9, '[]')
    from httpg
    on conflict (booking_id) do update set
        nb_children = excluded.nb_children
    returning 303 status,
    jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
        'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
        'when', to_char($8::date, 'MM-YY')
    ))) header;
end;

create or replace view booking_html (body)
with (security_invoker) as
with httpg (when_) as (
    select to_date(nullif(current_setting('httpg.query', true), '')::jsonb->'qs'->>'when', 'MM-YY')
),
day (d) as (
    select d from httpg, generate_series(
        date_trunc('week', date_trunc('month', coalesce(when_, now()))),
        date_trunc('month', coalesce(when_, now())) + interval '1 month' - interval '1 day',
        '1 day'
    ) d
),
calendar (html) as (
    select xmlelement(name div, xmlattributes(
        'day' as class,
        case when now()::date = d::date
            then 'background-color: oklch(from grey l c h / 0.2)'
        end as style
    ),
        xmlelement(name time, xmlattributes(d::date as timestamp),
            to_char(d, 'dy dd/mm')
        ),
        xmlagg(xmlelement(name section, xmlattributes(
            'booking' as class,
            format('--days: %s; --start-col: %s; --row: %s; --color: %s',
                days(period), date_part('isodow', lower(period)), date_part('day', lower(period))::int % 7,
                case status
                    when 'confirmed' then 'green'
                    when 'in progress' then 'yellow'
                    when 'canceled' then 'red'
                end
            ) as style
        ),
            case when place is not null then
                xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select * from grandroc.head union all select body::text from grandroc.contract_html where booking_id = $1::uuid',
                        'params[0]', booking_id
                    )) as href
                ), format('%s in %s', occupant ,place))
            end
        ) order by booking_id)
    )
    from day
    left join booking on period @> d
    group by d
)
select xmlelement(name form, xmlattributes(
        'grid' as class,
        'POST' as method,
        '/grandroc/query' as action
    ),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$call grandroc.book(nullif($1, '')::uuid, $2, $3, $4::int, nullif($5, '')::int, nullif($6, '')::int, nullif($7, '')::int, $8::date, $9::date)$$ as value
    )),
    xmlelement(name datalist, xmlattributes('places' as id),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(place as value)) order by place) from place), '')
    ),
    xmlelement(name datalist, xmlattributes('occupants' as id),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(occupant as value)) order by occupant) from occupant), '')
    ),
    xmlelement(name input, xmlattributes('hidden' as type, 'params[0]' as name, null as value)),
    xmlelement(name input, xmlattributes('required' as required, 'places' as list, 'params[1]' as name, 'place' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'occupants' as list, 'params[2]' as name, 'occupant' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'number' as type, 'params[3]' as name, 'nb adultes' as placeholder)),
    xmlelement(name input, xmlattributes('number' as type, 'params[4]' as name, 'nb enfants' as placeholder)),
    xmlelement(name input, xmlattributes('number' as type, 'params[5]' as name, 'nb chevaux' as placeholder)),
    xmlelement(name label, 'Draps?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_draps' as name))),
    xmlelement(name label, 'Serviettes?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_serviette' as name))),
    xmlelement(name input, xmlattributes('number' as type, 'params[6]' as name, 'Prix repas' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[7]' as name, 'from' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[8]' as name, 'to' as placeholder)),
    xmlelement(name input, xmlattributes('submit' as type))
)
union all select xmlelement(name nav,
    xmlelement(name a, xmlattributes(
        url.url('/grandroc/query', jsonb_build_object(
            'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
            'when', to_char(coalesce(when_, now()::date) - interval '1 month', 'MM-YY')
        )) as href
    ), 'prev'),
    xmltext(coalesce(when_, now()::date)::text),
    xmlelement(name a, xmlattributes(
        url.url('/grandroc/query', jsonb_build_object(
            'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
            'when', to_char(coalesce(when_, now()::date) + interval '1 month', 'MM-YY')
        )) as href
    ), 'next')
)
from httpg
union all select xmlelement(name div, xmlattributes('calendar' as class), xmlagg(html))
from calendar
;

create or replace view contract_html (body)
with (security_invoker) as
with httpg (error) as (
  select
    nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name div, xmlattributes(true as contenteditable),
  xmlelement(name header, xmlattributes('grid' as class),
    xmlelement(name div, xmlattributes('grid' as class, '--min: 15ch' as style),
      xmlelement(name img, xmlattributes(
        'https://static.wixstatic.com/media/649509_a87968ee91eb4900bc9856f2ce150d2d~mv2.png/v1/fill/w_454,h_476,al_c,q_85,usm_0.66_1.00_0.01,enc_avif,quality_auto/649509_a87968ee91eb4900bc9856f2ce150d2d~mv2.png' as src,
        '100' as width
      )),
      xmlelement(name h2, 'Le Grand Roc'),
      xmlelement(name p, '03250 Ferrières-sur-Sichon'),
      xmlelement(name p, '06 60 77 09 97')
    ),
    xmlelement(name div,
      -- xmlelement(name h2, format('Facture %s-%s', to_char(month, 'YY-MM'), to_char(increment, 'fm000'))),
      -- xmlelement(name p, format('Facturé: %s', invoiced_at::date)),
      -- xmlelement(name p, format('Echéance: %s', deadline_at::date)),
      xmlelement(name h3, occupant.occupant),
      xmlelement(name p, occupant.email)
    )
  ),
  xmlelement(name table,
    xmlelement(name thead,
      xmlelement(name tr,
        xmlelement(name th, 'Libellé'),
        xmlelement(name th, 'Qté'),
        xmlelement(name th, 'PU HT'),
        xmlelement(name th, 'Prix HT'),
        xmlelement(name th, '% TVA'),
        xmlelement(name th, 'TVA'),
        xmlelement(name th, 'TTC')
      )
    ),
    xmlelement(name tbody,
      xmlelement(name tr,
        xmlelement(name td, price_1)
      )
    --   with grouped (bl, shipped_at, lines) as (
    --     select bl, shipped_at, xmlagg(
    --       xmlelement(name tr,
    --         xmlelement(name td, product),
    --         xmlelement(name td, quantity),
    --         xmlelement(name td, unit_price_ht),
    --         xmlelement(name td, total_price_ht),
    --         xmlelement(name td, round(tva_rate * 100, 2)),
    --         xmlelement(name td, total_tva),
    --         xmlelement(name td, total_price_ttc)
    --       )
    --     )
    --     from invoice_line l
    --     where l.invoice = invoice.invoice
    --     group by 1, 2
    --   )
    --   select xmlagg(xmlelement(name tr,
    --     xmlelement(name th, format('BL #%s du %s', bl, shipped_at::date)),
    --     lines
    --   ))
    --   from grouped
    ),
    xmlelement(name tfoot,
      xmlelement(name tr,
        xmlelement(name th, xmlattributes(3 as colspan), 'Total €'),
        xmlelement(name td, ''),
        xmlelement(name td, ''),
        xmlelement(name td, ''),
        xmlelement(name td, xmlelement(name b, ''))
      )
    )
  ),
  xmlelement(name footer,
    xmlelement(name pre, 'Notes'),
    xmlelement(name div, xmlattributes('grid' as class),
        ''
      -- xmlelement(name p, bank_info),
      -- xmlelement(name p, legal_infos)
    )
  )
)::text, booking_id
from booking
join occupant using (occupant)
join place using (place)
;

-- truncate table booking;
-- insert into booking (place, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '3 days') i
-- ;
-- insert into booking (place, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '6 days') i
-- ;
-- insert into booking (place, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '8 days') i
-- ;

create table if not exists admin (
  name text primary key,
  password text not null,
  salt text not null
);

create extension if not exists pgcrypto;

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into admin (name, password, salt)
select 'admin', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;

create or replace function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to grandroc, pg_catalog
begin atomic
with httpg (body) as (
  select current_setting('httpg.query', true)::jsonb->'body'
)
select 'set local role to grandroc'
from admin, httpg
where name = body->>'name'
and password = crypt(body->>'password', salt);
end;

grant execute on function login() to anon;

grant grandroc to anon;

grant usage on schema grandroc to anon, grandroc;
grant select on table head to anon, grandroc;
grant select, insert, update on table booking to grandroc;
grant select, insert on table occupant to grandroc;
grant select, insert on table place to grandroc;
grant select on table booking_html to grandroc;
grant select on table contract_html to grandroc;
grant execute on function days to grandroc;
grant execute on function url.url to anon, grandroc;
grant execute on function url.encode to anon, grandroc;
grant execute on procedure book to grandroc;
