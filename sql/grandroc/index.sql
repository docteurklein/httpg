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
    taxe_sejour amount not null,
    cleaning_price amount not null,
    cgv text not null
);

insert into place (place, taxe_sejour, cleaning_price, cgv)
values ('grand gite', 1.25, 20, 'bla bla')
on conflict (place) do nothing;

-- drop table if exists booking cascade;
create table if not exists booking (
    booking_id uuid primary key default uuidv7(),
    place text not null references place (place) on delete cascade,
    occupant text not null references occupant (occupant) on delete cascade,
    period daterange not null,
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
    color text not null default (array_sample(array[
        'antiquewhite',
        'aqua',
        'aquamarine',
        'azure',
        'beige',
        'bisque',
        'black',
        'blanchedalmond',
        'blue',
        'blueviolet',
        'brown',
        'burlywood',
        'cadetblue',
        'chartreuse',
        'chocolate',
        'coral',
        'cornflowerblue',
        'cornsilk',
        'crimson',
        'cyan',
        'darkblue',
        'darkcyan',
        'darkgoldenrod',
        'darkgray',
        'darkgreen',
        'darkkhaki',
        'darkmagenta',
        'darkolivegreen',
        'darkorange',
        'darkorchid',
        'darkred',
        'darksalmon',
        'darkseagreen',
        'darkslateblue',
        'darkslategray',
        'darkturquoise',
        'darkviolet',
        'deeppink',
        'deepskyblue',
        'dimgray',
        'dodgerblue',
        'firebrick',
        'floralwhite',
        'forestgreen',
        'fuchsia',
        'gainsboro',
        'ghostwhite',
        'gold',
        'goldenrod',
        'gray',
        'green',
        'greenyellow',
        'honeydew',
        'hotpink',
        'indianred',
        'indigo',
        'ivory',
        'khaki',
        'lavender',
        'lavenderblush',
        'lawngreen',
        'lemonchiffon',
        'lightblue',
        'lightcoral',
        'lightcyan',
        'lightgoldenrodyellow',
        'lightgray',
        'lightgreen',
        'lightpink',
        'lightsalmon',
        'lightseagreen',
        'lightskyblue',
        'lightslategray',
        'lightsteelblue',
        'lightyellow',
        'lime',
        'limegreen',
        'linen',
        'magenta',
        'maroon',
        'mediumaquamarine',
        'mediumblue',
        'mediumorchid',
        'mediumpurple',
        'mediumseagreen',
        'mediumslateblue',
        'mediumspringgreen',
        'mediumturquoise',
        'mediumvioletred',
        'midnightblue',
        'mintcream',
        'mistyrose',
        'moccasin',
        'navajowhite',
        'navy',
        'oldlace',
        'olive',
        'olivedrab',
        'orange',
        'orangered',
        'orchid',
        'palegoldenrod',
        'palegreen',
        'paleturquoise',
        'palevioletred',
        'papayawhip',
        'peachpuff',
        'peru',
        'pink',
        'plum',
        'powderblue',
        'purple',
        'rebeccapurple',
        'red',
        'rosybrown',
        'royalblue',
        'saddlebrown',
        'salmon',
        'sandybrown',
        'seagreen',
        'seashell',
        'sienna',
        'silver',
        'skyblue',
        'slateblue',
        'slategray',
        'snow',
        'springgreen',
        'steelblue',
        'tan',
        'teal',
        'thistle',
        'tomato',
        'turquoise',
        'violet',
        'wheat',
        'yellow',
        'yellowgreen'
    ], 1))[1],
    exclude using gist (
        place with =,
        period with &&
    ) where (status = 'confirmed')
);

create or replace function days(period daterange) returns int
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
    union all select xmlelement(name script, xmlattributes('module' as type), $$
        document.body.addEventListener('mouseover', (e) => {
            if (!e.target.classList.contains('booking')) return;
            document.querySelectorAll(`[data-booking]`).forEach(n => n.classList.remove('active'));
            document.querySelectorAll(`[data-booking="${e.target.dataset.booking}"]`).forEach(n => n.classList.add('active'));
        });
    $$::text::xml)::text
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
    select xmlelement(name div, xmlattributes('flashes' as class),
        xmlelement(name article, xmlattributes('red card' as class), error)
    )::text
    from httpg
    where error is not null
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
        body->>'pension' = 'complete',
        price,
        daterange(from_, to_, '[]')
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
    with httpg (params) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'->'params'
    ),
    add (sql, action, occupant) as (
        select $$
            insert into grandroc.occupant (occupant, tel, email) values ($1, $2, $3)
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.occupant_html'
            ))) header;
        $$, 'Add', null::occupant
    ),
    edit (sql, action, occupant) as (
        select $$
            update grandroc.occupant set occupant = $1, tel = $2, email = $3
            where occupant = $4
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.occupant_html'
            ))) header;
        $$, 'Edit', o
        from occupant o
        order by occupant
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
            'grid' as class,
            'POST' as method,
            '/grandroc/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            sql as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'select * from grandroc.head union all select body::text from grandroc.occupant_html' as value
        )),
        xmlelement(name label, 'Nom', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, coalesce(params->>0, (occupant).occupant) as value))),
        xmlelement(name label, 'Tél', xmlelement(name input, xmlattributes('params[1]' as name, 'tel' as type, coalesce(params->>1, (occupant).tel) as value))),
        xmlelement(name label, 'email', xmlelement(name input, xmlattributes('params[2]' as name, 'email' as type, 'required' as required, coalesce(params->>2, (occupant).email) as value))),
        xmlelement(name input, xmlattributes('params[3]' as name, 'hidden' as type, (occupant).occupant as value)),
        xmlelement(name input, xmlattributes('submit' as type, action as value))
    ))
    from httpg, (table add union all table edit)
;

-- drop view if exists place_html;
create or replace view place_html (body)
with (security_invoker) as
    with httpg (params) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'->'params'
    ),
    add (sql, action, place) as (
        select $$
            insert into grandroc.place (place, taxe_sejour, cleaning_price, cgv)
            values ($1, nullif($2, '')::amount, nullif($3, '')::amount, $4)
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
            ))) header;
        $$, 'Add', null::place
    ),
    edit (sql, action, place) as (
        select $$
            update grandroc.place
                set place = $1, taxe_sejour = nullif($2, '')::amount, cleaning_price = nullif($3, '')::amount, cgv = $4
            where place = $5
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
            ))) header;
        $$, 'Edit', p
        from place p
        order by place
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
            'grid' as class,
            'POST' as method,
            '/grandroc/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            sql as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'select * from grandroc.head union all select body::text from grandroc.place_html' as value
        )),
        xmlelement(name label, 'Logement', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, coalesce(params->>0, (place).place) as value))),
        xmlelement(name label, 'Taxe de séjour', xmlelement(name input, xmlattributes('params[1]' as name, 'number' as type, 'required' as required, coalesce((params->>1), (place).taxe_sejour::text) as value))),
        xmlelement(name label, 'Prix ménage', xmlelement(name input, xmlattributes('params[2]' as name, 'number' as type, 'required' as required, coalesce(params->>2, (place).cleaning_price::text) as value))),
        xmlelement(name label, 'CGV', xmlelement(name textarea, xmlattributes('params[3]' as name, 5 as rows, 'required' as required), coalesce(params->>3, (place).cgv, ''))),
        xmlelement(name input, xmlattributes('params[4]' as name, 'hidden' as type, (place).place as value)),
        xmlelement(name input, xmlattributes('submit' as type, action as value)
    )))
    from httpg, (table add union all table edit)
;

create or replace view booking_html (body)
with (security_invoker) as
with httpg (when_) as (
    select to_date(nullif(current_setting('httpg.query', true), '')::jsonb->'qs'->>'when', 'MM-YY')
),
day (d) as (
    select d::date from httpg, generate_series(
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
        coalesce(xmlagg(case when place is not null then
            xmlelement(name section, xmlattributes(
                format('booking %s',  case when lower(period)::date <> d then 'line' end) as class,
                
                format('--color: %s;', color) as style,
                booking_id as "data-booking"
            ),
                xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select body::text from grandroc.contract_html where booking_id = $1::uuid',
                        'params[0]', booking_id
                    )) as href
                ), format('%s in %s', occupant ,place)),
                xmlelement(name form, xmlattributes(
                    'POST' as method,
                    '/grandroc/query' as action,
                    'inline' as class
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
                )
            )
            end
        order by period asc, place)
    ), '')
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
    xmlelement(name label, 'Demi-pension?', xmlelement(name input, xmlattributes('radio' as type, 'pension' as name, 'demi' as value))),
    xmlelement(name label, 'Pension Complete?', xmlelement(name input, xmlattributes('radio' as type, 'pension' as name, 'complete' as value))),
    xmlelement(name input, xmlattributes('number' as type, 'params[7]' as name, 'Prix forfait' as placeholder, 'required' as required, 'any' as step)),
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

    & p {
        margin: 0;
    }
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
    & p {
        margin: 0;
    }
    min-height: 75px;
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
          case when nb_children > 0 then xmlelement(name p, 
            xmlelement(name strong, 
              xmltext('Enfants: ')), 
            xmltext(nb_children::text)) end, 
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
              xmltext(round(5, 2)::text)), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), 
              xmltext(round(total_horses, 2)::text))
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
            xmltext('Signature suivie de la mention "Lu et approuvé" :'))
          ), 
        xmlelement(name div, xmlattributes(
          'signature-box' as "class"
        ), 
          xmlelement(name strong, 
            xmltext('Le Grand Roc')), 
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
    xmlelement(name pre, xmlattributes('cgv' as class), cgv))
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
--     daterange(i::date, (i + format('%s days', random(2, 8))::interval)::date, '[)'),
--     true,
--     4,
--     2,
--     2,
--     20
-- from (
--     select generate_series(now(), now() + interval '1 year', '3 days')
--     union all 
--     select generate_series(now(), now() + interval '1 year', '5 days')
--     union all 
--     select generate_series(now(), now() + interval '1 year', '8 days')
-- ) i (i);


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


