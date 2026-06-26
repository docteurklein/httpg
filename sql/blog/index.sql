create schema if not exists blog;

set search_path to blog, url, public;

grant usage on schema blog, url, public to anon;
grant execute on function public.hstore(text, text) to anon;
grant execute on function url.url, url.encode to anon;

-- drop table if exists post cascade;
create table if not exists post (
    post_id uuid primary key default uuidv7(),
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

-- drop table if exists comment cascade;
create table if not exists comment (
    comment_id uuid primary key default uuidv7(),
    author text not null check (trim(author) <> ''),
    content text not null check (length(content) <= 10000 and trim(content) <> ''),
    post_id uuid not null references post (post_id) on delete cascade,
    published_at timestamptz default now()
);

create index if not exists post_id on comment (post_id);

grant select, insert on table comment to anon;

truncate post cascade;
insert into post (title, content, published_at)
select i::text, xmlelement(name h3, 'hello '||i)::text, case when i > 6 then null else now() end
from generate_series(1, 100) i;

insert into comment (author, content, post_id)
select 'example@example.org', xmlconcat(
    xmlelement(name h3, 'comment '||i),
    xmlelement(name script, 'alert(1)'),
    xmlelement(name iframe, xmlattributes('https://wikipedia.fr' as src), ''),
    xmlelement(name base, xmlattributes('https://wikipedia.fr' as href)),
    xmlelement(name form, xmlattributes('https://wikipedia.fr' as action), xmlelement(name input, xmlattributes('submit' as type))),
    xmlelement(name div,
        xmlelement(name script, 'alert(2)'),
        xmlelement(name style, 'body {color: red !important;}'),
        xmlelement(name h4, 'sub h4 '||i)
    ),
    xmlelement(name p, 'test')
)::text, post_id
from generate_series(1, 5) i, post;

-- drop view if exists post_html cascade;
create or replace view post_html (post_id, body)
with (security_invoker)
as with entry (post_id, xml) as (
    select post_id, xmlelement(name div,
        xmlelement(name article, xmlattributes('card' as class),
            xmlelement(name h2, post.title),
            post.content::xml,
            xmlelement(name hr),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                '/blog/query' as action
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'insert into blog.comment (author, content, post_id) values ($1, $2, $3::uuid)' as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'on_error' as name,
                    'select * from blog.blog' as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'redirect' as name,
                    url('/blog/query', jsonb_build_object('sql', 'select * from blog.blog')) as value
                )),
                xmlelement(name input, xmlattributes(
                    'text' as type,
                    'params[0]' as name,
                    'author' as placeholder
                )),
                xmlelement(name textarea, xmlattributes(
                    'params[1]' as name,
                    'comment' as placeholder
                ), ''),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'params[2]' as name,
                    post_id as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'Comment' as value
                ))
            ),
            xmlelement(name div, xmlattributes('messages' as class), xmlagg(
                xmlelement(name article, xmlattributes('card' as class),
                    comment.content,
                    -- (
                    --     with recursive n (comment_id, n, i, ordinality) as (
                    --         select comment_id, r.n, 0, ordinality
                    --         from unnest(xpath('/root/*[name() != ''script'']', xmlelement(name root, comment.content::xml))) with ordinality r(n)
                    --         union all
                    --         select comment_id, c.n, i + 1, c.ordinality
                    --         from n, unnest(xpath('/root/*/child::*[name() != ''script'']', xmlelement(name root, n.n))) with ordinality c(n)
                    --         -- where i < 20
                    --     )
                    --     select xmlagg(n.n order by i, ordinality)
                    --     from n
                    --     group by comment_id
                    --     -- order by i, ordinality
                    -- )),
                    xmlelement(name address, comment.author)
                )
                order by comment.published_at
            ))
        )
    )
    from post
    left join comment using (post_id)
    group by post_id
)
select post_id, xml
from entry
;

grant select on table post_html to anon;

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
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; base-uri 'self'; form-action 'self'; " />
    <link rel="stylesheet" href="/cpres/index.css?v=4" />
</head>
$html$;

grant select on table head to anon;

-- drop view if exists blog cascade;
create or replace view blog (html)
with (security_invoker)
as
with httpg (error) as (
    select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
table head
union all
select xmlelement(name h1, 'docteurklein''s blog')::text
union all
select xmlelement(name article, xmlattributes(
    'card error' as class
), coalesce(
    pg_get_constraintdef((
        select oid
        from pg_constraint
        where conname = substring(error, 'violates check constraint "(\w+)"')
    )),
    error
))::text
from httpg
where error is not null
union all
select body::text
from post_html
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
            'sql', 'select * from blog.head union all select body::text from blog.post_html where post_id = $1::uuid',
            'params[]', post_id
        )) as href)),
        xmlelement(name id, 'urn:uuid:' || post_id),
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
