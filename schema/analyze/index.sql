-- require: url/url.sql

create extension if not exists pg_stat_statements;

drop schema if exists plan cascade;
create schema "plan";

set local search_path to "plan", url, pg_catalog, public;

create function exec(sql text)
returns setof record
language plpgsql strict volatile
security definer
as $$
begin
    return query execute sql;
exception when others then
    return next row(jsonb_build_object('error', sqlerrm)::json);
end;
$$;

create function explain_html(query_ text default null, queryid_ bigint default null) returns table (status int, header jsonb, body text)
language sql
stable parallel safe -- leakproof
security definer
begin atomic
with recursive httpg (query) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb
),
stat_statement (query) as (
    select format('explain (format json, verbose, costs, plan_advice, generic_plan) %s', query)
    from pg_stat_statements
    where queryid_ = queryid limit 1
),
plan (plan, error) as materialized (
    select plans::jsonb->0, plans->>'error'
    from exec(coalesce(query_, (select query from stat_statement))) _(plans json)
    union all
    select (query->'qs'->>'plan')::jsonb->0, null
    from httpg
    where nullif(query->'qs'->>'plan', '') is not null
),
node (plan, type, name, parent_id, id, cost, time, loops, planned_rows, actual_rows, row_ratio, filtered, wal_bytes, shared_read_blocks, shared_hit_blocks, temp_written_blocks, path, depth) as (
    select
        plan->'Plan',
        plan->'Plan'->>'Node Type',
        coalesce(plan->'Plan'->>'Alias', plan->'Plan'->>'Subplan Name', plan->'Plan'->>'CTE Name', plan->'Plan'->>'Index Name'),
        null,
        format('%s', row_number() over ()),
        (plan->'Plan'->'Total Cost')::numeric,
        (plan->'Plan'->'Actual Total Time')::numeric,
        (plan->'Plan'->'Actual Loops')::int,
        (plan->'Plan'->'Plan Rows')::numeric,
        (plan->'Plan'->'Actual Rows')::int,
        round((plan->'Plan'->'Plan Rows')::numeric / greatest((plan->'Plan'->'Actual Rows')::int, 1), 2),
        coalesce(plan->'Plan'->'Rows Removed by Filter', plan->'Plan'->'Rows Removed by Join Filter')::numeric,
        (plan->'Plan'->'WAL Bytes')::int,
        (plan->'Plan'->'Shared Read Blocks')::int,
        (plan->'Plan'->'Shared Hit Blocks')::int,
        (plan->'Plan'->'Temp Written Blocks')::int,
        '{}'::bigint[],
        0
        from plan
        where error is null
    union all
    select
        sub,
        sub->>'Node Type',
        coalesce(sub->>'Alias', sub->>'Subplan Name', sub->>'CTE Name', sub->>'Index Name'),
        id, 
        format('%s_%s', id, row_number() over ()),
        (sub->'Total Cost')::numeric,
        (sub->'Actual Total Time')::numeric,
        (sub->'Actual loops')::int,
        (sub->'Plan Rows')::numeric,
        (sub->'Actual Rows')::int,
        round((sub->'Plan Rows')::numeric / greatest((sub->'Actual Rows')::int, 1), 2),
        coalesce(sub->'Rows Removed by Filter', sub->'Rows Removed by Join Filter')::numeric,
        (sub->'WAL Bytes')::int,
        (sub->'Shared Read Blocks')::int,
        (sub->'Shared Hit Blocks')::int,
        (sub->'Temp Written Blocks')::int,
        path || array[row_number() over ()],
        depth + 1
    from node,
    jsonb_array_elements(plan->'Plans') sub
)
select 200, null::jsonb, '<!DOCTYPE html>'::text
-- union all select null, null, xmlelement(name pre, jsonb_pretty(current_setting('httpg.query')::jsonb))::text -- debug
union all select null, null, $$
<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Dosis">
<style>

body, textarea, pre {
    font-family: 'Dosis', serif;
}

* {
  box-sizing: border-box;
}

.error {
    background-color: indianred;
    padding: .1rem;
}

:root {
    interpolate-size: allow-keywords;
    scroll-padding-top: 4rem;
}
table {
    tbody {
        tr:has(details[open]) {
            background-color: #e1f3d2;
        }
        tr:nth-child(odd) {
            background-color: #eee;
        }
        tr:target {
          background-color: yellow;
        }
    }

    width: 100%;
    thead {
        & * {
            background-color: #cee5ea;
            opacity: .8;
        }
        top: 0px;
        position: sticky;
    }
    th {
        overflow: hidden;
        max-width: 3vw;
    }
    td {
        max-width: min-content;
        &.node {
            max-width: 66vw;
        }
        &.num {
            font-variant-numeric: tabular-nums;
            font-feature-settings: 'tnum';
            text-align: right;
        }
    }
}

textarea {
    width: 100%;
}

details {
    & pre {
        max-height: 40vh;
        max-width: 66vw;
        overflow: scroll;
        text-wrap: wrap;
        overflow-wrap: break-word;
    }
    &::details-content {
      transition: opacity 1s;
      opacity: 0;
    }
    
    &[open]::details-content {
      opacity: 1;
    }
}
</style>
$$
union all select null, null, xmlelement(name form, xmlattributes(
    'GET' as method,
    '/query' as action
),
    xmlelement(name input, xmlattributes('hidden' as type, 'use_primary' as name)),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$select * from plan.explain_html(nullif($1, ''))$$ as value
    )),
    xmlelement(name textarea, xmlattributes('params[0]' as name, 7 as rows),
        coalesce(
            query_,
            (select query from stat_statement),
            case when queryid_ is null then 'explain (format json, analyze, timing, costs, buffers, io, verbose, plan_advice) ' end
        ), ''
    )
    -- , xmlelement(name label, 'stat_statements', xmlelement(name select, xmlattributes('params[1]' as name),
    --     xmlelement(name option, xmlattributes(''as value)),
    --     (select xmlagg(xmlelement(name option, xmlattributes(
    --         s.queryid as value,
    --         case when queryid_ = s.queryid then 'selected' end as selected
    --     ), query) order by max_exec_time) from pg_stat_statements s),
    --     ''
    -- )),
    , xmlelement(name input, xmlattributes('submit' as type))
)::text
from httpg
union all select null, null, xmlelement(name div, xmlattributes('error' as class),
    xmlelement(name pre, error)
)::text
from plan
where error is not null
union all select null, null, xmlelement(name details,
    xmlelement(name summary, 'raw'),
    xmlelement(name textarea, xmlattributes(20 as rows), jsonb_pretty(plan), ''), ''
)::text
from plan
where error is null
union all
select null, null, xmlelement(name table, xmlattributes('1' as border),
    xmlelement(name thead,
        xmlelement(name tr,
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'time',
                    'sql', query->>'sql'
                )) as href
            ), 'time', case when query->'qs'->>'sort' = 'time' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'cost',
                    'sql', query->>'sql'
                )) as href
            ), 'cost', case when query->'qs'->>'sort' = 'cost' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'loops',
                    'sql', query->>'sql'
                )) as href
            ), 'loops', case when query->'qs'->>'sort' = 'loops' then '▼' end)),
            xmlelement(name th,
                xmlelement(name a, xmlattributes(
                    url.url('/query', query->'qs' || jsonb_build_object(
                        'sort', 'rows',
                        'sql', query->>'sql'
                    )) as href
                ), 'rows', case when query->'qs'->>'sort' = 'rows' then '▼' end),
                ' / ',
                xmlelement(name a, xmlattributes(
                    url.url('/query', query->'qs' || jsonb_build_object(
                        'sort', 'bad_row_estim',
                        'sql', query->>'sql'
                    )) as href
                ), 'bad estim', case when query->'qs'->>'sort' = 'bad_row_estim' then '▼' end)
            ),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'filtered',
                    'sql', query->>'sql'
                )) as href
            ), 'filtered', case when query->'qs'->>'sort' = 'filtered' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'wal_bytes',
                    'sql', query->>'sql'
                )) as href
            ), 'WAL Bytes', case when query->'qs'->>'sort' = 'wal_bytes' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'shared_read_blocks',
                    'sql', query->>'sql'
                )) as href
            ), 'read blocks', case when query->'qs'->>'sort' = 'shared_read_blocks' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'temp_written_blocks',
                    'sql', query->>'sql'
                )) as href
            ), 'temp written blocks', case when query->'qs'->>'sort' = 'temp_written_blocks' then '▼' end)),
            xmlelement(name th, xmlelement(name a, xmlattributes(
                url.url('/query', query->'qs' || jsonb_build_object(
                    'sort', 'node',
                    'sql', query->>'sql'
                )) as href
            ), 'node', case when coalesce(query->'qs'->>'sort', 'node') = 'node' then '▲' end))
        )
    ),
    xmlagg(xmlelement(name tr, xmlattributes(id),
        xmlelement(name td, xmlattributes('num' as class), coalesce(time::text, '')),
        xmlelement(name td, xmlattributes('num' as class), coalesce(cost::text, '')),
        xmlelement(name td, xmlattributes('num' as class), coalesce(loops::text, '')),
        xmlelement(name td, xmlattributes('num' as class), format('%s/%s (%sx)', actual_rows, planned_rows, row_ratio)),
        xmlelement(name td, xmlattributes('num' as class), coalesce(filtered::text, '')),
        xmlelement(name td, xmlattributes('num' as class), coalesce(wal_bytes::text, '')),
        xmlelement(name td, xmlattributes('num' as class), format('%s (%s hits)', shared_read_blocks, shared_hit_blocks)),
        xmlelement(name td, xmlattributes('num' as class), coalesce(temp_written_blocks::text, '')),
        xmlelement(name td, xmlattributes('node' as class),
            xmlelement(name details,
                xmlelement(name summary, repeat('--', depth), format('%s: %s', type, name)),
                case when parent_id is not null then xmlelement(name a, xmlattributes(format('#%s', parent_id) as href), 'parent') end,
                xmlelement(name pre, jsonb_pretty(plan - 'Plans'))
            )
        )
    ) order by
        (case when coalesce(query->'qs'->>'sort', 'time') = 'time' then time end) desc,
        (case when query->'qs'->>'sort' = 'cost' then cost end) desc,
        (case when query->'qs'->>'sort' = 'loops' then loops end) desc nulls last,
        (case when query->'qs'->>'sort' = 'bad_row_estim' then row_ratio end) desc nulls last,
        (case when query->'qs'->>'sort' = 'rows' then actual_rows end) desc nulls last,
        (case when query->'qs'->>'sort' = 'filtered' then filtered end) desc nulls last,
        (case when query->'qs'->>'sort' = 'wal_bytes' then wal_bytes end) desc nulls last,
        (case when query->'qs'->>'sort' = 'shared_read_blocks' then shared_read_blocks end) desc nulls last,
        (case when query->'qs'->>'sort' = 'temp_written_blocks' then temp_written_blocks end) desc nulls last,
        (case when query->'qs'->>'sort' = 'node' then path end) asc
    )
)::text
from node, httpg
group by query
union all select null, null, xmlelement(name hr)::text
union all
select null, null, xmlelement(name table, xmlattributes('1' as border, 'pg_stat_statements' as class),
    xmlagg(xmlelement(name tr,
        xmlelement(name td, xmlelement(name a, xmlattributes(
            url.url('/query', jsonb_build_object(
                'sql', $$select * from plan.explain_html(null, nullif($1, '')::bigint)$$,
                'params[0]', queryid,
                'use_primary', null
            )) as href
        ), queryid))
        , xmlelement(name td, query)
        , xmlelement(name td, max_exec_time)
        , xmlelement(name td, calls)
    ) order by max_exec_time desc)
)::text
from pg_stat_statements
;
end;

grant usage on schema plan to anon;
grant execute on function exec to anon;
grant execute on function explain_html to anon;
