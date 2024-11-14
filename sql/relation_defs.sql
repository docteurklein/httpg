-- drop function if exists decorate(text, jsonb, jsonb, jsonb, jsonb);
create or replace function decorate(rel text, record jsonb, pkey jsonb, links jsonb, qs_ jsonb = '{}')
returns jsonb 
language sql
immutable parallel safe
begin atomic
    with link (direction, fkey, details) as (
        select value->'direction', key, value from jsonb_each(links)
    ),
    crit (direction, fkey, crit, qs, fields, params) as (
        select direction, fkey,
            format('(%s) = (%s)', string_agg(quote_ident(key), ', ' order by ordinality), string_agg(format('$%s', ordinality), ', ' order by ordinality)),
            string_agg(format('params=%s', url_encode(record->>value)), '&' order by ordinality),
            array_agg(key order by key),
            array_agg(record->>value order by ordinality) filter (where record->>value is not null)
        from link, jsonb_each_text(details->'attributes') with ordinality
        group by direction, fkey
    ),
    query (direction, fkey, query, crit, qs, fields, params) as (
        select direction, fkey,
        format($sql$
select html('%1$s', to_jsonb(r)) 
from %1$s r 
where %2$s 
limit 100
$sql$, details->>'target', crit),
        crit,
        qs, fields, params
        from crit
        join link using (direction, fkey)
        where cardinality(params) = cardinality(fields)
    ),
    pkey (pkey) as (
        select array_agg(record->>value order by value)
        from jsonb_array_elements_text(pkey)
    ),
    where_ (where_) as (
        select format('(%s) = (%s)', string_agg(quote_ident(value), ', '), string_agg(quote_literal(record->>value), ', '))
        from jsonb_array_elements_text(pkey)
    )
    select jsonb_build_object(
        'record', record,
        'pkey', pkey,
        'where', where_,
        'rel', rel,
        'links', coalesce(jsonb_agg(to_jsonb(q)), '[]')
    )
    from query q, pkey, where_
    group by pkey, where_
    ;
end;

drop materialized view if exists rel cascade;
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
        'name', a.attname,
        'type', t.typname
    )) cols,
    jsonb_agg(distinct a.attname) filter (where i.indisprimary) pkey
    from pg_catalog.pg_class r
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid = r.oid
    left join pg_index i
        on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    join pg_catalog.pg_type t on t.oid = a.atttypid
    left join view_col vc on r.oid in (vc.from, vc.resorigtbl)
    where r.relkind = any(array['v', 'r', 'm', 'f', 'p'])
    and i.indrelid = r.oid
    and a.attnum > 0
    and n.nspname <> all(array['pg_catalog', 'information_schema'])
    group by vc.resorigtbl, r.oid, n.nspname, r.relname
),
link as (
    with fkey_col(direction, conrelid, confrelid, conname, attrelid, attnum, ratrel) as (
        select 'out', c.conrelid, c.confrelid, format('out: %s', conname), c.conrelid, an.conkey, (c.confrelid, an.confkey)
        from relation r
        join pg_catalog.pg_constraint c on r.conrelid = c.conrelid,
        unnest(c.confkey, c.conkey) as an (confkey, conkey)
        where contype = 'f'
      union all
        select 'in', c.confrelid, c.conrelid, format('in: %s', conname), c.confrelid, an.confkey, (c.conrelid, an.conkey)
        from relation r
        join pg_catalog.pg_constraint c on r.conrelid = c.confrelid,
        unnest(c.confkey, c.conkey) as an (confkey, conkey)
        where contype = 'f'
    ),
    fkey_agg as (
        select c.direction, c.conrelid, c.confrelid, conname, jsonb_object_agg(ra.attname, a.attname) map
        from fkey_col c
        join pg_catalog.pg_attribute a using (attrelid, attnum)
        join pg_catalog.pg_attribute ra on (ra.attrelid, ra.attnum) = c.ratrel
        where a.attnum > 0
        and ra.attnum > 0
        group by 1, 2, 3, 4
    )
    select r.conrelid, jsonb_object_agg(c.conname, jsonb_build_object(
        'target', format('%I.%I', rn.nspname, rr.relname),
        'attributes', map,
        'direction', direction
    )) links
    from fkey_agg c
    join relation r on r.oid = c.confrelid
    join pg_catalog.pg_class rr on c.conrelid = rr.oid
    join pg_catalog.pg_namespace rn on rn.oid = rr.relnamespace
    group by 1
)
select format('%s.%s', r.nspname, r.relname) fqn,
r.nspname,
r.relname,
cols,
pkey,
coalesce(links, '{}') links
from relation r
left join link using (conrelid)
;

