\set ON_ERROR_STOP on

create schema if not exists grandroc;

set local search_path to grandroc, url, pg_catalog, public;
create extension if not exists btree_gist;

do $$
begin
if not exists (select from pg_type where typname = 'booking_status') then
    create type booking_status as enum ('in progress', 'confirmed', 'canceled');
end if;
end;
$$;

-- drop table if exists booking cascade;
create table if not exists booking (
    booking_id uuid primary key default uuidv7(),
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
immutable strict parallel safe -- leakproof
begin atomic
    select (date_trunc('day', upper(period))::date - date_trunc('day', lower(period))::date);
end;


-- drop view if exists head;
create or replace view head (body)
with (security_invoker) as
    select '<!DOCTYPE html>'
    union all
    select xmlelement(name link, xmlattributes('stylesheet' as rel, '/grandroc/index.css' as href))::text
    union all
    select '<meta name="viewport" content="width=device-width">'
;

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
            case when room_id is not null then
                xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select * from grandroc.head union all select body::text from grandroc.contract where booking_id = $1::uuid',
                        'params[0]', booking_id
                    )) as href
                ), format('%s in %s', occupant ,room_id))
            end
        ) order by booking_id)
    )
    from day
    left join booking on period @> d
    group by d
)
select xmlelement(name h1, 'Le Grand Roc')
union all select xmlelement(name form, xmlattributes(
        'POST' as method,
        '/grandroc/query' as action
    ),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$
            insert into grandroc.booking (room_id, occupant, period) select $1, $2, tstzrange($3::date, $4::date, '[]') returning
            303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
                'when', to_char($3::date, 'MM-YY')
            ))) header
        $$ as value
    )),
    xmlelement(name input, xmlattributes('required' as required, 'text' as type, 'params[0]' as name, 'room_id' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'text' as type, 'params[1]' as name, 'occupant' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[2]' as name, 'from' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[3]' as name, 'to' as placeholder)),
    xmlelement(name input, xmlattributes('submit' as type))
)
union all select xmlelement(name menu,
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

create or replace view contract (body)
with (security_invoker) as
with httpg (error) as (
  select
    nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name div, xmlattributes(true as contenteditable),
  xmlelement(name header, xmlattributes('grid' as class),
    xmlelement(name div,
      xmlelement(name img, xmlattributes('https://static.wixstatic.com/media/649509_a87968ee91eb4900bc9856f2ce150d2d~mv2.png/v1/fill/w_454,h_476,al_c,q_85,usm_0.66_1.00_0.01,enc_avif,quality_auto/649509_a87968ee91eb4900bc9856f2ce150d2d~mv2.png' as src)),
      xmlelement(name h2, 'Le Grand Roc'),
      xmlelement(name p, '03250 Ferrières-sur-Sichon'),
      xmlelement(name p, '06 60 77 09 97')
    )
    -- xmlelement(name div,
    --   -- xmlelement(name h2, format('Facture %s-%s', to_char(month, 'YY-MM'), to_char(increment, 'fm000'))),
    --   -- xmlelement(name p, format('Facturé: %s', invoiced_at::date)),
    --   -- xmlelement(name p, format('Echéance: %s', deadline_at::date)),
    --   -- xmlelement(name h3, client),
    --   -- xmlelement(name p, client_address)
    -- )
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
    )
    -- xmlelement(name tbody, (
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
    -- )),
    -- xmlelement(name tfoot,
    --   xmlelement(name tr,
    --     xmlelement(name th, xmlattributes(3 as colspan), 'Total €'),
    --     xmlelement(name td, total_ht),
    --     xmlelement(name td, ''),
    --     xmlelement(name td, round(total_tva, 2)),
    --     xmlelement(name td, xmlelement(name b, round(total_ttc, 2)))
    --   )
    -- )
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
;

-- truncate table booking;
-- insert into booking (room_id, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '3 days') i
-- ;
-- insert into booking (room_id, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '6 days') i
-- ;
-- insert into booking (room_id, occupant, period)
-- select
--     (array_sample(array['A', 'B', 'C'], 1))[1],
--     (array_sample(array['simon', 'georges', 'tintin'], 1))[1],
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)')
-- from generate_series(now(), now() + interval '1 year', '8 days') i
-- ;

grant usage on schema grandroc to anon;
grant select on table head to anon;
grant select, insert on table booking to anon;
grant select on table booking_html to anon;
grant select on table contract to anon;
grant execute on function days to anon;
