do $$ begin
raise info $it$

it renders detailed html of a good
$it$;


set local search_path to cpres, pg_catalog, public;

set local "http.query" to '{}';

insert into cpres.person (person_id, name, email, login_challenge) values (default, '', '', default);
insert into good (title, description, location, giver)
select
    format('good %s %s', name, i),
    format('good %s %s', name, i),
    '(0,0)'::point,
    person_id -- , array[format('https://lipsum.app/id/%s/800x900', i)]
from generate_series(1, 10) i, person
where name <> 'p3';

assert (
    select every(xpath_exists('/div', html::xml))
    from cpres.good_detail
);

assert (
    select xpath_exists('//script', (string_agg(html, '') || '</main></body></html>')::xml)
    from cpres.head
);
rollback;

end $$;

