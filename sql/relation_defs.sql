with relation as (
    select r.oid, n.nspname, r.relname,
    jsonb_object_agg(a.attname, jsonb_build_object(
	'escaped_name', quote_ident(a.attname),
	'name', a.attname,
	'type', t.typname,
	'oid', t.oid
    )) cols
    from pg_catalog.pg_class r
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid = r.oid
    join pg_catalog.pg_type t on t.oid = a.atttypid
    where r.relkind = any(array['r', 'v', 'm', 'f', 'p'])
    and a.attnum > 0
    -- and n.nspname = any($1)
    and n.nspname in('public', 'gieze', 'shca')
    group by r.oid, n.nspname, r.relname
),
out_link as (
    with fkey_col(conrelid, confrelid, conname, confkey, conkey) as (
	select c.conrelid, c.confrelid, conname, an.confkey, an.conkey
	from relation r
	join pg_catalog.pg_constraint c on r.oid = c.conrelid,
	unnest(c.confkey, c.conkey) as an (confkey, conkey)
	where contype = 'f'
    ),
    fkey_agg as (
	select c.conrelid, c.confrelid, conname, jsonb_object_agg(a.attname, ra.attname) map
	from fkey_col c
	join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey
	join pg_catalog.pg_attribute ra on ra.attrelid = c.confrelid and ra.attnum = c.confkey
	where a.attnum > 0
	and ra.attnum > 0
	group by 1, 2, 3
    )
    select r.oid, jsonb_object_agg(c.conname, jsonb_build_object(
	'target', format('%I.%I', rn.nspname, rr.relname),
	'attributes', map
    )) out_links
    from fkey_agg c
    join relation r on r.oid = c.conrelid
    join pg_catalog.pg_class rr on c.confrelid = rr.oid
    join pg_catalog.pg_namespace rn on rn.oid = rr.relnamespace
    group by r.oid
),
in_link as (
    with fkey_col(conrelid, confrelid, conname, confkey, conkey) as (
	select c.conrelid, c.confrelid, conname, an.confkey, an.conkey
	from relation r
	join pg_catalog.pg_constraint c on r.oid = c.confrelid,
	unnest(c.confkey, c.conkey) as an (confkey, conkey)
	where contype = 'f'
    ),
    fkey_agg as (
	select c.conrelid, c.confrelid, conname, jsonb_object_agg(a.attname, ra.attname) map
	from fkey_col c
	join pg_catalog.pg_attribute a on a.attrelid = c.confrelid and a.attnum = c.confkey
	join pg_catalog.pg_attribute ra on ra.attrelid = c.conrelid and ra.attnum = c.conkey
	where a.attnum > 0
	and ra.attnum > 0
	group by 1, 2, 3
    )
    select r.oid, jsonb_object_agg(c.conname, jsonb_build_object(
	'target', format('%I.%I', rn.nspname, rr.relname),
	'attributes', map
    )) in_links
    from fkey_agg c
    join relation r on r.oid = c.confrelid
    join pg_catalog.pg_class rr on c.conrelid = rr.oid
    join pg_catalog.pg_namespace rn on rn.oid = rr.relnamespace
    group by r.oid
)
select format('%s.%s', r.nspname, r.relname) fqn,
-- format('%I', r.relname || '_') alias,
-- r.nspname,
-- r.relname,
-- cols,
jsonb_pretty(coalesce(in_links, '{}')) many,
jsonb_pretty(coalesce(out_links, '{}')) one
from relation r
left join out_link using (oid)
left join in_link using (oid)
