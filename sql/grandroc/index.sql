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
    electricity_cost_unit amount,
    dog_price_unit amount,
    cgv text not null
);

insert into place (place, taxe_sejour, dog_price_unit, cgv) values
('grand gite', 1.25, 0, 'bla bla'),
('camping', 1.25, 3.50, 'bla bla')
on conflict (place) do nothing;

-- drop table if exists booking cascade;
create table if not exists booking (
    booking_id uuid primary key default uuidv7(),
    place text not null references place (place) on update cascade on delete cascade,
    occupant text not null references occupant (occupant) on update cascade on delete cascade,
    period daterange not null,
    status booking_status not null default 'in progress',
    nb_adults int,
    nb_children int not null default 0,
    nb_babies int not null default 0,
    nb_horses int not null default 0,
    nb_dogs int not null default 0,
    nb_emplacements int not null default 0,
    with_draps bool default false,
    with_serviette bool default false,
    with_cleaning bool default false,
    food_price_unit amount,
    cleaning_price amount,
    is_pension_complete bool default false,
    price amount not null,
    is_early bool not null default false,
    is_late bool not null default false,
    at date default now(),
    cue int not null default random(0, 180),
    exclude using gist (
        place with =,
        period with &&
    ) where (status = 'confirmed')
);

create or replace function days(period daterange) returns int
language sql
immutable strict parallel safe -- leakproof
begin atomic
    select (date_trunc('day', upper(period))::date - date_trunc('day', lower(period))::date) - 1;
end;

-- drop view if exists head;
create or replace view head (body)
with (security_invoker) as
    with httpg (error) as (
        select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
    )
    select '<!DOCTYPE html>'
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/index.css' as href))::text
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/grandroc/index.css' as href))::text
    union all select '<meta name="viewport" content="width=device-width">'
    union all select xmlelement(name script, xmlattributes('module' as type), $$
        document.querySelectorAll('.from').forEach(n => {
            n.addEventListener('change', e => {
                let to = document.querySelector('.to');
                to.value = to.value || n.value;
            });
        });
        document.querySelectorAll('.booking').forEach(n => {
            n.addEventListener('click', (e) => {
                document.querySelectorAll(`[data-booking="${e.target.dataset.booking}"]`).forEach(n => n.classList.toggle('active'));
            });
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
        ), 'Logements'),
        xmlelement(name a, xmlattributes(
            url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.stat'
            )) as href
        ), 'Stats'),
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
    nb_babies int,
    nb_horses int,
    nb_dogs int,
    nb_emplacements int,
    food_price_unit amount,
    cleaning_price amount,
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
    insert into grandroc.booking (booking_id, place, occupant, nb_adults, nb_children, nb_babies, nb_horses, nb_dogs, nb_emplacements, with_draps, with_serviette, cleaning_price, food_price_unit, is_pension_complete, price, is_early, is_late, period)
    select
        coalesce(booking_id, uuidv7()),
        place,
        coalesce((select occupant from occupant), occupant),
        nb_adults,
        nb_children,
        nb_babies,
        nb_horses,
        nb_dogs,
        nb_emplacements,
        body->>'with_draps' = 'on',
        body->>'with_serviette' = 'on',
        cleaning_price,
        food_price_unit,
        body->>'pension' = 'complete',
        price,
        coalesce(body->>'is_early' = 'on', false),
        coalesce(body->>'is_late' = 'on', false),
        daterange(from_, to_, '[]')
    from httpg
    on conflict (booking_id) do update set
        place = excluded.place,
        occupant = excluded.occupant,
        nb_adults = excluded.nb_adults,
        nb_children = excluded.nb_children,
        nb_babies = excluded.nb_babies,
        nb_horses = excluded.nb_horses,
        nb_dogs = excluded.nb_dogs,
        nb_emplacements = excluded.nb_emplacements,
        with_draps = excluded.with_draps,
        with_serviette = excluded.with_serviette,
        cleaning_price = excluded.cleaning_price,
        food_price_unit = excluded.food_price_unit,
        is_pension_complete = excluded.is_pension_complete,
        price = excluded.price,
        is_early = excluded.is_early,
        is_late = excluded.is_late,
        period = excluded.period
    returning 303 status,
    jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
        'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
        'when', to_char(from_::date, 'MM-YY')
    ))) header;
end;


drop view if exists occupant_html;
create or replace view occupant_html (body, occupant)
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
            'select * from grandroc.head union all select body::text from grandroc.occupant_html where case when $1 is not null then occupant = $1 else true end' as value
        )),
        xmlelement(name fieldset, xmlattributes('grid' as class),
            xmlelement(name label, 'Nom', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, coalesce(params->>0, (occupant).occupant) as value))),
            xmlelement(name label, 'Tél', xmlelement(name input, xmlattributes('params[1]' as name, 'tel' as type, coalesce(params->>1, (occupant).tel) as value))),
            xmlelement(name label, 'email', xmlelement(name input, xmlattributes('params[2]' as name, 'email' as type, 'required' as required, coalesce(params->>2, (occupant).email) as value))),
            xmlelement(name input, xmlattributes('params[3]' as name, 'hidden' as type, (occupant).occupant as value))
        ),
        xmlelement(name input, xmlattributes('submit' as type, action as value))
    )), (occupant).occupant
    from httpg, (table add union all table edit)
;

drop view if exists place_html;
create or replace view place_html (body, place)
with (security_invoker) as
    with httpg (params) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body'->'params'
    ),
    add (sql, action, place) as (
        select $$
            insert into grandroc.place (place, taxe_sejour, electricity_cost_unit, dog_price_unit, cgv)
            values ($1, nullif($2, '')::amount, nullif($3, '')::amount, nullif($4, '')::amount, $5)
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
            ))) header;
        $$, 'Add', null::place
    ),
    edit (sql, action, place) as (
        select $$
            update grandroc.place
                set place = $1,
                taxe_sejour = nullif($2, '')::amount,
                electricity_cost_unit = nullif($3, '')::amount,
                dog_price_unit = nullif($4, '')::amount,
                cgv = $5
            where place = $6
            returning 303 status,
            jsonb_build_object('Location', url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head union all select body::text from grandroc.place_html'
            ))) header;
        $$, 'Edit', p
        from place p
        order by place
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
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
            'select * from grandroc.head union all select body::text from grandroc.place_html where case when $1 is not null then place = $1 else true end' as value
        )),
        xmlelement(name fieldset, xmlattributes('grid' as class),
            xmlelement(name label, 'Logement', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, coalesce(params->>0, (place).place) as value))),
            xmlelement(name label, 'Taxe de séjour', xmlelement(name input, xmlattributes('params[1]' as name, 'number' as type, 'any' as step, 'required' as required, coalesce((params->>1), (place).taxe_sejour::text) as value))),
            xmlelement(name label, 'Prix électricité', xmlelement(name input, xmlattributes('params[2]' as name, 'number' as type, 'any' as step, coalesce(params->>3, (place).electricity_cost_unit::text) as value))),
            xmlelement(name label, 'Prix chien', xmlelement(name input, xmlattributes('params[3]' as name, 'number' as type, 'any' as step, coalesce(params->>4, (place).dog_price_unit::text) as value))),
            xmlelement(name label, 'CGV', xmlelement(name textarea, xmlattributes('params[4]' as name, 5 as rows, 'required' as required), coalesce(params->>5, (place).cgv, ''))),
            xmlelement(name input, xmlattributes('params[5]' as name, 'hidden' as type, (place).place as value))
        ),
        xmlelement(name input, xmlattributes('submit' as type, action as value)
    ))), (place).place
    from httpg, (table add union all table edit)
;

-- drop view if exists booking_html;
create or replace view booking_html (body)
with (security_invoker) as
with httpg (when_, booking_id, place) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select to_date(query->'qs'->>'when', 'MM-YY'),
    (query->'qs'->>'booking_id')::uuid,
    query->'qs'->>'place'
    from query
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
        coalesce(xmlagg(case when booking.place is not null then
            xmlelement(name section, xmlattributes(
                format('booking %s',  case when lower(period)::date <> d then 'line' end) as class,
                
                format('--cue: %s;', cue) as style,
                booking.booking_id as "data-booking"
            ),
                xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select body::text from grandroc.contract_html where booking_id = $1::uuid',
                        'params[0]', booking.booking_id
                    )) as href
                ), format('%s in %s', occupant, booking.place)),
                xmlelement(name a, xmlattributes(
                    url('/grandroc/query', jsonb_build_object(
                        'sql', 'select body::text from grandroc.head union all select body::text from grandroc.booking_html',
                        'booking_id', booking.booking_id
                    )) as href
                ), xmlelement(name button, 'Edit')),
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
                        booking.booking_id as value
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
        order by period asc, days(period) desc, booking.place)
    ), '')
    from httpg, day
    left join booking on period @> d
    where case when httpg.place is not null then booking.place = httpg.place else true end
    group by d
),
current_booking (b) as (
    select booking from httpg, booking where booking.booking_id = httpg.booking_id
    union all select null::booking from httpg where httpg.booking_id is null
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
                nb_children => coalesce(nullif($5, '')::int, 0),
                nb_babies => coalesce(nullif($6, '')::int, 0),
                nb_horses => coalesce(nullif($7, '')::int, 0),
                nb_dogs => coalesce(nullif($8, '')::int, 0),
                nb_emplacements => coalesce(nullif($9, '')::int, 0),
                food_price_unit => nullif($10, '')::grandroc.amount,
                price => nullif($11, '')::grandroc.amount,
                cleaning_price => nullif($12, '')::grandroc.amount,
                from_ => $13::date,
                to_ => $14::date
            )
        $$ as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from grandroc.head union all select body::text from grandroc.booking_html' as value
    )),
    xmlelement(name datalist, xmlattributes('occupants' as id),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(occupant as value)) order by occupant) from occupant), '')
    ),
    xmlelement(name input, xmlattributes('hidden' as type, 'params[0]' as name, (b).booking_id as value)),
    xmlelement(name label, 'Logement', xmlelement(name select, xmlattributes('params[1]' as name, 'required' as required),
        coalesce((select xmlagg(xmlelement(name option, xmlattributes(
            place as value,
            case when (b).place = place then 'selected' end as selected
        ), place) order by place) from current_booking, place), '')
    )),
    xmlelement(name label, 'Occupant', xmlelement(name input, xmlattributes('required' as required, 'occupants' as list, 'params[2]' as name, (b).occupant as value))),
    xmlelement(name label, 'Nb adultes', xmlelement(name input, xmlattributes('required' as required, 'number' as type, 'params[3]' as name, (b).nb_adults as value))),
    xmlelement(name label, 'Prix forfait', xmlelement(name input, xmlattributes('number' as type, 'params[10]' as name, 'required' as required, 'any' as step, (b).price as value))),
    xmlelement(name label, 'De', xmlelement(name input, xmlattributes('required' as required, 'from' as class, 'date' as type, 'params[12]' as name, lower((b).period) as value))),
    xmlelement(name label, 'à', xmlelement(name input, xmlattributes('required' as required, 'to' as class, 'date' as type, 'params[13]' as name, (upper((b).period) - interval '1 day')::date as value))),
    xmlelement(name label, 'Nb enfants', xmlelement(name input, xmlattributes('number' as type, 'params[4]' as name, (b).nb_children as value))),
    xmlelement(name label, 'nb bébés', xmlelement(name input, xmlattributes('number' as type, 'params[5]' as name, (b).nb_babies as value))),
    xmlelement(name label, 'Nb chevaux', xmlelement(name input, xmlattributes('number' as type, 'params[6]' as name, (b).nb_horses as value))),
    xmlelement(name label, 'Nb chiens', xmlelement(name input, xmlattributes('number' as type, 'params[7]' as name, (b).nb_dogs as value))),
    xmlelement(name label, 'Nb emplacements', xmlelement(name input, xmlattributes('number' as type, 'params[8]' as name, (b).nb_emplacements as value))),
    xmlelement(name label, 'Prix repas', xmlelement(name input, xmlattributes('number' as type, 'params[9]' as name, 'any' as step, (b).food_price_unit as value))),
    xmlelement(name label, 'Prix Ménage', xmlelement(name input, xmlattributes('number' as type, 'params[11]' as name, 'any' as step, (b).cleaning_price as value))),
    xmlelement(name label, 'Draps?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_draps' as name, case when (b).with_draps then 'checked' end as checked))),
    xmlelement(name label, 'Serviettes?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_serviette' as name, case when (b).with_serviette then 'checked' end as checked))),
    xmlelement(name label, 'Ménage?', xmlelement(name input, xmlattributes('checkbox' as type, 'with_cleaning' as name, case when (b).with_cleaning then 'checked' end as checked))),
    xmlelement(name fieldset,
        xmlelement(name label, 'Demi-pension?', xmlelement(name input, xmlattributes('radio' as type, 'pension' as name, 'demi' as value,
            case when (b).food_price_unit > 0 and not (b).is_pension_complete then 'checked' end as checked
        ))),
        xmlelement(name label, 'Pension Complete?', xmlelement(name input, xmlattributes('radio' as type, 'pension' as name, 'complete' as value,
            case when (b).food_price_unit > 0 and (b).is_pension_complete then 'checked' end as checked
        )))
    ),
    xmlelement(name input, xmlattributes('submit' as type, case when (b).booking_id is not null then 'Edit' else 'Add' end as value))
)
from current_booking
union all select '<hr/>'
union all select xmlelement(name nav, xmlattributes('calnav' as id),
    xmlelement(name a, xmlattributes(
        url.url('/grandroc/query', jsonb_build_object(
            'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
            'when', to_char(coalesce(when_, now()::date) - interval '1 month', 'MM-YY')
        )) || '#calnav' as href
    ), 'prev'),
    xmltext(to_char(coalesce(when_, now()::date), 'Mon/YY')),
    xmlelement(name a, xmlattributes(
        url.url('/grandroc/query', jsonb_build_object(
            'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
            'when', to_char(coalesce(when_, now()::date) + interval '1 month', 'MM-YY')
        )) || '#calnav' as href
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
line (booking_id, label, qty, pu, total) as (
    select booking_id, line.*, qty * pu
    from booking
    join place using (place),
    unnest(array[
        row(
            place,
            1,
            price
        ),
        row(
            'Ménage'::text,
            1,
            cleaning_price
        ),
        row(
            'Taxe de séjour'::text,
            nb_adults * days(period),
            taxe_sejour
        ),
        row(
            'Serviettes'::text,
            case when with_serviette then nb_adults + nb_children end,
            4::amount
        ),
        row(
            'Draps'::text,
            nb_adults + nb_children,
            8::amount
        ),
        row(
            case when is_pension_complete then 'Pension Complete' else 'Demi pension' end,
            nb_adults + nb_children * days(period),
            food_price_unit
        ),
        row(
            'Chevaux'::text,
            nb_horses * days(period),
            5::amount
        ),
        row(
            'Chiens'::text,
            nb_dogs,
            dog_price_unit
        ),
        row(
            'Départ ou arrivée tardive'::text,
            1,
            case when is_early and is_late then 70
                when is_early then 50
                when is_late then 50
            end::amount
        ),
        row(
            'Electricité'::text,
            nb_emplacements * days(period),
            electricity_cost_unit
        )
    ]) line (label text, qty int, pu amount)
),
grand_total (booking_id, grand_total, acompte) as (
    select booking_id, sum(total), round(0.3 * sum(total), 0)
    from line
    group by booking_id
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
    xmlelement(name link, xmlattributes('stylesheet' as rel, '/grandroc/contract.css' as href))),
  xmlelement(name body, xmlattributes(true as contenteditable),
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
                to_char(upper(period) - interval '1 day', 'DD/MM/YYYY')
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
            xmltext((nb_children + nb_babies)::text)) end, 
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
          (select xmlagg(xmlelement(name tr, 
            xmlelement(name td, label), 
            xmlelement(name td, xmlattributes(
              'center' as "class"
            ), qty::text), 
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), pu::text),
            xmlelement(name td, xmlattributes(
              'right' as "class"
            ), total)
          ))
          from line
          where booking_id = booking.booking_id
          and total > 0
        )
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
            xmltext(grand_total::text))),
        xmlelement(name div, xmlattributes(
          'payment-row' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Acompte de 30 %')), 
          xmlelement(name strong, 
            xmltext(round(acompte, 2)::text))), 
        xmlelement(name div, xmlattributes(
          'payment-row' as "class"
        ), 
          xmlelement(name span, 
            xmltext('Solde restant à régler')), 
          xmlelement(name strong, 
            xmltext((grand_total - acompte)::text))), 
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
          ) 
        ), 
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
from grand_total
join booking using (booking_id)
join occupant using (occupant)
join place using (place)
;

-- truncate table occupant cascade;
-- insert into occupant (occupant) values ('georges')
-- on conflict (occupant) do nothing;

-- truncate table booking;
-- insert into booking (place, occupant, price, period, with_cleaning, nb_adults, nb_children, nb_babies, nb_horses, food_price_unit, with_draps, with_serviette, is_early, is_late)
-- select
--     (select place from place order by random() limit 1),
--     (select occupant from occupant order by random() limit 1),
--     900,
--     daterange(i::date, (i + format('%s days', random(2, 8))::interval)::date, '[)'),
--     true,
--     4,
--     2,
--     1,
--     2,
--     20,
--     true,
--     true,
--     true,
--     false
-- from (
--     select generate_series(now() - interval '3 weeks', now() + interval '1 week', '3 days')
--     union all 
--     select generate_series(now() + interval '3 weeks', now() + interval '6 weeks', '5 days')
--     union all 
--     select generate_series(now() + interval '8 weeks', now() + interval '5 months', '8 days')
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


-- drop view if exists stat;
create or replace view stat (body)
with (security_invoker) as
with top_place (nb, place, max) as (
    select count(booking), place, max(count(booking)) over ()
    from booking
    group by place
),
top_date (nb, date, max) as (
    select count(booking), date_trunc('month', d)::date, max(count(booking)) over ()
    from generate_series((now() - interval '6 months'), (now() + interval '6 months'), '1 day') d
    left join booking on lower(period) = d::date
    group by 2
    order by 2
)
select xmlelement(name div, xmlattributes('chart' as class),
    xmlelement(name table,
        xmlelement(name caption, xmlelement(name h3, 'Top places')),
        xmlagg(xmlelement(name tr,
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/grandroc/query', jsonb_build_object(
                    'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
                    'place', place
                )) as href
            ), place)),
            xmlelement(name td, xmlelement(name div, xmlattributes(
                format('--size: %s; --max: %s', nb, max) as style
            ), nb))
        ))
    )
)
from top_place
union all select xmlelement(name hr)
union all select xmlelement(name div, xmlattributes('chart' as class),
    xmlelement(name table,
        xmlelement(name caption, xmlelement(name h3, 'Top Dates')),
        xmlagg(xmlelement(name tr,
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/grandroc/query', jsonb_build_object(
                    'sql', 'select * from grandroc.head union all select body::text from grandroc.booking_html',
                    'when', to_char(date::date, 'MM-YY')
                )) as href
            ), to_char(date::date, 'Mon/YY'))),
            xmlelement(name td, xmlelement(name div, xmlattributes(
                format('--size: %s; --max: %s', nb, max) as style
            ), nb))
        ))
    )
)
from top_date
;

grant execute on function login() to anon;
grant grandroc to anon;
grant usage on schema grandroc, url to anon, grandroc;
grant select on table stat to anon, grandroc;
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


