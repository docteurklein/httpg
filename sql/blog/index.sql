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
    select xmlelement(name feed, xmlattributes('http://www.w3.org/2005/Atom' as xmlns),
        xmlelement(name title, 'docteurklein'),
        xmlelement(name link, '/'),
        xmlelement(name id, 'urn:uuid:' || uuidv7()),
        xmlagg(xmlelement(name entry,
            xmlelement(name title, title),
            xmlelement(name link, xmlattributes(url(format('%s://%s/query', scheme, host), jsonb_build_object(
                'sql', 'select content from blog.post where id = $1::uuid',
                'params[]', id
            )) as href)),
            xmlelement(name id, 'urn:uuid:' || id),
            xmlelement(name content, xmlattributes('html' as type), content::xml)
        )
        order by published_at desc)
    )
    from httpg, post
    limit 50
)
select hstore('content-type', 'application/xml'), null
union all
select null, e'<?xml version="1.0" encoding="UTF-8"?>\n'
union all
select null, xmlserialize(document xml as text indent)
from entry
;


grant select on table atom to anon;
