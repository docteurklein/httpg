create extension if not exists plv8 schema pg_catalog;

-- drop function if exists html(text, jsonb, jsonb, jsonb);
create or replace function html(fqn_ text, r jsonb, query jsonb = '{}', errors jsonb = '{}')
returns text
language sql
immutable parallel safe -- leakproof
begin atomic
select xmlconcat(
    xmlelement(name pre, jsonb_pretty(query)), -- debug
(with hypermedia (hypermedia, pkey, cols) as (
    select decorate(fqn, r, pkey, links, query), pkey, cols
    from rel
    where fqn = fqn_
)
select xmlelement(name div
    , xmlelement(name h3, (select string_agg(r->>value, ' ') from jsonb_array_elements_text(pkey)))
    , xmlelement(name ul, xmlattributes('order' as class), (
        with link (href, field, value) as (
            select url('/query', query->'qs' || jsonb_build_object(
                'sql', coalesce(query->'qs'->>'rootsql', query->'qs'->>'sql'),
                'order', jsonb_build_object(
                    coalesce(query->'qs'->>'rel', 'r'), jsonb_build_object(
                        key, case query->'order'->(coalesce(query->'qs'->>'rel', 'r'))->>key
                            when 'asc' then 'desc'
                            else 'asc'
                        end
                    )
                )
            )),
            key,
            value
            from jsonb_each_text(r)
        ),
        params (params) as (
            select xmlagg(
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'params[]' as name,
                    r->>value as value
                ))
            )
            from hypermedia, jsonb_array_elements_text(pkey)
        )
        select xmlagg(
            xmlelement(name li,
                xmlelement(name form, xmlattributes('POST' as method, url('/query', jsonb_build_object(
                        'field', field,
                        'rootsql', coalesce(query->'qs'->>'rootsql', query->'qs'->>'sql')
                    )) as action),
                    xmlelement(name fieldset, xmlattributes('grid' as class),
                        xmlelement(name input, xmlattributes(
                            'hidden' as type,
                            'redirect' as name,
                            coalesce(query->>'redirect', 'referer') as value
                        )),
                        xmlelement(name a, xmlattributes(
                            href as href
                        ), field),
                        params.params,
                        xmlelement(name input, xmlattributes(
                            hypermedia.cols->(link.field)->>'html_type' as type,
                            'params[]' as name,
                            case query->'qs'->>'field' when field
                                then coalesce(query->'params'->>0, value) else value
                            end as value,
                            case when errors ? 'error' and errors->>'field' = field
                                then 'true'
                            end as "aria-invalid",
                            'invalid-helper' as "aria-describedby"
                        )),
                        case when errors ? 'error' and errors->>'field' = field
                            then xmlelement(name small, xmlattributes('invalid-helper' as id), errors->>'error')
                        end,
                        xmlelement(name input, xmlattributes(
                            'hidden' as type,
                            'on_error' as name,
                            format($sql$
                                select html from head
                                union all
                                select html(
                                    %1$L,
                                    to_jsonb(r),
                                    current_setting('httpg.query', true)::jsonb,
                                    current_setting('httpg.errors', true)::jsonb || jsonb_build_object(
                                        'field', '%3$s'
                                    )
                                )
                                from %1$s r
                                where %2$s
                                $sql$, fqn_, hypermedia->>'where', field
                            ) as value
                        )),
                        xmlelement(name input, xmlattributes('submit' as type, 'update' as value))
                    ),
                    xmlelement(name fieldset, xmlattributes('grid' as class),
                        xmlelement(name details,
                            xmlelement(name summary, 'sql'),
                            xmlelement(name textarea, xmlattributes('sql' as name), format(
                                $sql$update %s set %s = nullif($%s, '')::%s where %s$sql$,
                                fqn_,
                                field,
                                jsonb_array_length(pkey) + 1,
                                hypermedia.cols->(link.field)->>'type',
                                hypermedia->>'where'
                            ))
                        )
                    )
                )
            )
        )
        from link, params
    ), '')
    , xmlelement(name ul, xmlattributes('hypermedia' as class), (
        select xmlagg(
            xmlelement(name li,
                xmlelement(name a, xmlattributes(
                    format($$/query?sql=select html from head union all (select html('%1$s', to_jsonb(r), current_setting('httpg.query')::jsonb) from %1$s r where %s limit 100)&%s$$, value->>'target', value->>'crit', value->>'qs') as href
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
revoke all on all tables in schema pg_catalog, public, pim from web, app, public;
revoke all on all routines in schema pg_catalog, public, pim from web, app, public;

grant usage on schema public, pim, pg_catalog to web, app, anon;
grant select on public.rel, public.head to web, app, anon;
grant select on all tables in schema pim to web, app, anon;
grant execute on function public.html(text, jsonb, jsonb, jsonb) to web, app, anon;
grant execute on function public.url(text, jsonb) to web, app, anon;
grant execute on function url.encode(text) to web, app, anon;
grant execute on function public.decorate(text, jsonb, jsonb, jsonb, jsonb) to web, app, anon;

grant select, insert, update on all tables in schema pim to web, app;

grant select on pg_ts_config to pim, web, app;
-- grant execute on function pg_catalog.jsonb_object_fields to web;
-- grant execute on function pg_catalog.xmlagg to web;
-- grant execute on function pg_catalog.format(text, variadic "any") to web;
grant execute on all functions in schema pg_catalog, pim to web, app, anon;
revoke execute on function pg_catalog.pg_sleep from web, app, anon;
