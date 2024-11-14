create or replace view head(html) as
select $html$<!DOCTYPE html>
<html>
<head>
    <style>
        body {
          max-width: 90%;
          margin: auto;
        }
    </style>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" />
</head>
<body>
<script type="module">
    console.log(document);
    document.addEventListener('click', console.log);
</script>
$html$;

create or replace function url_encode (str text) returns text as $$
return encodeURIComponent(String(str))
$$ language plv8;

-- drop function if exists html(text, jsonb, jsonb);
create or replace function html(fqn_ text, r jsonb, qs jsonb = '{}')
returns text
language sql
immutable parallel safe
begin atomic
with hypermedia (hypermedia) as (
    select decorate(fqn, r, pkey, links, qs)
    from rel
    where fqn = fqn_
)
select xmlelement(name card
    , xmlelement(name h3, fqn_)
    , xmlelement(name pre, r)
    , xmlelement(name ul, xmlattributes('order' as class), (
        with link (href, field, value, "order") as (
            select format(
                $$/query?query=table head union all ( select html('%1$s', to_jsonb(r)) from %1$s r order by %2$s %3$s limit 100)&order[%2$s]=%3$s$$,
                fqn_,
                key,
                (case when (qs->>format('order[%s]', key) = 'asc') then 'desc' else 'asc' end)
                -- (select string_agg(format('%s=%s', key, url_encode(value)), '&') from jsonb_each_text(qs) where key ilike 'order[%')
            ),
            key,
            value,
            (case when (qs->>format('order[%s]', key) = 'asc') then 'desc' else 'asc' end)
            from jsonb_each_text(r)
        )
        select xmlagg(
            xmlelement(name li,
                xmlelement(name a, xmlattributes(
                    href as href
                ), format('%s: (order by: %s)', field, "order")),
                xmlelement(name form, xmlattributes('POST' as method, '/query?redirect=' as action),
                    xmlelement(name input, xmlattributes('text' as type, 'params' as name, value)),
                    xmlelement(name textarea, xmlattributes('query' as name), format('update %s set %s = $1 where %s', fqn_, field, hypermedia->>'where')),
                    xmlelement(name input, xmlattributes('submit' as type))
                )
            )
        )
        from link
    ), '')
    , xmlelement(name ul, xmlattributes('hypermedia' as class), (
        select xmlagg(
            xmlelement(name li,
                xmlelement(name a, xmlattributes(
                    format('/query?query=table head union all (%s)&%s', value->>'query', value->>'qs') as href
                ), value->>'fkey'))
        )
        from jsonb_array_elements(hypermedia->'links')
    ), '')
)
from hypermedia;
end;

-- create role web noinherit nologin;
revoke all on schema pg_catalog, public from web, app, public;
revoke all on all tables in schema pg_catalog, public from web, app, public;
revoke all on all functions in schema pg_catalog, public from web, app, public;

grant usage on schema public, pim, pg_catalog to web, app;
grant select on public.rel, public.head to web, app;
-- grant execute on function public.html(rel, jsonb) to web, app;
-- grant execute on function public.html(pim.product, jsonb) to web, app;
-- grant execute on function public.html(pim.product_descendant, jsonb, jsonb) to web, app;

grant select on all tables in schema pim to web, app;

-- grant execute on function pg_catalog.jsonb_each to web;
-- grant execute on function pg_catalog.jsonb_object_fields to web;
-- grant execute on function pg_catalog.xmlagg to web;
-- grant execute on function pg_catalog.format(text, variadic "any") to web;
grant execute on all functions in schema pg_catalog to web, app;
revoke execute on function pg_catalog.pg_sleep from web, app;
