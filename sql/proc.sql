\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

create or replace function compare_search() returns trigger
volatile strict parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
as $$
begin
    with result (good_id, person_id, interest, query, rerank_distance) as (
        select new.good_id, person_id, interest, query, rerank_distance(query, new.passage)
        from search
        where person_id <> new.giver
        order by (new.embedding <=> search.embedding)
        limit 100
    )
    insert into interest (good_id, person_id, level, origin, query)
    select good_id, person_id, interest, 'automatic', query
    from result
    where rerank_distance < 0;

    return null;
end;
$$ language plpgsql;

create or replace trigger compare_search
after insert or update of title, description on good
for each row
execute procedure compare_search();

create or replace procedure give(_good_id uuid, _receiver uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
with interest as (
    update interest
    set state = 'approved'
    where (good_id, person_id) = (_good_id, _receiver)
)
update good
set receiver = _receiver,
given_at = now()
where good_id = _good_id;
end;

grant execute on procedure give to person;

create or replace procedure want(_good_id uuid, level interest_level, price_ text)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    insert into interest (good_id, person_id, origin, level, price)
    values (_good_id, current_person_id(), 'manual', level, nullif(price_, '')::numeric)
    on conflict (good_id, person_id) do update
        set level = excluded.level,
        price = excluded.price
    ;
end;

grant execute on procedure want(uuid, interest_level, text) to person;

create or replace procedure unwant(_good_id uuid)
language sql
security invoker
set search_path to cpres, pg_catalog
begin atomic
    delete from interest where (good_id, person_id) = (_good_id, current_person_id());
end;
grant execute on procedure unwant to person;

-- alter function http parallel safe;

create or replace procedure mark_late_interests()
language sql
security invoker
set search_path to cpres, pg_catalog
set parallel_setup_cost to 0
set parallel_tuple_cost to 0
begin atomic
    -- with late as (
        update cpres.interest
        set
            state = 'late',
            at = now()
        where at < now() - interval '3 days'
        and state = 'approved';
        -- returning good_id, person_id
    -- ),
    -- detail as (
    --     select push_endpoint
    --     from person_detail
    --     join late using (person_id)
    --     where push_endpoint is not null
    -- )
    -- select http(('POST', push_endpoint,
    --     array[('TTL', 50000)]::http_header[],
    --     'application/json',
    --     jsonb_build_object()
    -- )::http_request)
    -- from detail;
end;
grant execute on procedure mark_late_interests to person;

create or replace function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to cpres, pg_catalog
begin atomic
    with "user" as (
        update person
        set login_challenge = null
        where login_challenge = (current_setting('httpg.query', true)::jsonb->'qs'->>'login_challenge')::uuid
        returning person_id
    )
    select 'set local role to person'
    union all select format('set local "cpres.person_id" to %L', person_id)
    from "user";
end;

grant execute on function login to person;

create or replace function send_login_email(email_ text, location_ text)
returns table ("from" text, "to" text, subject text, plain text, html text)
language sql
volatile parallel safe not leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
    with login_person as (
        insert into person (name, email, login_challenge)
        values (replace($1, '@', '-at-'), $1, gen_random_uuid())
        on conflict (email) do update
            set login_challenge = excluded.login_challenge
        returning *
    ),
    person_detail as (
        insert into person_detail (person_id, location)
        select person_id, nullif(location_, '')::point
        from login_person
        where location_ <> ''
        on conflict (person_id) do update
            set location = excluded.location
    ),
    url as (
        select login_person.*, url(format('https://%s/login', current_setting('httpg.query', true)::jsonb->>'host'), jsonb_build_object(
            'redirect', '/',
            'login_challenge', login_challenge,
            'sql', 'select'
        )) as url
        from login_person
    )
    select 'florian.klein@free.fr', email, '[cpres]: Nouveau lien d''authentification',
        format($$
            Bonjour %s,

            Un nouveau lien d'authentification a été crée pour vous authentifier: %s

            Ignorez ce lien si vous n'êtes pas à l'origine de la demande.

            Cordialement, l'admin.
        $$, name, url),
        xmlconcat(
            xmlelement(name h1, format(_('Bonjour %s'), name)),
            xmlelement(name p, 'Un nouveau lien d''authentification a été crée pour vous authentifier: '),
            xmlelement(name a, xmlattributes(
                url as href
            ), url)
            , xmlelement(name p, 'Ignorez ce lien si vous n''êtes pas a l''origine de la demande.')
            , xmlelement(name p, 'Cordialement, l''admin.')
        )
    from url;
end;

grant execute on function send_login_email(text, text) to person;

