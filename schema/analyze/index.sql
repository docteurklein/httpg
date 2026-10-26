-- require: url/url.sql
set local search_path to "plan", url, pg_catalog, public;

create schema "plan";


create function query(sql text, params jsonb = '{}'::jsonb)
returns setof record
language plpgsql strict volatile
security definer
as $$
begin
    return query execute sql using params;
end;
$$;

create function explain_html(plan_ jsonb) returns table (status int, header jsonb, body text)
language sql
stable strict parallel safe -- leakproof
security invoker
begin atomic
select 200, null::jsonb, '<!DOCTYPE html>'::text
union all select null, null, xmlelement(name pre, jsonb_pretty(current_setting('httpg.query')::jsonb))::text
union all select null, null, $$
<style>
table {
    width: 100%;
    th, td {
        border: 1px solid grey;
        &.num {
            font-variant-numeric: tabular-nums;
            font-feature-settings: 'tnum';
            text-align: right;
        }
    }
}
</style>
$$
union all (
    with recursive httpg (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    ),
    node (plan, type, cost, time, loops, filtered, depth) as (
        select
            plan_->'Plan',
            plan_->'Plan'->>'Node Type',
            (plan_->'Plan'->'Total Cost')::numeric,
            (plan_->'Plan'->'Actual Total Time')::numeric,
            (plan_->'Plan'->'Actual Loops')::numeric,
            coalesce(plan_->'Plan'->'Rows Removed by Filter', plan_->'Plan'->'Rows Removed by Join Filter')::numeric,
            0
        union all
        select
            sub,
            sub->>'Node Type',
            (sub->'Total Cost')::numeric,
            (sub->'Actual Total Time')::numeric,
            (sub->'Actual loops')::numeric,
            coalesce(sub->'Rows Removed by Filter', sub->'Rows Removed by Join Filter')::numeric,
            depth + 1
        from node,
        jsonb_array_elements(plan->'Plans') sub
    )
    select null, null, xmlelement(name body,
        xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object('sort', query->'qs'->>'sort')) as action
        ),
            xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, format($$
                select * from plan.explain_html($1::jsonb)
            $$, plan_) as value)),
            xmlelement(name textarea, xmlattributes('params[0]' as name), jsonb_pretty(plan_)),
            xmlelement(name input, xmlattributes('submit' as type))
        ),
        xmlelement(name table,
            xmlelement(name thead,
                xmlelement(name tr,
                    xmlelement(name th, xmlelement(name a, xmlattributes(
                        url.url('/query', jsonb_build_object(
                            'sort', 'time',
                            -- 'sql', format('select * from plan.explain_html(%L)', jsonb_pretty(plan_))
                            'sql', query->>'sql'
                        )) as href
                    ), 'time')),
                    xmlelement(name th, xmlelement(name a, xmlattributes(
                        url.url('/query', jsonb_build_object(
                            'sort', 'cost',
                            'sql', query->>'sql'
                        )) as href
                    ), 'cost')),
                    xmlelement(name th, xmlelement(name a, xmlattributes(
                        url.url('/query', jsonb_build_object(
                            'sort', 'loops',
                            'sql', query->>'sql'
                        )) as href
                    ), 'loops')),
                    xmlelement(name th, xmlelement(name a, xmlattributes(
                        url.url('/query', jsonb_build_object(
                            'sort', 'filtered',
                            'sql', query->>'sql'
                        )) as href
                    ), 'filtered')),
                    xmlelement(name th, xmlelement(name a, xmlattributes(
                        url.url('/query', jsonb_build_object(
                            'sort', 'depth',
                            'sql', query->>'sql'
                        )) as href
                    ), 'node'))
                )
            ),
            xmlagg(xmlelement(name tr,
                xmlelement(name td, xmlattributes('num' as class), coalesce(time::text, '')),
                xmlelement(name td, xmlattributes('num' as class), coalesce(cost::text, '')),
                xmlelement(name td, xmlattributes('num' as class), coalesce(loops::text, '')),
                xmlelement(name td, xmlattributes('num' as class), coalesce(filtered::text, '')),
                xmlelement(name td, xmlelement(name details,
                    xmlelement(name summary, repeat('--', depth), type),
                    xmlelement(name pre, jsonb_pretty(plan - 'Plans'))
                ))
            ) order by
                (case when coalesce(query->'qs'->>'sort', 'time') = 'time' then time end) desc,
                (case when query->'qs'->>'sort' = 'cost' then cost end) desc,
                (case when query->'qs'->>'sort' = 'loops' then loops end) desc nulls last,
                (case when query->'qs'->>'sort' = 'filtered' then filtered end) desc nulls last,
                (case when query->'qs'->>'sort' = 'depth' then depth end) asc
            )
        )
    )::text
    from node, httpg
    group by query
);
end;

grant usage on schema plan to anon;
grant execute on function query to anon;
grant execute on function explain_html to anon;
