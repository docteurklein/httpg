-- drop function decorate(text, jsonb, text, jsonb, jsonb);
create or replace function decorate(rel text, record jsonb, query_format text, pkey jsonb, in_links jsonb, out_links jsonb)
returns jsonb 
language sql
immutable parallel safe
begin atomic
    with link (direction, fkey, details) as (
        select 'in', key, value from jsonb_each(in_links)
        union all select 'out', key, value from jsonb_each(out_links)
    ),
    crit (direction, fkey, crit, fields, params) as (
        select direction, fkey,
            format('(%s) = (%s)', string_agg(quote_ident(key) || '::text', ', ' order by ordinality), string_agg('$' || ordinality, ', ' order by ordinality)),
            array_agg(key order by key),
            array_agg(record->>value order by ordinality) filter (where record->>value is not null)
        from link, jsonb_each_text(details->'attributes') with ordinality
        -- where record->key is not null
        group by direction, fkey
    ),
    query (direction, fkey, query, fields, params) as (
        select direction, fkey,
        format(coalesce(query_format, '
select r, %L
from %s r
where %s
limit 10'), details->>'target', details->>'target', crit),
        fields, params
        from crit
        join link using (direction, fkey)
        where cardinality(params) = cardinality(fields)
    ),
    pkey (pkey) as (
        select array_agg(record->>value order by value) -- filter (where record->>value is not null)
        from jsonb_array_elements_text(pkey)
    )
    select jsonb_build_object(
        'record', record,
        'pkey', pkey,
        'rel', rel,
        'links', coalesce(jsonb_agg(to_jsonb(q)), '[]')
    )
    from query q, pkey
    group by pkey
    ;
end;

-- prepare ps1 as 
drop materialized view if exists rel;
create materialized view rel as
with recursive view_dep (nspname, "from", oid, ev_action) as (
    select n.nspname, v.oid, v.oid, rw.ev_action
    from pg_rewrite rw
    join pg_class v on rw.ev_class = v.oid
    join pg_depend d on rw.oid = d.objid
    join pg_namespace n on n.oid = v.relnamespace
    where v.relkind in ('v', 'm')
    and d.deptype in ('i', 'n')
    and d.classid = 'pg_rewrite'::regclass
    and d.refclassid = 'pg_class'::regclass
    and n.nspname <> all(array['pg_catalog', 'information_schema'])
union all
    select view_dep.nspname, view_dep.from, d.refobjid, rw.ev_action
    from view_dep
    join pg_rewrite rw on rw.ev_class = view_dep.oid
    join pg_class v on v.oid = view_dep.oid
    join pg_depend d on rw.oid = d.objid
    join pg_class t on t.oid = d.refobjid
    where v.relkind in ('v', 'r', 'f', 'm', 'p')
    and d.deptype in ('i', 'n')
    and d.classid = 'pg_rewrite'::regclass
    and d.refclassid = 'pg_class'::regclass
    and d.refobjid <> v.oid
),
tl(nspname, "from", oid, resno, resorigtbl, resorigcol) as (
    select v.nspname, v.from::regclass, v.oid::regclass, (tl->'resno')::int, (tl->>'resorigtbl')::oid::regclass, (tl->'resorigcol')::int
    from view_dep v
    cross join jsonb_array_elements(replace(replace(replace(replace(replace(replace(replace(
                                    regexp_replace(replace(replace(replace(replace(replace(
                                    replace(replace(replace(replace(replace(replace(
          ev_action,
           '<>'              , '()'
        ), ','               , ''
        ), E'\\{'            , ''
        ), E'\\}'            , ''
        ), ' :targetList '   , ',"targetList":'
        ), ' :resno '        , ',"resno":'
        ), ' :resorigtbl '   , ',"resorigtbl":'
        ), ' :resorigcol '   , ',"resorigcol":'
        ), '{'               , '{ :'
        ), '(('              , '{(('
        ), '({'              , '{({'
        ), ' :[^}{,]+'       , ',"":'              , 'g'
        ), ',"":}'           , '}'
        ), ',"":,'           , ','
        ), '{('              , '('
        ), '{,'              , '{'
        ), '('               , '['
        ), ')'               , ']'
        ), ' '               , ','
    )::jsonb->0->'targetList') tl
    where (tl->>'resorigtbl')::int <> 0
),
view_col as (
    select distinct tl.from, sa.attname, tl.resorigtbl, da.attname
    from tl
    join pg_class d on tl.resorigtbl = d.oid
    join pg_attribute sa on tl.from = sa.attrelid and tl.resno = sa.attnum
    join pg_attribute da on tl.resorigtbl = da.attrelid and tl.resorigcol = da.attnum
),
relation as (
    select r.oid, coalesce(vc.resorigtbl, r.oid) conrelid, n.nspname, r.relname,
    jsonb_object_agg(a.attname, jsonb_build_object(
        'escaped_name', quote_ident(a.attname),
        'name', a.attname,
        'type', t.typname,
        'oid', t.oid
    )) cols,
    jsonb_agg(a.attname) filter (where i.indisprimary) pkey
    from pg_catalog.pg_class r
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid = r.oid
    left join pg_index i
        on a.attrelid = i.indrelid and a.attnum = ANY(i.indkey)
    join pg_catalog.pg_type t on t.oid = a.atttypid
    left join view_col vc on r.oid = vc.from
    where r.relkind = any(array['v', 'r', 'm', 'f', 'p'])
    and i.indrelid = r.oid
    and a.attnum > 0
    and n.nspname <> all(array['pg_catalog', 'information_schema'])
    group by vc.resorigtbl, r.oid, n.nspname, r.relname
),
out_link as (
    with fkey_col(conrelid, confrelid, conname, confkey, conkey) as (
        select c.conrelid, c.confrelid, conname, an.confkey, an.conkey
        from relation r
        join pg_catalog.pg_constraint c on r.conrelid = c.conrelid,
        unnest(c.confkey, c.conkey) as an (confkey, conkey)
        where contype = 'f'
    ),
    fkey_agg as (
        select c.conrelid, c.confrelid, conname, jsonb_object_agg(ra.attname, a.attname) map
        from fkey_col c
        join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey
        join pg_catalog.pg_attribute ra on ra.attrelid = c.confrelid and ra.attnum = c.confkey
        where a.attnum > 0
        and ra.attnum > 0
        -- and ra.attname <> 'tenant'
        group by 1, 2, 3
    )
    select r.conrelid, jsonb_object_agg(c.conname, jsonb_build_object(
        'target', format('%I.%I', rn.nspname, rr.relname),
        'attributes', map
    )) out_links
    from fkey_agg c
    join relation r on r.oid = c.conrelid
    join pg_catalog.pg_class rr on c.confrelid = rr.oid
    join pg_catalog.pg_namespace rn on rn.oid = rr.relnamespace
    group by r.conrelid
),
in_link as (
    with fkey_col(conrelid, confrelid, conname, confkey, conkey) as (
        select c.conrelid, c.confrelid, conname, an.confkey, an.conkey
        from relation r
        join pg_catalog.pg_constraint c on r.conrelid = c.confrelid,
        unnest(c.confkey, c.conkey) as an (confkey, conkey)
        where contype = 'f'
    ),
    fkey_agg as (
        select c.conrelid, c.confrelid, conname, jsonb_object_agg(ra.attname, a.attname) map
        from fkey_col c
        join pg_catalog.pg_attribute a on a.attrelid = c.confrelid and a.attnum = c.confkey
        join pg_catalog.pg_attribute ra on ra.attrelid = c.conrelid and ra.attnum = c.conkey
        where a.attnum > 0
        and ra.attnum > 0
        -- and ra.attname <> 'tenant'
        group by 1, 2, 3
    )
    select r.conrelid, jsonb_object_agg(c.conname, jsonb_build_object(
        'target', format('%I.%I', rn.nspname, rr.relname),
        'attributes', map
    )) in_links
    from fkey_agg c
    join relation r on r.oid = c.confrelid
    join pg_catalog.pg_class rr on c.conrelid = rr.oid
    join pg_catalog.pg_namespace rn on rn.oid = rr.relnamespace
    group by r.conrelid
)
select format('%s.%s', r.nspname, r.relname) fqn,
format('%I', r.relname || '_') alias,
r.nspname,
r.relname,
cols,
pkey,
coalesce(in_links, '{}') in_links,
coalesce(out_links, '{}') out_links
from relation r
left join out_link using (conrelid)
left join in_link using (conrelid)
;

