-- require: url/url.sql

do $$ begin
    create role jmeu noinherit;
    exception when duplicate_object then raise notice '%, skipping', sqlerrm using errcode = sqlstate;
end $$;

drop schema if exists jmeu cascade;
create schema if not exists jmeu;
set local search_path to jmeu, url, pg_catalog, public;

create table tenant (
    tenant_id uuid primary key default uuidv7(),
    name text unique not null,
    password text not null,
    salt text not null
);

create table animal (
    tenant_id uuid not null references tenant (tenant_id) default nullif(current_setting('jmeu.tenant_id', true), '')::uuid,
    number text not null,
    lot text not null,
    sex text not null,
    birth date not null default now(),
    mother text,
    primary key (tenant_id, number),
    constraint has_mother foreign key (tenant_id, mother) references animal (tenant_id, number)
);

alter table animal enable row level security;
create policy "owner" on animal for all to jmeu
using (tenant_id = current_setting('jmeu.tenant_id', true)::uuid);

with grandmother as (
    insert into animal (tenant_id, number, lot, birth, sex)
    select tenant_id, random(), random(1, 4), now() - format('%s years', random(2, 10))::interval, 'Femelle'
    from tenant, generate_series(1, 3)
    returning *
),
mother as (
    insert into animal (tenant_id, number, lot, mother, birth, sex)
    select tenant_id, random(), random(1, 4), number, now() - format('%s months', random(7, 20))::interval, 'Femelle'
    from grandmother, generate_series(1, 4)
    returning *
)
insert into animal (tenant_id, number, lot, mother, birth, sex)
select tenant_id, name || random(), random(1, 4), number, now() - format('%s days', random(20, 300))::interval, 'Mâle'
from generate_series(1, 5), mother
join tenant using (tenant_id)
;

create table medication (
    tenant_id uuid not null references tenant (tenant_id) default nullif(current_setting('jmeu.tenant_id', true), '')::uuid,
    medication_id uuid not null default uuidv7(),
    name text not null,
    posology text not null,
    is_empty bool not null default false,
    date date not null default now(),
    primary key (tenant_id, medication_id)
);

alter table medication enable row level security;
create policy "owner" on medication for all to jmeu
using (tenant_id = current_setting('jmeu.tenant_id', true)::uuid);

insert into medication (tenant_id, name, posology)
select tenant_id, 'medoc ' || random(2, 200), format('%smL par kg', random(10, 70))
from tenant, generate_series(1, 3);

create table treatment (
    tenant_id uuid not null references tenant (tenant_id) default nullif(current_setting('jmeu.tenant_id', true), '')::uuid,
    number text not null,
    at timestamptz not null default now(),
    medication_id uuid not null,
    ordonnance text not null,
    comment text,
    primary key (tenant_id, number, medication_id, at),
    foreign key (tenant_id, number) references animal (tenant_id, number),
    foreign key (tenant_id, medication_id) references medication (tenant_id, medication_id)
);

alter table treatment enable row level security;
create policy "owner" on treatment  for all to jmeu
using (tenant_id = current_setting('jmeu.tenant_id', true)::uuid);

insert into treatment (tenant_id, number, at, ordonnance, medication_id)
select tenant_id, number, now() - format('%s days', random(20, 300))::interval, 'ordonnance ' || random(20, 800), medication_id
from animal
join medication using (tenant_id);


create or replace function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to jmeu, pg_catalog
begin atomic
    with httpg (body) as (
      select current_setting('httpg.query', true)::jsonb->'body'
    )
    select format('set local role to jmeu; set local "jmeu.tenant_id" to %L', tenant_id)
    -- select 303,
    -- jsonb_build_object(
    --     'Location', url.url('/jmeu/query', jsonb_build_object(
    --         'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html'
    --     )),
    --     'Set-Cookie', format('jmeu=%s; HttpOnly; SameSite=Lax; Path=jmeu; Max-Age: 86400',
    --         pgp_sym_encrypt(format('set local role to jmeu; set local "jmeu.tenant_id to %L"', tenant_id), 'secreeeeet')
    --     )
    -- )
    from tenant, httpg
    where name = body->>'name'
    and password = crypt(body->>'password', salt);
end;

-- create or replace function check_cookie() returns void
-- language plpgsql
-- volatile
-- as $$
-- declare httpg jsonb;
-- declare query text;
-- begin
--     raise notice '%', 'YOOOOOOO';
--     select nullif(current_setting('httpg.query', true), '')::jsonb into httpg;
--     begin
--     select pgp_sym_decrypt(httpg->'cookies'->>'jmeu', 'secreeeeet') into query;
--     exception when others then
--         raise notice '%', sqlerrm;
--         return;
--     end;
--     execute query;
-- end;
-- $$;

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
    union all select xmlelement(name script, xmlattributes('module' as type), $$
        document.getElementById('all')?.addEventListener('click', (e) => {
            document.querySelectorAll('.animals input[type=checkbox]').forEach(n => {
                n.checked = e.target.checked;
            });
        });
        document.querySelectorAll('form.admin').forEach(n => {
            n.addEventListener('submit', (e) => {
                document.querySelectorAll('.animals input[type=checkbox]').forEach(i => {
                    i.setAttribute('form', e.target.id);
                });
            });
        });
    $$::text::xml)::text
    union all select xmlelement(name header,
        xmlelement(name h1, xmlelement(name a, xmlattributes(
            url('/jmeu/query', jsonb_build_object(
                'redirect', url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head'
                ))
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
            -- url('/jmeu/query', jsonb_build_object(
            --     'sql', 'select * from jmeu.login()'
            -- )) as action
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
                url.url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head union all select body::text from jmeu.agneulage_html'
                )) as href
            ), 'Agneulages'),
            xmlelement(name a, xmlattributes(
                url.url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head union all select body::text from jmeu.treatment_html'
                )) as href
            ), 'Journal sanitaire'),
            xmlelement(name a, xmlattributes(
                url.url('/jmeu/query', jsonb_build_object(
                    'sql', 'select * from jmeu.head union all select body::text from jmeu.medication_html'
                )) as href
            ), 'Médicaments'),
            xmlelement(name a, xmlattributes(
                url.url('/jmeu/logout', jsonb_build_object(
                    'redirect', url('/jmeu/query', jsonb_build_object('sql', 'select * from jmeu.head'))
                )) as href
            ), 'Logout')
            -- @TODO tous les agnelages grouped by date avec filtre from et to
            -- @TODO tous les traitements (journal sanitaire)
        )
        where current_role = 'jmeu'),
        (
            select xmlelement(name div, xmlattributes('flashes' as class),
                xmlelement(name article, xmlattributes('red card' as class), error)
            )
            from httpg
            where error is not null
        ),
        (
            select xmlelement(name div, xmlattributes('flashes' as class),
                xmlelement(name article, xmlattributes(format('%s card', key) as class), value)
            )
            from httpg, jsonb_each_text(qs->'flashes')
        )
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
select xmlelement(name details,
    xmlelement(name summary, 'Ajouter animal'),
    xmlelement(name form, xmlattributes(
        'POST' as method,
        url.url('/jmeu/query', jsonb_build_object(
            'redirect', 'referer'
        )) as action
    ),
        xmlelement(name fieldset, xmlattributes('grid' as class),
            xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, $$
                insert into jmeu.animal (number, lot, sex, birth) values ($1, $2, $3, $4::date)
            $$ as value)),
            xmlelement(name label, 'Numero', xmlelement(name input, xmlattributes('text' as type, 'params[0]' as name, 'required' as required))),
            xmlelement(name label, 'Lot', xmlelement(name input, xmlattributes('text' as type, 'params[1]' as name, 'required' as required))),
            xmlelement(name fieldset,
                xmlelement(name label, 'Mâle', xmlelement(name input, xmlattributes('radio' as type, 'params[2]' as name, 'Mâle' as value, 'required' as required))),
                xmlelement(name label, 'Femelle', xmlelement(name input, xmlattributes('radio' as type, 'params[2]' as name, 'Femelle' as value)))
            ),
            xmlelement(name label, 'Date de naissance', xmlelement(name input, xmlattributes('date' as type, 'params[3]' as name, 'required' as required)))
        ),
        xmlelement(name input, xmlattributes('submit' as type, 'Ajouter animal' as value))
    )
)
union all
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
    xmlelement(name label, 'Numéro', xmlelement(name input, xmlattributes(
        'text' as type,
        'number' as name,
        qs->>'number' as value
    ))),
    xmlelement(name label, 'Lot', xmlelement(name select, xmlattributes('lot' as name),
        coalesce((
            with lot (lot) as (
                select '' lot union all 
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
from httpg
union all select xmlelement(name pre, coalesce(jsonb_pretty(body), '')) from httpg
union all 
select xmlelement(name form, xmlattributes(
    'POST' as method,
    'treat' as id,
    'admin' as class,
    url.url('/jmeu/query', jsonb_build_object(
        'sql', 'call jmeu.admin()',
        'lot', qs->>'lot'
    )) as action
), '')
from httpg
union all 
select xmlelement(name form, xmlattributes(
    'POST' as method,
    'move_lot' as id,
    'admin' as class,
    url.url('/jmeu/query', jsonb_build_object(
        'sql', 'call jmeu.admin()',
        'lot', qs->>'lot'
    )) as action
), '')
from httpg
union all 
select xmlelement(name form, xmlattributes(
    'POST' as method,
    url.url('/jmeu/query', jsonb_build_object(
        'sql', 'call jmeu.admin()',
        'lot', qs->>'lot'
    )) as action
),
    xmlelement(name label, 'Tous', xmlelement(name input, xmlattributes('checkbox' as type, 'all' as id))),
    xmlelement(name div, xmlattributes('grid' as class, '--min: 40vw' as style),
        xmlelement(name div, xmlattributes('animals' as class), coalesce((
            select xmlagg(xmlelement(name label, xmlattributes('card' as class),
                xmlelement(name input, xmlattributes('checkbox' as type, 'number[]' as name, number as value)),
                xmlelement(name a, xmlattributes(
                    url.url('/jmeu/query', jsonb_build_object(
                        'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html',
                        'number', number
                    )) as href
                ), number)
            ) order by number)
            from animal, httpg
            where case when nullif(qs->>'lot', '') is not null then qs->>'lot' = lot else true end
            and case when nullif(qs->>'number', '') is not null then qs->>'number' = number else true end
        ), 'Aucun animal')),
        xmlelement(name fieldset, xmlattributes('' as class),
            xmlelement(name fieldset, xmlattributes('card' as class),
                xmlelement(name label, 'Ordonnance', xmlelement(name input, xmlattributes('text' as type, 'ordonnance' as name, 'required' as required, 'treat' as form))),
                xmlelement(name label, 'Médicament', xmlelement(name select, xmlattributes('medication_id' as name, 'required' as required, 'treat' as form),
                    coalesce((
                        select xmlagg(xmlelement(name option, xmlattributes(
                            medication_id as value
                        ), format('%s (%s)', name, medication.posology)) order by name)
                        from medication
                        where not is_empty
                    ), '')
                )),
                xmlelement(name label, 'Commentaire', xmlelement(name textarea, xmlattributes('comment' as name, 5 as rows, 'treat' as form), '')),
                xmlelement(name button, xmlattributes('submit' as type, 'action' as name, 'treat' as value, 'treat' as form), 'Traiter')
            ),
            xmlelement(name fieldset, xmlattributes('card' as class),
                xmlelement(name label, 'Lot', xmlelement(name input, xmlattributes('text' as type, 'lot' as name, 'required' as required, 'move_lot' as form))),
                xmlelement(name button, xmlattributes('submit' as type, 'action' as name, 'move_lot' as value, 'move_lot' as form), 'Changer de lot')
            )
        )
    )
)
from httpg;

create or replace view agneulage_html (body)
with (security_invoker) as
with httpg (qs, body) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select query->'qs', query->'body'
    from query
)
select xmlelement(name form, xmlattributes('GET' as method),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        'select * from jmeu.head union all select body::text from jmeu.agneulage_html' as value
    )),
    xmlelement(name label, 'De', xmlelement(name input, xmlattributes(
        'date' as type,
        'from' as name,
        qs->>'from' as value
    ))),
    xmlelement(name label, 'à', xmlelement(name input, xmlattributes(
        'date' as type,
        'to' as name,
        qs->>'to' as value
    ))),
    xmlelement(name input, xmlattributes('submit' as type, 'Chercher' as value))
)
from httpg
union all
(select xmlelement(name div, xmlattributes('card animal grid' as class),
    xmlelement(name a, xmlattributes(
        url.url('/jmeu/query', jsonb_build_object(
            'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html',
            'number', number
        )) as href
    ), number),
    xmlelement(name div, format('Sexe: %s', sex)),
    xmlelement(name div, format('Lot: %s', lot)),
    xmlelement(name time, to_char(birth, 'DD/MM/YY'))
)
from animal, httpg
where mother is not null
and case when nullif(qs->>'from', '') is not null then birth >= (qs->>'from')::date else true end
and case when nullif(qs->>'to', '') is not null then birth <= (qs->>'to')::date else true end
order by birth desc)
;

create or replace view treatment_html (body)
with (security_invoker) as
with httpg (qs, body) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select query->'qs', query->'body'
    from query
),
treat_group as (
    select *, date_part('year', at) as year
    from treatment
)
select xmlelement(name div,
    xmlelement(name h2, year),
    coalesce(xmlagg(xmlelement(name div, xmlattributes('card treatment grid' as class),
        xmlelement(name a, xmlattributes(
            url.url('/jmeu/query', jsonb_build_object(
                'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html',
                'number', number
            )) as href
        ), number),
        xmlelement(name time, to_char(at, 'DD/MM/YY')),
        xmlelement(name div, name),
        xmlelement(name div, posology),
        xmlelement(name pre, coalesce(comment, ''))
    )), '')
)
from treat_group
join medication using (medication_id)
group by year
order by year desc
;

create or replace view animal_html (body)
with (security_invoker) as
with httpg (qs, body) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select query->'qs', query->'body'
    from query
)
select xmlelement(name div, xmlattributes('card animal' as class),
    xmlelement(name h3, number),
    xmlelement(name div, format('Lot: %s', lot)),
    xmlelement(name div, format('Sexe: %s', sex)),
    xmlelement(name time, to_char(birth, 'DD/MM/YY')),
    case when mother is not null then xmlelement(name a, xmlattributes(
        url.url('/jmeu/query', jsonb_build_object(
            'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html',
            'number', mother
        )) as href
    ), 'Mère') end,
    xmlelement(name div, xmlattributes('grid' as class),
        xmlelement(name details, xmlattributes(true as open),
            xmlelement(name summary, 'Traitements'),
            (
                select xmlagg(xmlelement(name div, xmlattributes('card' as class),
                    xmlelement(name h4, name),
                    xmlelement(name div, posology),
                    xmlelement(name time, to_char(at, 'DD/MM/YY')),
                    xmlelement(name pre, coalesce(comment, ''))
                ) order by at desc)
                from treatment
                join medication using (medication_id)
                where treatment.number = animal.number
            )
        ),
        xmlelement(name details, xmlattributes(true as open),
            xmlelement(name summary, 'Agneulages'),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                url.url('/jmeu/query', jsonb_build_object(
                    'redirect', 'referer',
                    'flashes[green]', 'Sauvegardé'
                )) as action
            ),
                xmlelement(name fieldset, xmlattributes('grid' as class),
                    xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, $$
                        insert into jmeu.animal (number, lot, mother, sex, birth) values ($1, $2, $3, $4, $5::date)
                    $$ as value)),
                    xmlelement(name label, 'Numero', xmlelement(name input, xmlattributes('text' as type, 'params[0]' as name, 'required' as required))),
                    xmlelement(name label, 'Lot', xmlelement(name input, xmlattributes('text' as type, 'params[1]' as name, 'required' as required))),
                    xmlelement(name fieldset,
                        xmlelement(name label, 'Mâle', xmlelement(name input, xmlattributes('radio' as type, 'params[3]' as name, 'Mâle' as value, 'required' as required))),
                        xmlelement(name label, 'Femelle', xmlelement(name input, xmlattributes('radio' as type, 'params[3]' as name, 'Femelle' as value)))
                    ),
                    xmlelement(name label, 'Date de naissance', xmlelement(name input, xmlattributes('date' as type, 'params[4]' as name, 'required' as required))),
                    xmlelement(name input, xmlattributes('hidden' as type, 'params[2]' as name, animal.number as value))
                ),
                xmlelement(name input, xmlattributes('submit' as type, 'Ajouter agneau' as value))
            ),
            (
                select xmlagg(xmlelement(name div, xmlattributes('card' as class),
                    xmlelement(name a, xmlattributes(
                        url.url('/jmeu/query', jsonb_build_object(
                            'sql', 'select * from jmeu.head union all select body::text from jmeu.animal_html',
                            'number', number
                        )) as href
                    ), number),
                    xmlelement(name div, format('Sexe: %s', sex)),
                    xmlelement(name div, format('(Lot: %s)', lot)),
                    xmlelement(name time, to_char(birth, 'DD/MM/YY'))
                ) order by birth desc)
                from animal a
                where a.mother = animal.number
            )
        )
    )
)
from animal, httpg
where case when qs ? 'number' then number = qs->>'number' else true end
;

create or replace function httpg_query() returns jsonb
language sql
strict stable parallel safe
begin atomic
    select nullif(current_setting('httpg.query', true), '')::jsonb;
end;


-- drop view if exists medication_html;
create or replace view medication_html (body, medication_id)
with (security_invoker) as
    with httpg (body, params) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'body',
            nullif(current_setting('httpg.query', true), '')::jsonb->'body'->'params'
    ),
    add (sql, action, medication) as (
        select $$
            insert into jmeu.medication (name, posology) values ($1, $2)
            returning 303 status,
            jsonb_build_object('Location', url.url('/jmeu/query', jsonb_build_object(
                'sql', 'select * from jmeu.head union all select body::text from jmeu.medication_html',
                'flashes[green]', 'Sauvegardé'
            ))) header;
        $$, 'Add', null::medication
    ),
    edit (sql, action, medication) as (
        select $$
            update jmeu.medication set name = $1, posology = $2, is_empty = coalesce(httpg_query()->'body'->>'is_empty' = 'on', false)
            where medication_id = $3::uuid
            returning 303 status,
            jsonb_build_object('Location', url.url('/jmeu/query', jsonb_build_object(
                'sql', 'select * from jmeu.head union all select body::text from jmeu.medication_html',
                'flashes[green]', 'Sauvegardé'
            ))) header;
        $$, 'Edit', m
        from medication m
        order by name, date
    )
    select xmlelement(name article, xmlattributes('card' as class), xmlelement(name form, xmlattributes(
            'POST' as method,
            '/jmeu/query' as action
        ),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            sql as value
        )),
        xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            $$select * from jmeu.head union all select body::text from jmeu.medication_html where case when nullif($3, '') is not null then medication_id = $3::uuid else true end$$ as value
        )),
        xmlelement(name fieldset, xmlattributes('grid' as class),
            xmlelement(name label, 'Nom', xmlelement(name input, xmlattributes('params[0]' as name, 'text' as type, 'required' as required, coalesce(params->>1, (medication).name) as value))),
            xmlelement(name label, 'Posologie', xmlelement(name input, xmlattributes('params[1]' as name, 'text' as type, 'required' as required, coalesce(nullif(params->>2, ''), (medication).posology) as value))),
            xmlelement(name label, 'Vide?', xmlelement(name input, xmlattributes('is_empty' as name, 'checkbox' as type, case when coalesce(body->>'is_empty' = 'on', (medication).is_empty) then 'checked' end as checked))),
            xmlelement(name input, xmlattributes('params[2]' as name, 'hidden' as type, (medication).medication_id as value))
        ),
        xmlelement(name input, xmlattributes('submit' as type, action as value))
    )), (medication).medication_id
    from httpg, (table add union all table edit)
;

-- drop procedure if exists admin;
create or replace procedure admin(
    inout status int default null,
    header inout jsonb default null
)
language sql
begin atomic
    with httpg (qs, body) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'qs',
        nullif(current_setting('httpg.query', true), '')::jsonb->'body'
    ),
    treat as (
        insert into treatment (number, at, ordonnance, medication_id, comment)
        select number, now(), body->>'ordonnance', (body->>'medication_id')::uuid, body->>'comment'
        from httpg, jsonb_array_elements_text(body->'number') number
        where body->>'action' = 'treat'
    ),
    move_lot as (
        update animal set lot = body->>'lot'
        from httpg
        where body->'number' ? number
        and body->>'action' = 'move_lot'
    )
    select 303 status,
    jsonb_build_object('Location', url.url('/jmeu/query', jsonb_build_object(
        'sql', 'select * from jmeu.head union all select body::text from jmeu.admin_html',
        'lot', qs->>'lot',
        'flashes[green]', 'Sauvegardé'
    ))) header
    from httpg;
end;

grant jmeu to anon;
grant execute on function login() to anon, jmeu;
-- grant execute on function check_cookie() to anon, jmeu;
grant usage on schema jmeu, url to anon, jmeu;
grant select on table head to anon, jmeu;
grant select, insert, update on table animal to jmeu;
grant select, insert, update on table medication to jmeu;
grant select on table admin_html to jmeu;
grant select on table agneulage_html to jmeu;
grant select on table treatment_html to jmeu;
grant select on table animal_html to jmeu;
grant select, insert on table treatment to jmeu;
grant select on table medication_html to jmeu;
grant execute on procedure admin to jmeu;
grant execute on function url.url to jmeu;
grant execute on function url.encode to jmeu;
grant execute on function httpg_query to jmeu;
