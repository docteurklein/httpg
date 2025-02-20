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
                    $$/query?sql=select * from head union all ( select html('%1$s', to_jsonb(r), current_setting('httpg.query')::jsonb) from %1$s r limit 100)$$,
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

create or replace function url(path text, params jsonb = '{}')
returns text
language sql
immutable strict parallel safe leakproof
begin atomic
select format('%s?%s', path, (
    with recursive param(path, value) as (
        select key, value
        from jsonb_each(params)
        union all (
            with _param as (select * from param)
            select format('%s[%s]', path, key), c.value
            from _param, jsonb_each(value) c
            where _param.value is json object
            union all
            select format('%s[]', path), c.value
            from _param, jsonb_array_elements(value) c
            where _param.value is json array
        )
    )
    select string_agg(format('%s=%s', path, url_encode(value #>> '{}')), '&')
    from param 
    where value is json scalar
));
end;

create or replace function url_decode (str text)
returns text
immutable strict parallel safe leakproof
language plv8
as $$
return decodeURIComponent(String(str))
$$;

-- drop function if exists html(text, jsonb, jsonb, jsonb);
create or replace function html(fqn_ text, r jsonb, query jsonb = '{}', errors jsonb = '{}')
returns text
language sql
immutable parallel safe leakproof
begin atomic
-- select xmlconcat(
--     xmlelement(name pre, jsonb_pretty(r)), -- debug
((with hypermedia (hypermedia, pkey, cols) as (
    select decorate(fqn, r, pkey, links, query), pkey, cols
    from rel
    where fqn = fqn_
)
select xmlelement(name card
    , xmlelement(name h3, (select string_agg(r->>value, ' ') from jsonb_array_elements_text(pkey)))
    , xmlelement(name ul, xmlattributes('order' as class), (
        with link (href, field, value) as (
            select url('/query', query || jsonb_build_object(
                'order', jsonb_build_object(
                    coalesce(query->>'rel', 'r'), jsonb_build_object(
                        key, case query->'order'->(coalesce(query->>'rel', 'r'))->>key
                            when 'asc' then 'desc'
                            else 'asc'
                        end
                    )
                )
            )),
            key,
            value
            from jsonb_each_text(r)
        )
        select xmlagg(
            xmlelement(name li,
                xmlelement(name form, xmlattributes('POST' as method, format('/query?redirect=%s', coalesce(query->>'redirect', 'referer')) as action),
                    xmlelement(name details,
                        xmlelement(name summary, 'sql'),
                        xmlelement(name textarea, xmlattributes('sql' as name), format(
                            $sql$update %s set %s = nullif($1, '')::%s where %s$sql$,
                            fqn_,
                            field,
                            hypermedia.cols->(link.field)->>'type',
                            hypermedia->>'where'
                        ))
                    ),
                    xmlelement(name fieldset, xmlattributes('grid' as class),
                        xmlelement(name a, xmlattributes(
                            href as href
                        ), field),
                        xmlelement(name input, xmlattributes(
                            'text' as type,
                            'params[]' as name,
                            value,
                            case when errors ? 'error' and errors->>'field' = field then 'true' end as "aria-invalid",
                            'invalid-helper' as "aria-describedby"
                        )),
                        case when errors ? 'error' and errors->>'field' = field then xmlelement(name small, xmlattributes('invalid-helper' as id), errors->>'error') end,
                        xmlelement(name input, xmlattributes('hidden' as type, 'on_error' as name, format(
                            $sql$
                            select * from head
                            union all
                            select html(
                                %1$L,
                                to_jsonb(r),
                                current_setting('httpg.query')::jsonb,
                                current_setting('httpg.errors')::jsonb || jsonb_build_object(
                                    'field', '%3$s'
                                )
                            )
                            from %1$s r
                            where %2$s
                            $sql$, fqn_, hypermedia->>'where', field) as value)),
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
                    format($$/query?sql=select * from head union all (select html('%1$s', to_jsonb(r), current_setting('httpg.query')::jsonb) from %1$s r where %s limit 100)&%s$$, value->>'target', value->>'crit', value->>'qs') as href
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
from hypermedia));
end;

-- create role web noinherit nologin;
revoke all on schema pg_catalog, public, pim from web, app, public;
revoke all on all tables in schema pg_catalog, public from web, app, public;
revoke all on all routines in schema pg_catalog, public, pim from web, app, public;

grant usage on schema public, pim to web, app, anon;
grant select on public.rel, public.head to web, app, anon;
grant select on all tables in schema pim to web, app, anon;
grant execute on function public.html(text, jsonb, jsonb, jsonb) to web, app, anon;
grant execute on function public.url(text, jsonb) to web, app, anon;
grant execute on function public.url_encode(text) to web, app, anon;
grant execute on function public.decorate(text, jsonb, jsonb, jsonb, jsonb) to web, app, anon;

grant select, insert, update on all tables in schema pim to web, app;

grant select on pg_ts_config to pim, web, app;
-- grant execute on function pg_catalog.jsonb_object_fields to web;
-- grant execute on function pg_catalog.xmlagg to web;
-- grant execute on function pg_catalog.format(text, variadic "any") to web;
grant execute on all functions in schema pg_catalog, pim to web, app, anon;
revoke execute on function pg_catalog.pg_sleep from web, app, anon;
