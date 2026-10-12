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
    tel text,
    address text
);

do $$
begin
if not exists (select from pg_type where typname = 'amount' and typnamespace = to_regnamespace('grandroc')) then
    create domain amount as numeric(10, 2) check (value >= 0);
end if;
end;
$$;

drop table if exists place cascade;
create table if not exists place (
    place text primary key,
    taxe_sejour amount not null,
    cleaning_price amount not null
);

insert into place (place, taxe_sejour, cleaning_price)
values ('grand gite', 1.25, 20)
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
    with_cleaning bool default false,
    food_price_unit amount,
    is_pension_complete bool default false,
    price amount not null,
    at date default now(),
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
    with httpg (error) as (
        select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
    )
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
                'sql', 'select * from grandroc.head union all select body::text from grandroc.occupant_html'
            )) as href
        ), 'Occupants'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
            )) as href
        ), 'Places'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/logout', jsonb_build_object(
                'redirect', url('/grandroc/query', jsonb_build_object('sql', 'select * from grandroc.head'))
            )) as href
        ), 'Logout')
    )::text
    where current_role = 'grandroc'
    union all
    select xmlelement(name div, xmlattributes('flashes onhover' as class),
        xmlelement(name article, xmlattributes('blue card' as class), error)
    )::text
    from httpg
;

-- drop procedure if exists book;
create or replace procedure book(
    booking_id uuid,
    place text,
    occupant text,
    nb_adults int,
    nb_children int,
    nb_horses int,
    food_price_unit amount,
    price amount,
    from_ date,
    to_ date,
    inout status int default null,
    header inout jsonb default null
)
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
    insert into grandroc.booking (booking_id, place, occupant, nb_adults, nb_children, nb_horses, with_draps, with_serviette, with_cleaning, food_price_unit, is_pension_complete, price, period)
    select
        coalesce(booking_id, uuidv7()),
        place,
        coalesce((select occupant from occupant), occupant),
        nb_adults,
        nb_children,
        nb_horses,
        body->>'with_draps' = 'on',
        body->>'with_serviette' = 'on',
        body->>'with_cleaning' = 'on',
        food_price_unit,
        body->>'is_pension_complete' = 'on',
        price,
        tstzrange(from_, to_, '[]')
    from httpg
    on conflict (booking_id) do update set
        nb_children = excluded.nb_children
    returning 303 status,
    jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
        'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
        'when', to_char(from_::date, 'MM-YY')
    ))) header;
end;


-- drop view if exists occupant_html;
create or replace view occupant_html (body)
with (security_invoker) as
    with httpg (body) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
            'grid' as class,
            'POST' as method,
            '/grandroc/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            $$
                insert into grandroc.occupant (occupant, tel, email, address)
                values ($1, $2, $3, $4)
                on conflict (occupant) do update set
                    tel = excluded.tel,
                    email = excluded.email,
                    address = excluded.address
                returning 303 status,
                jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                    'sql', 'select * from grandroc.head union all select body::text from grandroc.occupant_html'
                ))) header;
            $$ as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'select * from grandroc.head union all select body::text from grandroc.occupant_html' as value
        )),
        xmlelement(name label, 'Nom', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, occupant as value))),
        xmlelement(name label, 'Tél', xmlelement(name input, xmlattributes('params[1]' as name, 'tel' as type, 'required' as required, tel as value))),
        xmlelement(name label, 'email', xmlelement(name input, xmlattributes('params[2]' as name, 'email' as type, 'required' as required, email as value))),
        xmlelement(name label, 'Adresse', xmlelement(name textarea, xmlattributes('params[3]' as name, 5 as rows, 'required' as required), coalesce(address, ''))),
        xmlelement(name input, xmlattributes('submit' as type))
    ))
    from httpg, occupant
;

-- drop view if exists place_html;
create or replace view place_html (body)
with (security_invoker) as
    with httpg (body) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
            'grid' as class,
            'POST' as method,
            '/grandroc/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            $$
                insert into grandroc.place (place, taxe_sejour, cleaning_price)
                values ($1, $2::amount, $3::amount)
                on conflict (place) do update set
                    taxe_sejour = excluded.taxe_sejour,
                    cleaning_price = excluded.cleaning_price
                returning 303 status,
                jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                    'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
                ))) header;
            $$ as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'select * from grandroc.head union all select body::text from grandroc.place_html' as value
        )),
        xmlelement(name label, 'Logement', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, place as value))),
        xmlelement(name label, 'Taxe de séjour', xmlelement(name input, xmlattributes('params[1]' as name, 'number' as type, 'required' as required, taxe_sejour as value))),
        xmlelement(name label, 'Prix ménage', xmlelement(name input, xmlattributes('params[2]' as name, 'number' as type, cleaning_price as value))),
        xmlelement(name input, xmlattributes('submit' as type)
    )))
    from httpg, place
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
            'booking' as class
            -- format('--days: %s; --start-col: %s; --row: %s; --color: %s',
            --     days(period), date_part('isodow', lower(period)), date_part('day', lower(period))::int % 7,
            --     case status
            --         when 'confirmed' then 'green'
            --         when 'in progress' then 'yellow'
            --         when 'canceled' then 'red'
            --     end
            -- ) as style
        ),
            case when place is not null then
                xmlconcat(xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select body::text from grandroc.contract_html where booking_id = $1::uuid',
                        'params[0]', booking_id
                    )) as href
                ), format('%s in %s', occupant ,place)),
                xmlelement(name form, xmlattributes(
                    'POST' as method,
                    '/grandroc/query' as action
                ),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'redirect' as name,
                        'referer' as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'sql' as name,
                        'delete from grandroc.booking where booking_id = $1::uuid' as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'params[]' as name,
                        booking_id as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'submit' as type,
                        'destructive' as class,
                        format('return confirm(%L)', 'Are you sure?') as onclick,
                        '[x]' as value
                    ))
                ))
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
        $$
            call grandroc.book(
                booking_id => nullif($1, '')::uuid,
                place => $2,
                occupant => $3,
                nb_adults => $4::int,
                nb_children => nullif($5, '')::int,
                nb_horses => nullif($6, '')::int,
                food_price_unit => nullif($7, '')::grandroc.amount,
                price => nullif($8, '')::grandroc.amount,
                from_ => $9::date,
                to_ => $10::date
            )
        $$ as value
    )),
    xmlelement(name datalist, xmlattributes('occupants' as id),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(occupant as value)) order by occupant) from occupant), '')
    ),
    xmlelement(name input, xmlattributes('hidden' as type, 'params[0]' as name, null as value)),
    xmlelement(name select, xmlattributes('params[1]' as name, 'required' as required),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(place as value), place) order by place) from place), '')
    ),
    xmlelement(name input, xmlattributes('required' as required, 'occupants' as list, 'params[2]' as name, 'occupant' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'number' as type, 'params[3]' as name, 'nb adultes' as placeholder)),
    xmlelement(name input, xmlattributes('number' as type, 'params[4]' as name, 'nb enfants' as placeholder)),
    xmlelement(name input, xmlattributes('number' as type, 'params[5]' as name, 'nb chevaux' as placeholder)),
    xmlelement(name label, 'Draps?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_draps' as name))),
    xmlelement(name label, 'Serviettes?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_serviette' as name))),
    xmlelement(name label, 'Ménage?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_cleaning' as name))),
    xmlelement(name input, xmlattributes('number' as type, 'params[6]' as name, 'Prix repas' as placeholder, 'any' as step)),
    xmlelement(name input, xmlattributes('number' as type, 'params[7]' as name, 'Prix forfait' as placeholder, 'required' as required, 'any' as step)),
    xmlelement(name label, 'Pension complete?', xmlelement(name input, xmlattributes('checkbox' as type, 'is_pension_complete' as name))),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[8]' as name, 'from' as placeholder)),
    xmlelement(name input, xmlattributes('required' as required, 'date' as type, 'params[9]' as name, 'to' as placeholder)),
    xmlelement(name input, xmlattributes('submit' as type))
)
union all select xmlelement(name nav,
    xmlelement(name a, xmlattributes(
        url.url('/grandroc/query', jsonb_build_object(
            'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
            'when', to_char(coalesce(when_, now()::date) - interval '1 month', 'MM-YY')
        )) as href
    ), 'prev'),
    xmltext(to_char(coalesce(when_, now()::date), 'Mon/YY')),
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

create or replace view contract_html (body, booking_id)
with (security_invoker) as
with httpg (error) as (
  select
    nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
),
booking_calc (booking_id, price, total_cleaning, total_taxe_sejour, total_food, total_horses, total, acompte) as (
    with calc (booking_id, price, total_cleaning, total_taxe_sejour, total_food, total_horses) as (
        select booking_id, price,
            case when with_cleaning then cleaning_price else 0 end,
            nb_adults * taxe_sejour,
            case when food_price_unit > 0 then (nb_adults + nb_children) * food_price_unit else 0 end,
            case when nb_horses > 0 then days(period) * nb_horses * 5 else 0 end
        from booking
        join place using (place)
    ),
    total as (
        select *, price + total_cleaning + total_food + total_horses + total_taxe_sejour total
        from calc
    )
    select booking_id, price, total_cleaning, total_taxe_sejour, total_food, total_horses,
        -- round(total + (0.3 * total) - round(0.3 * total, 0), 2),
        total,
        round(round(0.3 * total, 0), 2) acompte
    from total
)
select '<!DOCTYPE html>' ||
xmlelement(name html, xmlattributes(
  'fr' as "lang"
), 
  xmlelement(name head, 
    xmlelement(name meta, xmlattributes(
      'UTF-8' as "charset"
    )), 
    xmlelement(name meta, xmlattributes(
      'viewport' as "name"
,
      'width=device-width, initial-scale=1' as "content"
    )), 
    xmlelement(name title, 
      xmltext(format('Contrat de location – %s du Grand Roc', place))), 
    xmlelement(name style, 
      xmltext('
  @page {
    size: A4;
    margin: 15mm;
  }

    pre {
        margin: 0;
    }

    pre.cgv {
      text-wrap: wrap;
      break-before: page;
    }

  * {
    box-sizing: border-box;
  }

  body {
    margin: 0;
    font-family: Arial, Helvetica, sans-serif;
    color: #30372f;
    background: #f4f3ee;
    font-size: 11px;
    line-height: 1.5;
  }

  .page {
    width: 210mm;
    min-height: 297mm;
    margin: 0 auto;
    padding: 0 15mm;
    background: #ffffff;
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 3px solid #89977a;
  }

  .brand {
    color: #536447;
    font-size: 25px;
    font-weight: bold;
    letter-spacing: 2px;
  }

  .brand-subtitle {
    color: #777b70;
    font-size: 10px;
    margin-top: 0;
  }

  .contract-title {
    text-align: right;
  }

  .contract-title h1 {
    font-size: 18px;
    margin: 0;
    color: #30372f;
  }

  .contract-title p {
    margin: 0 0 0;
    color: #777b70;
  }

  .eyebrow {
    text-transform: uppercase;
    letter-spacing: 1.3px;
    color: #68775b;
    font-weight: bold;
    font-size: 10px;
    margin-bottom: 0;
  }

  .intro {
    margin-bottom: 0;
  }

  .intro p {
    margin: 0 0;
  }

  .info-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-bottom: 0;
  }

  .panel {
    background: #f5f5f0;
    border-left: 4px solid #89977a;
    padding: 12px 14px;
    border-radius: 3px;
  }

  .panel h2 {
    font-size: 11px;
    margin: 0;
    color: #536447;
    text-transform: uppercase;
    letter-spacing: 0.6px;
  }

  .panel p {
    margin: 0;
  }

  .client-name {
    font-size: 14px;
    font-weight: bold;
    margin-bottom: 0;
  }

  .section-title {
    font-size: 13px;
    color: #536447;
    border-bottom: 1px solid #d9ded3;
    padding-bottom: 6px;
    margin: 0;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0;
  }

  thead {
    background: #536447;
    color: #ffffff;
  }

  th {
    padding: 9px 8px;
    text-align: left;
    font-size: 10px;
    font-weight: bold;
  }

  td {
    padding: 8px;
    border-bottom: 1px solid #e6e8e2;
    vertical-align: top;
  }

  tbody tr:nth-child(even) {
    background: #f8f8f5;
  }

  .center {
    text-align: center;
  }

  .right {
    text-align: right;
    white-space: nowrap;
  }

  .payment {
    width: 62%;
    margin-left: auto;
    background: #f5f5f0;
    padding: 0 15px;
    border-radius: 3px;
  }

  .payment-row {
    display: flex;
    justify-content: space-between;
    gap: 15px;
    padding: 5px 0;
    border-bottom: 1px solid #dfe2d9;
  }

  .payment-row:last-child {
    border-bottom: none;
  }

  .payment-total {
    color: #536447;
    font-size: 15px;
    font-weight: bold;
    border-bottom: 2px solid #89977a;
  }

  .deposit {
    margin: 5px 0;
    padding: 10px 13px;
    border: 1px solid #d8c9a7;
    background: #fbf8ef;
    border-radius: 3px;
  }

  .deposit strong {
    color: #66552f;
  }

  .practical {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin: 0;
  }

  .practical div {
    padding: 10px 12px;
    border: 1px solid #e1e4dc;
    border-radius: 3px;
  }

  .practical strong {
    color: #536447;
    display: block;
    margin-bottom: 0;
  }

  .conditions {
    font-size: 10px;
    color: #555b52;
  }

  .conditions p {
    margin: 0;
  }

  .signatures {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
    margin-top: 0;
  }

  .signature-box {
    border: 1px solid #dfe2d9;
    padding: 12px;
    min-height: 85px;
  }

  .signature-box strong {
    color: #536447;
  }

  .signature-space {
    height: 35px;
  }

  .footer {
    border-top: 1px solid #d9ded3;
    margin-top: 20px;
    padding-top: 8px;
    text-align: center;
    font-size: 9px;
    color: #777b70;
  }

  @media print {
    body {
      background: #ffffff;
    }

    .page {
      width: auto;
      min-height: auto;
      margin: 0;
      padding: 0;
    }

    .panel, .payment, .deposit, .practical div {
      print-color-adjust: exact;
      -webkit-print-color-adjust: exact;
    }
  }
'))), 
  xmlelement(name body, 
    xmlelement(name main, xmlattributes(
      'page' as "class"
    ), 
      xmlelement(name header, xmlattributes(
        'header' as "class"
      ), 
        xmlelement(name div, 
          xmlelement(name div, xmlattributes(
            'brand' as "class"
          ), 
            xmltext('LE GRAND ROC')), 
          xmlelement(name div, xmlattributes(
            'brand-subtitle' as "class"
          ), 
            xmltext('Gîtes • Camping • Logements insolites'))
        ), 
        xmlelement(name div, xmlattributes(
          'contract-title' as "class"
        ), 
          xmlelement(name h1, 
            xmltext('CONTRAT DE LOCATION')), 
          xmlelement(name p, 
            xmltext(place)), 
          xmlelement(name p, 
            xmltext('Ferrières-sur-Sichon'))
          )
        ), 
      xmlelement(name section, xmlattributes(
        'intro' as "class"
      ), 
        xmlelement(name div, xmlattributes(
          'eyebrow' as "class"
        ), 
          xmltext('Votre séjour au Grand Roc')), 
        xmlelement(name p, 
          xmltext('Nous vous remercions d''avoir choisi notre hébergement.')), 
        xmlelement(name p, 
          xmltext('Vous trouverez ci-dessous le récapitulatif de votre réservation et des prestations retenues.'))
        ), 
      xmlelement(name section, xmlattributes(
        'info-grid' as "class"
      ), 
        xmlelement(name div, xmlattributes(
          'panel' as "class"
        ), 
          xmlelement(name h2, 
            xmltext('Informations du locataire')), 
          xmlelement(name p, xmlattributes(
            'client-name' as "class"
          ), 
            xmltext(occupant)), 
          xmlelement(name pre, 
            xmltext(address)), 
          xmlelement(name p, 
            xmltext(format('Téléphone: %s', tel))), 
          xmlelement(name p, 
            xmltext(format('E-mail: %s', email)))
        ), 
        xmlelement(name div, xmlattributes(
          'panel' as "class"
        ), 
          xmlelement(name h2, 
            xmltext('Dates du séjour')), 
          xmlelement(name p, 
            xmlelement(name strong, 
              xmltext(format('du %s au %s',
                to_char(lower(period), 'DD/MM/YYYY'),
                to_char(upper(period), 'DD/MM/YYYY')
          )))), 
          xmlelement(name p, 
            xmlelement(name strong, 
              xmltext('Durée: ')), 
            xmltext(format(' %s nuitée(s)', days(period)))), 
          xmlelement(name p, 
            xmlelement(name strong, 
              xmltext('Adultes: ')), 
            xmltext(nb_adults::text)), 
          xmlelement(name p, 
            xmlelement(name strong, 
              xmltext('Enfants: ')), 
            xmltext(nb_children::text)), 
          xmlelement(name p, 
            xmlelement(name strong, 
              xmltext('Date du contrat: ')), 
            xmltext(to_char(at, 'DD/MM/YYYY'))) 
        )), 
      xmlelement(name h2, xmlattributes(
        'section-title' as "class"
      ), 
        xmltext('Détail des prestations')), 
      xmlelement(name table, 
        xmlelement(name thead, 
          xmlelement(name tr, 
            xmlelement(name th, xmlattributes(
              'width: 43%' as "style"
            ), 
              xmltext('Prestation')), 
            xmlelement(name th, xmlattributes(
              'center' as "class"
,
              'width: 17%' as "style"
            ), 
              xmltext('Quantité')), 
            xmlelement(name th, xmlattributes(
              'right' as "class"
,
              'width: 20%' as "style"
            ), 
              xmltext('Prix unitaire')), 
            xmlelement(name th, xmlattributes(
              'right' as "class"
,
              'width: 20%' as "style"
            ), 
              xmltext('Total'))
        )), 
        xmlelement(name tbody, 
          xmlelement(name tr, 
            xmlelement(name td, 
              xmltext('Location du Grand Gîte')), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), 
              xmltext(format('%s nuit(s)', days(period)))), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext('—')), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(booking_calc.price::text))
            ), 
          case when with_cleaning then xmlelement(name tr, 
            xmlelement(name td, 
              xmltext('Forfait ménage')), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), 
              xmltext(1::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(place.cleaning_price::text)),
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(place.cleaning_price::text)) 
          ) end, 
          case when nb_horses > 0 then xmlelement(name tr, 
            xmlelement(name td, 
              xmltext('Pension cheval')), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), 
              xmltext(nb_horses::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(5::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(total_horses::text))
          ) end, 
          xmlelement(name tr, 
            xmlelement(name td, 
              xmltext('Taxe de séjour')), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), 
              xmltext(nb_adults::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(taxe_sejour::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(total_taxe_sejour::text))), 
          case when food_price_unit > 0 then xmlelement(name tr, 
            xmlelement(name td, 
              xmltext(case when is_pension_complete then 'Pension complète' else 'Demi-pension' end)), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), 
              xmltext((nb_adults + nb_children)::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(food_price_unit::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(total_food::text))
          ) end
          -- xmlelement(name tr, 
          --   xmlelement(name td, 
          --     xmltext('Arrivée anticipée')), 
          --   xmlelement(name td, xmlattributes(
          --     'center' as "class"
          --   ), 
          --     xmltext('{{ARRIVEE_ANTICIPEE}}')), 
          --   xmlelement(name td, xmlattributes(
          --     'right' as "class"
          --   ), 
          --     xmltext('{{PRIX_ARRIVEE_ANTICIPEE}}')), 
          --   xmlelement(name td, xmlattributes(
          --     'right' as "class"
          --   ), 
          --     xmltext('{{TOTAL_ARRIVEE_ANTICIPEE}}'))), 
          -- xmlelement(name tr, 
          --   xmlelement(name td, 
          --     xmltext('Départ tardif')), 
          --   xmlelement(name td, xmlattributes(
          --     'center' as "class"
          --   ), 
          --     xmltext('{{DEPART_TARDIF}}')), 
          --   xmlelement(name td, xmlattributes(
          --     'right' as "class"
          --   ), 
          --     xmltext('{{PRIX_DEPART_TARDIF}}')), 
          --   xmlelement(name td, xmlattributes(
          --     'right' as "class"
          --   ), 
          --     xmltext('{{TOTAL_DEPART_TARDIF}}'))) 
        )),
      xmlelement(name section, xmlattributes(
        'payment' as "class"
      ), 
        xmlelement(name div, xmlattributes(
          'payment-row payment-total' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Total du séjour')), 
          xmlelement(name span, 
            xmltext(total::text))),
        xmlelement(name div, xmlattributes(
          'payment-row' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Acompte de 30 %')), 
          xmlelement(name strong, 
            xmltext(acompte::text))), 
        xmlelement(name div, xmlattributes(
          'payment-row' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Solde restant à régler')), 
          xmlelement(name strong, 
            xmltext((total - acompte)::text))), 
        xmlelement(name div, xmlattributes(
          'payment-row' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Date limite de versement de l''acompte')), 
          xmlelement(name strong, 
            xmltext(to_char(at + interval '14 days', 'DD/MM/YYYY'))))), 
      xmlelement(name section, xmlattributes(
        'deposit' as "class"
      ), 
        xmlelement(name strong, 
          xmltext('Dépôt de garantie: 1 000 €')), 
        xmlelement(name p, 
          xmltext('Le dépôt de garantie est distinct du montant total du séjour et n''est pas inclus dans le calcul ci-dessus.'))), 
      xmlelement(name h2, xmlattributes(
        'section-title' as "class"
      ), 
        xmltext('Informations pratiques')), 
      xmlelement(name section, xmlattributes(
        'practical' as "class"
      ), 
        xmlelement(name div, 
          xmlelement(name strong, 
            xmltext('Arrivée')), 
          xmltext('
      À partir de 17 h et jusqu''à 20 h, sauf accord préalable.
    ')), 
        xmlelement(name div, 
          xmlelement(name strong, 
            xmltext('Départ')), 
          xmltext('
      Avant 10 h, sauf accord préalable.
    '))), 
      xmlelement(name h2, xmlattributes(
        'section-title' as "class"
      ), 
        xmltext('Conditions du séjour')), 
      xmlelement(name section, xmlattributes(
        'conditions' as "class"
      ), 
        xmlelement(name p, 
          xmltext('Le locataire reconnaît avoir pris connaissance des conditions de location applicables au séjour.')), 
        xmlelement(name p, 
          xmltext('Le locataire s''engage à respecter les lieux, les équipements et le voisinage, et à restituer l''hébergement dans les conditions prévues au contrat.')), 
        xmlelement(name p, 
          xmltext('Le présent document récapitule la réservation, les prestations sélectionnées et les montants associés. Les autres conditions contractuelles doivent être conservées dans la version définitive du contrat.'))), 
      xmlelement(name section, xmlattributes(
        'signatures' as "class"
      ), 
        xmlelement(name div, xmlattributes(
          'signature-box' as "class"
        ), 
          xmlelement(name strong, 
            xmltext('Le locataire')), 
          xmlelement(name p, 
            xmltext('Lu et approuvé')), 
          xmlelement(name div, xmlattributes(
            'signature-space' as "class"
          ), ''), 
          xmlelement(name p, 
            xmltext('Signature: '))), 
        xmlelement(name div, xmlattributes(
          'signature-box' as "class"
        ), 
          xmlelement(name strong, 
            xmltext('Le Grand Roc')), 
          xmlelement(name p, 
            xmltext('Bon pour accord')), 
          xmlelement(name div, xmlattributes(
            'signature-space' as "class"
          ), ''), 
          xmlelement(name p, 
            xmltext('Signature: ')))), 
      xmlelement(name footer, xmlattributes(
        'footer' as "class"
      ), 
        xmltext('
    LE GRAND ROC • Lieu-dit Mounier Haut • 03250 Ferrières-sur-Sichon'), 
        xmlelement(name br), 
        xmltext('
    06 87 49 68 60 • contact@legrandroc.com • www.legrandroc.com
  ')),
    xmlelement(name pre, xmlattributes('cgv' as class), $$
Gîte Le Grand Roc


Type :	Gîte de groupe

Localisation :	FERRIERES SUR SICHON – Lieudit Mounier Haut

Coordonnées GPS :
Longitude : 3,67019534 - Latitude : 46,02882269

Altitude :	750 m
Capacite :	15 personnes 
Surface :	270 m²
Etage :	1

Description :
A pied, à cheval ou en vélo, venez découvrir la Montagne Bourbonnaise (Allier) !
Dans une ambiance « vacances à la ferme », situé à 750m d’altitude et directement sur les chemins de randonnées, le
 gîte « Le Grand Roc » peut accueillir jusqu’à 15 personnes.
Profitez pleinement d'une magnifique vue dominante et d'un ensoleillement du matin au soir, avec pour seul bruit, le chant des oiseaux...
Nous nous sommes installés en Montagne Bourbonnaise en 2013. En cet endroit idyllique, nous aimons faire découvrir à tous les amoureux de la randonnée, de la nature, et des richesses historiques, les nombreux attraits de cette si belle région. 
Caractéristiques :
Infrastructures : Piscine partagée (Piscine hors sol en juillet et aout), Aire de jeux, terrain de pétanque (à la belle saison).
Langues : Anglais parlé
Loisirs à proximité : Randonnée, VTT, Equestre (Accueil cheval)
Commodités : Barbecue
Spécificités : Gîte et accueil cheval, Accueil groupes



Contrat de location de vacances
Conditions applicables à toutes les réservations en ligne d’un séjour

Les parties au contrat :
« Le preneur » désigne tout utilisateur du présent site qui réserve un séjour dans le meublé de tourisme*** dénommé « grand gîte Le Grand Roc ». Vous ne pouvez utiliser ce site que si vous êtes majeur et habilité à signer des contrats qui engagent votre responsabilité. Vous serez financièrement responsable de toutes vos utilisations du site.
Les prestations vendues sur le présent site sont réservées aux particuliers. Les groupements et professionnels doivent prendre contact directement avec le Bailleur.

« Le Bailleur » nous désigne en tant que propriétaire du meublé de tourisme*** dénommé « grand gîte Le Grand Roc », offrant à la vente les locations et séjours dans le dit meublé de tourisme.

Objet du contrat : Le présent contrat a pour objet d’assurer à distance par voie électronique la réservation d’un séjour en hébergement dans le meublé de tourisme***
«Le Grand Roc », classé 3* par l’UDOTSI Allier en date du 12 mai 2025.
Les parties conviennent que la location faisant l'objet des présentes est une location saisonnière, dont la durée ne peut excéder 90 jours.
Le Bailleur déclare être propriétaire du logement et en avoir la libre disposition et la pleine jouissance durant la période de location définie dans les présentes.
Le Bailleur pourra justifier de la propriété de son bien en fournissant les justificatifs demandés par le Preneur.

Prise d’option en ligne : Le présent site permet de poser une option sur la réservation d’un séjour en hébergement dont la durée de validité est mentionnée sur la proposition de contrat émise par le Bailleur. En posant une option, vous bloquez la réservation du séjour pour un délai de 14 jours. Vous recevrez alors un contrat de réservation électronique. Attention : le Bailleur devra avoir reçu, avant la date figurant sur le contrat, votre contrat signé ainsi que votre paiement de l'acompte pour que votre réservation devienne définitive. A défaut, votre option de réservation sera considérée comme non confirmée et le Bailleur remettra en vente le séjour concerné.

La réservation du gîte ne s’effectue pas en ligne.
Le Preneur prend contact avec le Bailleur soit par téléphone, soit via le formulaire de contact du site internet.
  À la suite de cet échange, le Bailleur adresse au Preneur, par courrier électronique, un dossier de réservation comprenant :
  le contrat de location, le livret d’accueil, les coordonnées bancaires (RIB) du Bailleur.
  La réservation devient effective uniquement à réception, par le Bailleur, du contrat de location dûment signé par le Preneur et du versement de l’acompte correspondant, dans un délai maximum de deux (2) semaines suivant l’envoi du dossier de réservation.
  À défaut de réception du contrat signé et de l’acompte dans ce délai, le Bailleur se réserve le droit de considérer la demande comme annulée et de remettre le logement à la location sans que le Preneur ne puisse se prévaloir d’un quelconque droit ou recours.
La confirmation de la réservation est adressée au Preneur par courrier électronique. Cette confirmation vaut preuve de la conclusion du contrat de location, de l’accord du Preneur sur ses conditions, ainsi que de la date de réservation.

Les moyens de paiement du prix de la location : Le paiement en ligne par virement vous permet de réserver votre séjour en ligne et immédiatement de manière ferme. Si le délai entre la date de réservation et la date de début du séjour est inférieur à 14 jours, seul le paiement par virement vous est proposé, sans possibilité de prendre une option.
Pour les prises d’option, le paiement de l'acompte peut intervenir par chèque ou virement ; outre ces moyens de paiement, le règlement du solde du loyer peut également se faire en espèces ou par chèques vacances.

Cession et sous-location : Le présent contrat de location saisonnière est conclu au profit du seul Preneur signataire des présentes. La cession du bail, sous-location totale ou partielle, sont rigoureusement interdites.

Capacité d’hébergement : Le contrat est établi pour une capacité maximale de 15 personnes. Le Preneur s’engage expressément à ne pas dépasser ce nombre sans autorisation du Bailleur. Si le nombre de vacanciers dépasse la capacité d'accueil, le Bailleur peut refuser les clients supplémentaires. Dans ce cas, toute modification ou rupture du contrat sera considérée à l’initiative du Preneur.

Animaux de compagnie : La présence d’animaux de compagnie dans l’hébergement n’est pas autorisée ; le contrat pourra être résilié aux torts du Preneur en cas de non-respect de ces conditions de séjour.

Les prix : Les prix sont indiqués dans chaque descriptif et correspondent au coût global de la location du gîte pour la période choisie.

Les dates de perception du prix du séjour : La réservation devient effective dès lors que le Preneur a retourné au

Bailleur -avant la date indiquée sur le contrat- un exemplaire du présent contrat accompagné du paiement de l'acompte de 30% du coût total du séjour. Le solde du coût total du séjour devra être versé le jour de l'arrivée.

Absence de rétractation : Pour les réservations effectuées par courrier ou par téléphone, le Preneur ne bénéficie pas du délai de rétractation, et ce conformément à l’article L121-21-8 du code de la consommation relatif notamment aux prestations de services d’hébergement fournies à une date ou selon une périodicité déterminée

Remise des clés : Le Bailleur et le Preneur définissent les modalités de remise des clés suivantes : Remise des clès au Preneur à l’arrivée : sur place
Remise des clés au Bailleur au départ : sur place

L’arrivée : Le Preneur doit se présenter le jour précisé et aux heures mentionnées sur le contrat de réservation ou sur l’accusé de réception de la réservation. En cas d'arrivée tardive ou différée ou d'empêchement de dernière minute, le Preneur doit prévenir le Bailleur.

L’état des lieux réalisé sans la présence du Bailleur : Un état des lieux sera mis à disposition du Preneur qui aura alors 48 heures pour faire des contestations éventuelles, par écrit, remises au Bailleur. A défaut de contestation par le Preneur dans un délai de 48 heures, l'état des lieux établi par le Bailleur sera réputé accepté par le Preneur. Cet état des lieux constitue la seule référence en cas de litige. L'état de propreté du gîte à l'arrivée du Preneur devra être constaté dans l'état des lieux. Le nettoyage des locaux est à la charge du vacancier pendant la période de location (ou par le bailleur si le forfait ménage a été demandé) et avant son départ, le Preneur s'engage à rendre la location aussi propre qu'il l'aura trouvée à son arrivée. 
Le Preneur établira seul l'état des lieux de sortie et le transmettra le jour de sortie au Bailleur. Le Bailleur pourra contester l'état des lieux dans un délai courant jusqu'à l'arrivée du prochain locataire, dans une limite de 48 heures.

Le dépôt de garantie : Au plus tard lors de l’entrée dans les lieux, le Preneur remettra au Bailleur un chèque d'un montant de 1000.00 Euros (mille euros) à l'ordre du Bailleur à titre de dépôt de garantie destiné à couvrir les éventuels dommages locatifs. Sont compris comme dommages locatifs, tous dommages, dégradations du logement, ainsi que les dommages, pertes ou vols causés aux biens mobiliers garnissant l'hébergement, pendant la période de location. En l'absence de dommages locatifs le dépôt de garantie sera restitué au Preneur dans un délai maximum de 15 jours après son départ. Dans le cas de l'existence de dommages locatifs, le dépôt de garantie sera reversé dans un délai maximal de 2 mois, les dépenses effectuées en réparation du préjudice subi déduites, justification et factures à l'appui.

Annulation : Toute résiliation du présent contrat doit être adressée par courrier recommandé avec accusé de réception, la date de réception faisant foi.
Résiliation à l'initiative du Preneur : En cas d'annulation par le Preneur avant l'arrivée dans les lieux, l'acompte reste acquis au Bailleur. Celui-ci peut lui demander en outre le solde du montant du séjour, si l'annulation intervient moins de 30 jours avant la date prévue d'entrée dans les lieux.
Si le Preneur ne se manifeste pas dans les 24 heures qui suivent la date d'arrivée indiquée sur le contrat, le présent contrat est annulé et le propriétaire peut disposer de sa location. L'acompte reste également acquis au Bailleur qui peut demander le paiement du solde de la location.
Résiliation à l'initiative du Bailleur : En cas d'annulation par le Bailleur, celui-ci reverse au Preneur l'intégralité des sommes versées. 
Résiliation en cours de contrat : Lorsque la résiliation du contrat par le Bailleur intervient pendant la durée de location, elle doit être dûment justifiée (défaut de paiement de loyer, chèque sans provision émis par le locataire, détérioration avérée des lieux loués, plaintes du voisinage, manquement par le Preneur à l’une de ses obligations contractuelles...). Cette résiliation, qui intervient par courrier recommandé avec accusé de réception ou lettre remise en main propre, entraîne le départ du locataire dans les 48 heures de la date de réception du courrier lui notifiant cette décision, et le présent bail est résilié de plein droit. Dans ce cas, quelle que soit la cause de résiliation, l'intégralité du montant du loyer demeure acquise au Bailleur. Le Bailleur se réserve le droit de conserver le montant du dépôt de garantie dans les conditions précisées au paragraphe "le dépôt de garantie".

Interruption du séjour : En cas d'interruption du séjour par le Preneur, il ne sera procédé à aucun remboursement.

Modification d’un élément substantiel : Lorsqu'avant la date prévue du début du séjour le Bailleur se trouve contraint d'apporter une modification à l'un des éléments essentiels du contrat, le Preneur peut, et après en avoir été informé par le Bailleur par lettre recommandée avec accusé de réception :
soit résilier son contrat et obtenir sans pénalités le remboursement immédiat des sommes versées ;
soit accepter la modification ou la substitution de lieux de séjours proposée par le Bailleur : un avenant au contrat précisant les modifications apportées est alors signé par les parties. Toute diminution de prix vient en déduction des sommes restant éventuellement dues par le Preneur et si le paiement déjà effectué par ce dernier excède le prix de la prestation modifiée, le trop-perçu sera restitué au Preneur avant le début de son séjour.

Empêchement pour le Bailleur de fournir en cours de séjour les prestations prévues dans le contrat : Lorsqu'en cours de séjour, le Bailleur se trouve dans l'impossibilité de fournir une part prépondérante des services prévus au contrat ne relevant pas de faits directement causés par le Preneur, et représentant un pourcentage non négligeable du prix honoré par le Preneur, le Bailleur proposera un autre hébergement en remplacement, tout en supportant éventuellement un

supplément de prix. Si le séjour de remplacement accepté par le Preneur est de qualité inférieure, le Bailleur lui remboursera la différence de prix avant la fin de son séjour. Si le Bailleur ne peut lui proposer de séjour de remplacement ou si celui-ci est refusé par le Preneur pour des motifs valables, le Bailleur réglera au Preneur une somme correspondant au montant du loyer calculé au prorata du nombre de jours restant à courir jusqu’au terme initial du séjour.

Responsabilité du Preneur : Il vous appartient de vérifier que les informations que vous fournissez lors de votre inscription, ou à tout autre moment, sont exactes et complètes. Il est de votre responsabilité de vous assurer que les coordonnées que vous communiquez lors de votre réservation sont correctes et qu’elles vous permettront de recevoir la confirmation de votre réservation. Dans l’hypothèse où vous ne recevriez pas cette confirmation, il vous incombe de contacter le Bailleur. Pour le bon suivi de votre dossier, vous devez informer immédiatement le Bailleur de toute modification des informations fournies lors de votre inscription.

Obligations du Preneur : Le Preneur fera un usage paisible du logement loué. Il entretiendra le logement loué et le rendra en bon état de propreté. Il devra respecter le voisinage. Il s'engage à faire un usage normal et raisonnable des moyens de confort (chauffage, eau, etc.), ainsi que des équipements (électroménager, multimédia, cuisine, etc.) mis à sa disposition. Il s'engage à informer le Bailleur dans les meilleurs délais de toute panne, dommage, incidents, ou dysfonctionnement. Il lui est interdit de faire une copie des clés remises par le Bailleur.
Le Preneur est responsable de l'utilisation de l'accès internet mis à sa disposition au cours de la période de location. Le Bailleur ne pourrait pas être tenu responsable si l’accès à Internet ne fonctionnait pas, pour quelque raison que ce soit.

Obligations du Bailleur : Le Bailleur s'engage à maintenir la location faisant l'objet du présent contrat dans un état satisfaisant d'entretien, de propreté et de sécurité. Il s'engage à signaler dans les meilleurs délais au Preneur toute modification indépendante de sa volonté de nature à modifier le confort ou troubler la jouissance du bien loué (nuisance, panne d'un équipement, etc.). Dans le cas où un appareil ou matériel ayant une influence majeure sur le confort du Preneur, venait à être défaillant, le Bailleur s'engage à mettre en œuvre les moyens permettant la réparation ou le remplacement dans les meilleurs délais. Le Bailleur ne peut être tenu pour responsable des cas fortuits, des cas de force majeure ou du fait de toute personne étrangère à l'organisation et au déroulement du séjour.
Le Bailleur devra s'assurer que le Preneur bénéficie d'une jouissance pleine et entière du bien loué, sur la période. Il veillera à la remise des clés. Il s'abstiendra de perturber le confort ou la tranquillité du Preneur pendant la durée du séjour.

Preuve : Il est expressément convenu que, sauf erreur manifeste commise par le Bailleur, les données conservées dans le système d'information du Bailleur ont force probante quant aux commandes passées. Les données sur support informatique ou électronique conservées par le Bailleur constituent des preuves. Si elles sont produites comme moyens de preuve par le Bailleur dans toute procédure contentieuse ou autre, elles seront recevables, valables et opposables entre les parties de la même manière, dans les mêmes conditions et avec la même force probante que tout document qui serait établi, reçu ou conservé par écrit.

Les assurances : Le Preneur est responsable de tous les dommages survenant de son fait. Il est tenu d’être assuré par un contrat d’assurance type villégiature pour ces différents risques.
Une attestation d’assurance pourra lui être réclamée à l’entrée dans les lieux ou à défaut une attestation sur l’honneur.

Protection des données personnelles : Les données nominatives vous concernant font l’objet d’un traitement informatique. Vous êtes susceptibles de recevoir des offres commerciales de la part du Bailleur. Conformément à la loi « Informatique et Libertés » du 06/01/78 modifiée en 2004, vous bénéficiez d’un droit d’accès et de rectification aux informations vous concernant. Si vous souhaitez exercer ce droit, il vous suffit soit de nous écrire, soit d’en faire la demande par courrier électronique. Les données saisies sur les formulaires présents sur le présent site demeurent confidentielles au Bailleur.

27. Domicile : Pour l’exécution des présentes, le Bailleur et le Preneur font élection de domicile dans leurs domiciles respectifs, indiqués sur le contrat de location. Toutefois, en cas de litige, le tribunal du domicile du Bailleur sera seul compétent. Le présent contrat est soumis à la loi française.

    $$))
    )
)
::text, booking_id
from booking_calc
join booking using (booking_id)
join occupant using (occupant)
join place using (place)
;

-- truncate table occupant cascade;
-- insert into occupant (occupant) values ('georges');


-- truncate table booking;
-- insert into booking (place, occupant, price, period, with_cleaning, nb_adults, nb_children, nb_horses, food_price_unit)
-- select
--     (array_sample(array['grand gite'], 1))[1],
--     (array_sample(array['georges'], 1))[1],
--     900,
--     tstzrange(i, i + format('%s days', random(1, 4))::interval, '[)'),
--     true,
--     4,
--     2,
--     2,
--     20
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

grant usage on schema grandroc, url to anon, grandroc;
grant select on table head to anon, grandroc;
grant select, insert, update, delete on table booking to grandroc;
grant select, insert, update, delete on table occupant to grandroc;
grant select, insert, update, delete on table place to grandroc;
grant select on table occupant_html to grandroc;
grant select on table place_html to grandroc;
grant select on table booking_html to grandroc;
grant select on table contract_html to grandroc;
grant execute on function days to grandroc;
grant execute on function url.url to anon, grandroc;
grant execute on function url.encode to anon, grandroc;
grant execute on procedure book to grandroc;


