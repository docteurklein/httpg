do $$
begin
raise info $it$

it translates text
$it$;

set local search_path to cpres, pg_catalog, public;

-- insert into translation (id, lang, text) values
--   ('Welcome ', 'fr', 'Bienvenue ')
-- , ('a little interested', 'fr', 'un peu')
-- ;

set local "httpg.query" to '{"accept_language": "fr-FR,"}';

assert _('Welcome ') = 'Bienvenue ', 'has translation';

set local "httpg.query" to '{"accept_language": "en-US,"}';

assert _('no') = 'no', 'has fallback on key';

assert _('Welcome ', 'fr') = 'Bienvenue ', 'override lang';

rollback;

end $$;

