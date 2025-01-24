drop view if exists head;
create or replace view head(html) as
select $html$<!DOCTYPE html>
<html>
<head>
    <style>
        body {
          max-width: 90%;
          margin: auto;
        }
        .menu {
            //display: flex;
            //flex-wrap: wrap;
            //gap: 1rem 2rem;
        }
    </style>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" />
</head>
<body>
<script type="module">
    console.log(document);
    document.addEventListener('click', console.log);
</script>
$html$
union all select $html$
<form method="POST" action="/login">
  <fieldset class="grid">
    <input type="text" name="user" />
    <input type="password" name="password" />
    <input type="submit" value="login" />
  </fieldset>
</form>
$html$
where current_role = 'anon'
union all select xmlelement(name ul, xmlattributes('menu' as class), (
    select xmlagg(
        xmlelement(name li,
            xmlelement(name a, xmlattributes(
                format(
                    $sql$/query?sql=table head union all ( select html('%1$s', to_jsonb(r), $2) from %1$s r limit 100)$sql$,
                    fqn
                ) as href
            ), fqn)
            -- , xmlelement(name a, xmlattributes(
            --     format(
            --         $sql$/query?sql=table head union all ( select html('%1$s', to_jsonb(r), $2) from %1$s r limit 100)$sql$,
            --         fqn
            --     ) as href,
            --     'portal-' || fqn as target
            -- ), 'in iframe')
            -- , xmlelement(name iframe, xmlattributes(
            --     'portal-' || fqn as name
            -- ), '')
            )
        )
        from rel
    ), '')::text
    where current_role <> 'anon'
;

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
        with link (href, field, value, sort) as (
            select format('/query?%s', (
                select string_agg(format('%s=%s', key, url_encode(value)), '&')
                from jsonb_each_text(qs || jsonb_build_object(
                    'order', key,
                    'sort', (case when (qs->>'sort' = 'asc') then 'desc' else 'asc' end)
                ))
            )),
            key,
            value,
            (case when (qs->>'sort' = 'asc') then 'desc' else 'asc' end)
            from jsonb_each_text(r)
        )
        select xmlagg(
            xmlelement(name li,
                xmlelement(name form, xmlattributes('POST' as method, '/query?redirect=referer' as action),
                    xmlelement(name fieldset, xmlattributes('grid' as class),
                        xmlelement(name a, xmlattributes(
                            href as href
                        ), format('%s: (order by: %s)', field, sort)),
                        xmlelement(name input, xmlattributes('text' as type, 'params[]' as name, value)),
                        xmlelement(name textarea, xmlattributes('sql' as name), format('update %s set %s = $1->>0 where %s', fqn_, field, hypermedia->>'where')),
                        xmlelement(name input, xmlattributes('submit' as type, 'update' as value))
                    )
                )
            )
        )
        from link
    ), '')
    , xmlelement(name ul, xmlattributes('hypermedia' as class), (
        select xmlagg(
            xmlelement(name li,
                xmlelement(name a, xmlattributes(
                    format($$/query?sql=table head union all (select html('%1$s', to_jsonb(r), $2) from %1$s r where %s limit 100)&%s$$, value->>'target', value->>'crit', value->>'qs') as href
                ), value->>'fkey')
                -- , xmlelement(name a, xmlattributes(
                --     format($$/query?sql=table head union all (select html('%1$s', to_jsonb(r), $2) from %1$s r where %s limit 100)&%s$$, value->>'target', value->>'crit', value->>'qs') as href,
                --     format('%s-%s', value ->>'fkey', value->>'qs') as target
                -- ), 'in iframe')
                -- , xmlelement(name iframe, xmlattributes(
                --     format('%s-%s', value ->>'fkey', value->>'qs') as name
                -- ), '')
            )
        )
        from jsonb_array_elements(hypermedia->'links')
    ), '')
)
from hypermedia;
end;

-- create role web noinherit nologin;
-- revoke all on schema pg_catalog, public from web, app, public;
-- revoke all on all tables in schema pg_catalog, public from web, app, public;
-- revoke all on all functions in schema pg_catalog, public from web, app, public;

grant usage on schema public, pg_catalog to web, app;
grant select on public.rel, public.head to web, app, anon;
grant execute on function public.html(text, jsonb, jsonb) to web, app;
grant execute on function public.url_encode(text) to web, app;
grant execute on function public.decorate(text, jsonb, jsonb, jsonb, jsonb) to web, app;
-- grant execute on function public.html(pim.product, jsonb) to web, app;
-- grant execute on function public.html(pim.product_descendant, jsonb, jsonb) to web, app;

grant select, insert, update on all tables in schema pim to web, app;

-- grant execute on function pg_catalog.jsonb_each to web;
-- grant execute on function pg_catalog.jsonb_object_fields to web;
-- grant execute on function pg_catalog.xmlagg to web;
-- grant execute on function pg_catalog.format(text, variadic "any") to web;
grant execute on all functions in schema pg_catalog to web, app, public;
revoke execute on function pg_catalog.pg_sleep from web, app;
