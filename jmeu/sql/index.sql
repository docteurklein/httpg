\set ON_ERROR_STOP on

do $$ begin
    create role jmeu noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

create extension if not exists pgcrypto schema public;

drop schema if exists jmeu cascade;
create schema if not exists jmeu;
set local search_path to jmeu, url, pg_catalog, public;

create table tenant (
    tenant_id uuid primary key default uuidv7(),
    name text unique not null,
    password text not null,
    salt text not null
);

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into tenant (name, password, salt)
select 'jmeu', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;

create table animal (
    tenant_id uuid not null references tenant (tenant_id),
    number text not null,
    lot text not null,
    birth date not null,
    mother text,
    primary key (tenant_id, number),
    constraint has_mother foreign key (tenant_id, mother) references animal (tenant_id, number)
);

with grandmother as (
    insert into animal (tenant_id, number, lot, birth)
    select tenant_id, random(), random(1, 4), now() - format('%s days', random(20, 300))::interval
    from tenant, generate_series(1, 100)
    returning *
),
mother as (
    insert into animal (tenant_id, number, lot, mother, birth)
    select tenant_id, random(), random(1, 4), number, now() - format('%s days', random(20, 300))::interval
    from grandmother, generate_series(1, 3)
    returning *
)
insert into animal (tenant_id, number, lot, mother, birth)
select tenant_id, random(), random(1, 4), number, now() - format('%s days', random(20, 300))::interval
from mother, generate_series(1, 3)
;

create table medication (
    tenant_id uuid not null references tenant (tenant_id),
    medication_id uuid not null default uuidv7(),
    ordonnance text not null,
    name text not null,
    quantity int not null,
    date date not null default now(),
    primary key (tenant_id, medication_id)
);

insert into medication (tenant_id, ordonnance, name, quantity)
select tenant_id, random(), random(), random(1, 7)
from tenant, generate_series(1, 3);

create table treatment (
    tenant_id uuid not null references tenant (tenant_id),
    number text not null,
    at date not null default now(),
    medication_id uuid not null,
    quantity int not null,
    comment text,
    primary key (tenant_id, number, medication_id, at),
    foreign key (tenant_id, number) references animal (tenant_id, number),
    foreign key (tenant_id, medication_id) references medication (tenant_id, medication_id)
);

insert into treatment (tenant_id, number, at, medication_id, quantity)
select tenant_id, number, now() - format('%s days', random(20, 300))::interval, medication_id, random(.2, .8)
from animal
join medication using (tenant_id);

-- drop view if exists head;
create or replace view head (body)
with (security_invoker) as
    with httpg (qs, body, error) as (
        with query (query, error) as (
            select nullif(current_setting('httpg.query', true), '')::jsonb,
                nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
        )
        select query->'qs', query->'body', error
        from query
    )
    select '<!DOCTYPE html>'
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/index.css' as href))::text
    union all select xmlelement(name link, xmlattributes('stylesheet' as rel, '/jmeu/index.css' as href))::text
    union all select '<meta name="viewport" content="width=device-width">'
    -- union all select xmlelement(name script, xmlattributes('module' as type), $$
    -- $$::text::xml)::text
    union all select xmlelement(name header,
        xmlelement(name h1, xmlelement(name a, xmlattributes(
            url('/jmeu/query', jsonb_build_object(
                'redirect', url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head'
                )),
                'params[0]', 'jmeu'
            )) as href
        ), 'Jmeu')),
        (select xmlelement(name form, xmlattributes(
            'grid' as class,
            'POST' as method,
            url('/jmeu/login', jsonb_build_object(
                'redirect', url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html'
                )),
                'params[0]', 'jmeu'
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
        )
        where current_role <> 'jmeu'),
        (select xmlelement(name nav,
            xmlelement(name a, xmlattributes(
                url.url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html'
                )) as href
            ), 'Animaux'),
            xmlelement(name a, xmlattributes(
                url.url('/jmeu/logout', jsonb_build_object(
                    'redirect', url('/jmeu/query', jsonb_build_object('sql', 'select * from jmeu.head'))
                )) as href
            ), 'Logout')
        )
        where current_role = 'jmeu'),
        (select xmlelement(name div, xmlattributes('flashes' as class),
            xmlelement(name article, xmlattributes('red card' as class), error)
        )
        from httpg
        where error is not null)
)::text;


-- drop view if exists admin_html;
create or replace view admin_html (body)
with (security_invoker) as
with httpg (qs, body) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select query->'qs', query->'body'
    from query
)
select xmlelement(name form, xmlattributes(
    'GET' as method
    -- url.url('/jmeu/query', jsonb_build_object(
    --     'sql', 'select $1::text'
    --     -- 'in_types[0]', 'jsonb'
    -- )) as action
),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        'select * from jmeu.head union all select body::text from jmeu.admin_html' as value
    )),
    xmlelement(name label, 'Lot', xmlelement(name select, xmlattributes('lot' as name),
        coalesce((
            with lot (lot) as (
                select distinct lot from animal
            )
            select xmlagg(xmlelement(name option, xmlattributes(
                lot as value,
                case when lot = qs->>'lot' then 'selected' end as selected
            ), lot) order by lot) from lot, httpg
        ), '')
    )),
    xmlelement(name input, xmlattributes('submit' as type, 'Chercher' as value))
)
union all select xmlelement(name pre, coalesce(jsonb_pretty(body), '')) from httpg
union all 
select xmlelement(name form, xmlattributes(
    'POST' as method,
    url.url('/jmeu/query', jsonb_build_object(
        'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html',
        'lot', qs->>'lot'
    )) as action
),
    xmlelement(name label, 'Tous ces animaux', xmlelement(name input, xmlattributes('checkbox' as type, 'all' as name, 'all' as value))),
    xmlelement(name div, xmlattributes('grid' as class, '--min: 40vw' as style),
        xmlelement(name div, xmlattributes('animals' as class),
                (
                select xmlagg(xmlelement(name label, xmlattributes('card' as class),
                    xmlelement(name input, xmlattributes('checkbox' as type, 'number[]' as name, number as value)),
                    xmlelement(name a, xmlattributes(
                        url.url('/jmeu/query', jsonb_build_object(
                            'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html'
                        )) as href
                    ), number)
                ) order by number)
                from animal, httpg
                where case when qs->>'lot' is not null then qs->>'lot' = lot else true end
            )),
        xmlelement(name fieldset,
            xmlelement(name fieldset, xmlattributes('grid' as class),
                -- xmlelement(name label, 'Médicament', xmlelement(name input, xmlattributes('text' as type, 'medication' as name, '' as value))),
                xmlelement(name label, 'Médicament', xmlelement(name select, xmlattributes('medication_id' as name),
                    coalesce((select xmlagg(xmlelement(name option, xmlattributes(
                        medication_id as value
                        -- case when (b).place = place then 'selected' end as selected
                    ), name) order by name) from medication), '')
                )),
                xmlelement(name label, 'Qté', xmlelement(name input, xmlattributes('number' as type, 'quantity' as name, '' as value, 'any' as step))),
                xmlelement(name label, 'Commentaire', xmlelement(name textarea, xmlattributes('comment' as name, 5 as rows), '')),
                xmlelement(name input, xmlattributes('submit' as type, 'treat' as name, 'Traiter' as value))
            ),
            xmlelement(name fieldset,
                xmlelement(name label, 'Lot', xmlelement(name input, xmlattributes('text' as type, 'lot' as name, '' as value))),
                xmlelement(name input, xmlattributes('submit' as type, 'move_lot' as name, 'Changer de lot' as value))
            )
        )
    )
)
from httpg;


create or replace view animal_html (body)
with (security_invoker) as
with httpg (qs, body) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select query->'qs', query->'body'
    from query
)
select xmlelement(name form, xmlattributes(
    'POST' as method,
    url.url('/jmeu/query', jsonb_build_object(
        'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html'
    )) as action
));

create or replace function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to grandroc, pg_catalog
begin atomic
    with httpg (body) as (
      select current_setting('httpg.query', true)::jsonb->'body'
    )
    select format('set local role to jmeu; set local "jmeu.tenant_id" to %L', tenant_id)
    from tenant, httpg
    where name = body->>'name'
    and password = crypt(body->>'password', salt);
end;

grant jmeu to anon;
grant execute on function login() to anon, jmeu;
grant usage on schema jmeu, url to anon, jmeu;
grant select on table head to anon, jmeu;
grant select on table animal to anon, jmeu;
grant select on table medication to anon, jmeu;
grant select on table admin_html to anon, jmeu;
grant select on table animal_html to anon, jmeu;
