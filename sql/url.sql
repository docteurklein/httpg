\set ON_ERROR_STOP on

create schema if not exists url;

drop function if exists url.encode cascade;
create or replace function url.encode(value text)
returns text
language sql
immutable strict
begin atomic
  select
    string_agg(
      case
        when ol>1 or ch !~ '[0-9a-za-z:/@._?#-]+' 
          then regexp_replace(upper(substring(ch::bytea::text, 3)), '(..)', E'%\\1', 'g')
        else ch
      end,
      ''
    )
  from (
    select ch, octet_length(ch) as ol
    from regexp_split_to_table(value, '') as ch
  ) as s;
end;

drop function if exists url.url cascade;
create or replace function url.url(path text, params jsonb = '{}')
returns text
language sql
immutable parallel safe -- leakproof
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
    select string_agg(format('%s=%s', path, url.encode(value #>> '{}')), '&')
    from param 
    where value is json scalar
));
end;
