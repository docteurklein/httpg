create schema if not exists blog;

set search_path to blog, url, public;

grant usage on schema blog, url, public to anon;
grant execute on function public.hstore(text, text) to anon;
grant execute on function url.url, url.encode to anon;

-- drop table if exists post cascade;
create table if not exists post (
    id uuid primary key default uuidv7(),
    title text not null,
    content text not null,
    published_at timestamptz default now(),
    updated_at timestamptz default now()
);

create index if not exists published on post (published_at) where published_at is not null;

grant select on table post to anon;

alter table post enable row level security;

drop policy if exists "published" on post;
create policy "published" on post for all to anon
using (published_at is not null);

truncate post;
insert into post (title, content, published_at)
select i::text, xmlelement(name h3, 'hello '||i)::text, case when i > 6 then null else now() end
from generate_series(1, 100) i;

-- drop view if exists html cascade;
create or replace view html (id, body)
with (security_invoker)
as with entry (id, xml) as (
    select id, xmlelement(name div,
        xmlelement(name h1, title),
        xmlelement(name article, content::xml)
    )
    from post
)
select id, xml
from entry
;

grant select on table html to anon;

-- drop view if exists blog cascade;
create or replace view head (html)
with (security_invoker)
as
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>docteurklein's blog</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
</head>
$html$;

grant select on table head to anon;

-- drop view if exists blog cascade;
create or replace view blog (html)
with (security_invoker)
as
table head
union all
select body::text
from html
;

grant select on table blog to anon;

-- drop view if exists atom;
create or replace view atom (header, body)
with (security_invoker)
as with httpg (scheme, host) as (
    with q (q) as (
        select current_setting('httpg.query', true)::jsonb
    )
    select q->>'scheme', q->>'host'
    from q
),
entry (xml) as (
    select xmlagg(xmlelement(name entry,
        xmlelement(name title, title),
        xmlelement(name link, xmlattributes(url(format('%s://%s/query', scheme, host), jsonb_build_object(
            'sql', 'select * from blog.head union all select body::text from blog.html where id = $1::uuid',
            'params[]', id
        )) as href)),
        xmlelement(name id, 'urn:uuid:' || id),
        xmlelement(name content, xmlattributes('html' as type), content::xml)
    ) order by published_at desc)
    from httpg, post
    limit 50
),
feed (xml) as (
    select xmlelement(name feed, xmlattributes('http://www.w3.org/2005/Atom' as xmlns),
        xmlelement(name title, 'docteurklein''s blog'),
        xmlelement(name link, url(format('%s://%s/query', scheme, host), jsonb_build_object(
            'sql', 'select * from blog.blog'
        ))),
        xmlelement(name id, 'urn:uuid:019ef8ba-51f7-7b44-a223-e85ddb5bedea'),
        xml
    )
    from entry, httpg
)
select hstore('content-type', 'application/xml'), null
union all
select null, e'<?xml version="1.0" encoding="UTF-8"?>\n'
union all
select null, xmlserialize(document xml as text indent)
from feed
;


grant select on table atom to anon;
