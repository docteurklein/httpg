\set ON_ERROR_STOP on

begin; 

create extension if not exists plv8 schema pg_catalog;

create or replace function public.url_encode (str text)
returns text
immutable strict parallel safe -- leakproof
language plv8
as $$
return encodeURIComponent(String(str))
$$;

create or replace function public.url_decode (str text)
returns text
immutable strict parallel safe -- leakproof
language plv8
as $$
return decodeURIComponent(String(str))
$$;

create or replace function public.url(path text, params jsonb = '{}')
returns text
language sql
immutable strict parallel safe -- leakproof
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

commit;
