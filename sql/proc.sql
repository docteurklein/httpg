\set ON_ERROR_STOP on

set local search_path to cpres, url, pg_catalog, public;

create or replace function compare_search() returns trigger
volatile strict parallel safe -- leakproof
security definer
set search_path to cpres, url, pg_catalog
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
        set login_challenge = case when challenge_used_at < now() - interval '1 hour'
            then null
            else login_challenge
        end,
        challenge_used_at = coalesce(challenge_used_at, now())
        where login_challenge = (current_setting('httpg.query', true)::jsonb->'qs'->>'login_challenge')::uuid
        returning person_id
    )
    select 'set local role to person'
    union all select format('set local "cpres.person_id" to %L', person_id)
    from "user";
end;

grant execute on function login to person;

create or replace function send_login_email(email_ text, location_ text, push_endpoint_ text)
returns table ("from" text, "to" text, subject text, plain text, html text)
language sql
volatile parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
    with login_person as (
        insert into person (name, email, login_challenge)
        values (replace($1, '@', '-at-'), $1, gen_random_uuid())
        on conflict (email) do update
            set login_challenge = excluded.login_challenge,
                challenge_used_at = null
        returning *
    ),
    person_detail as (
        insert into person_detail (person_id, location, push_endpoint)
        select person_id, nullif(location_, '')::point, nullif(push_endpoint_, '')::jsonb
        from login_person
        on conflict (person_id) do update
            set location = excluded.location,
                push_endpoint = excluded.push_endpoint
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

            Ce lien sera valide 1 heure.
            Ignorez ce lien si vous n'êtes pas à l'origine de la demande.

            Cordialement, l'admin.
        $$, name, url),
        xmlconcat(
            xmlelement(name h1, format(_('Bonjour %s'), name)),
            xmlelement(name p, 'Un nouveau lien d''authentification a été crée pour vous authentifier: '),
            xmlelement(name a, xmlattributes(
                url as href
            ), url)
            , xmlelement(name p, 'Ce lien sera valide 1 heure.')
            , xmlelement(name p, 'Ignorez ce lien si vous n''êtes pas a l''origine de la demande.')
            , xmlelement(name p, 'Cordialement, l''admin.')
        )
    from url;
end;

grant execute on function send_login_email(text, text, text) to person;

drop function if exists web_push(uuid, text, text);
create or replace function web_push(person_id_ uuid, title text, content text, path text)
returns table (endpoint text, p256dh text, auth text, content bytea)
language sql
volatile parallel safe -- leakproof
security definer -- bypass RLS to access other's person_detail
set search_path to cpres, pg_catalog
begin atomic
    select
        push_endpoint->>'endpoint',
        push_endpoint->'keys'->>'p256dh',
        push_endpoint->'keys'->>'auth',
        jsonb_build_object(
            'title', title,
            'content', content,
            'path', path
        )::text::bytea
    from person_detail
    where person_id = person_id_
    and push_endpoint is not null
    and exists (select from person where person_id = nullif(current_setting('cpres.person_id', true), '')::uuid);
end;

grant execute on function web_push(uuid, text, text, text) to person;

drop function if exists web_push_message(uuid, text);

create or replace function web_push_message(message_id_ uuid, to_ uuid)
returns table (endpoint text, p256dh text, auth text, content bytea)
language sql
volatile parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
select p.*
from message m
join person author on m.author = author.person_id,
web_push(
    to_,
    format(
        _('New message from %s'),
        author.name
    ),
    content,
    url('/query', jsonb_build_object(
        'sql', format('table head union all table %I', case m.author
            when m.person_id then 'giving activity' -- author is the one interested, so we show message to giver
            else 'receiving activity' end
        )
    )) || '#' || message_id
) p
where m.message_id = message_id_;
end;

grant execute on function web_push_message(uuid, uuid) to person;

create or replace function web_push_gift(good_id_ uuid, receiver_id_ uuid)
returns table (endpoint text, p256dh text, auth text, content bytea)
language sql
volatile parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
select p.*
from interest
join good on (good.good_id = interest.good_id)
join person giver on good.giver = giver.person_id,
web_push(
    interest.person_id,
    format(
        _('%s gave you %s'),
        giver.name,
        good.title
    ),
    null,
    url('/query', jsonb_build_object(
        'sql', 'table head union all table "receiving activity"'
    )) || '#' || good.title
) p
where (interest.good_id, interest.person_id) = (good_id_, receiver_id_);
end;

grant execute on function web_push_gift(uuid, uuid) to person;

create or replace function web_push_want(good_id_ uuid, receiver_id_ uuid)
returns table (endpoint text, p256dh text, auth text, content bytea)
language sql
volatile parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
begin atomic
select p.*
from interest
join good on (good.good_id = interest.good_id)
join person receiver on interest.person_id = receiver.person_id,
web_push(
    good.giver,
    format(
        _('%s is interested by %s'),
        receiver.name,
        good.title
    ),
    null,
    url('/query', jsonb_build_object(
        'sql', 'table head union all table "giving activity"'
    )) || format('#%s-%s', good.good_id, receiver.person_id)
) p
where (interest.good_id, interest.person_id) = (good_id_, receiver_id_);
end;

grant execute on function web_push_want(uuid, uuid) to person;
