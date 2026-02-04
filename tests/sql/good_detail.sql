do $$
declare current_person_id uuid;
begin
raise info $it$

it renders detailed html of a good
$it$;

set local search_path to cpres, pg_catalog, public;

insert into cpres.person (person_id, name, email, login_challenge) values (default, 'user1', 'user1@example.org', default)
    returning person_id into current_person_id;

perform set_config('cpres.person_id', current_person_id::text, true);

insert into good (title, description, location, giver)
select
    format('good %s %s', name, i),
    format('good %s %s', name, i),
    '(0,0)'::point,
    person_id
from generate_series(1, 10) i, person
where name <> 'p3';

set local "httpg.query" to '{"accept_language": "en-US,"}';
set local role to person;

assert (
-- raise info '%', (
    select every(xpath_exists('/article', html::xml))
    -- select string_agg(html, '')
    from cpres.good_detail
-- );
), 'has div tags';

assert (
-- raise info '%', (
    select xpath_exists('//script', ((string_agg(html, '')) || '</html>')::xml)
    -- select string_agg(html, '')
    from cpres.head
-- );
), 'has script tag';

-- raise info '%', (select current_person_id());
assert (
-- raise info '%', (
    select
        -- string_agg(html, '')
        xpath_exists('//text()[contains(., "Welcome ")]', ((string_agg(html, ' ')) || '</html>')::xml)
    from cpres.head
)
, 'has welcome message';

set local "httpg.query" to '{"accept_language": "fr-FR,"}';

assert (
-- raise info '%', (
    select
        -- string_agg(html, '')
        xpath_exists('//text()[contains(., "Bienvenue ")]', ((string_agg(html, ' ')) || '</html>')::xml)
    from cpres.head
)
, 'has welcome message';

rollback;

end $$;

