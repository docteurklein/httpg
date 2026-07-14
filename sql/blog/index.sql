create schema if not exists blog;

set search_path to blog, url, public;

create extension if not exists hstore schema public cascade;
grant usage on schema blog, url, public to anon;
grant execute on function public.hstore(text, text) to anon;
grant execute on function url.url, url.encode to anon;

-- drop table if exists post cascade;
create table if not exists post (
    post_id uuid primary key default uuidv7(),
    title text not null,
    content text not null,
    language regconfig not null default 'english',
    fts tsvector not null generated always as (
        setweight(to_tsvector(language::regconfig, title), 'A') ||
        setweight(to_tsvector(language::regconfig, content), 'B')
    ) stored,
    published_at timestamptz default now(),
    updated_at timestamptz default null
);

create index if not exists fts on post using gin (fts);
create index if not exists published on post (published_at) where published_at is not null;

grant select on table post to anon;

alter table post enable row level security;

drop policy if exists "published" on post;
create policy "published" on post for all to anon
using (published_at is not null);

-- drop table if exists comment cascade;
create table if not exists comment (
    comment_id uuid primary key default uuidv7(),
    author text not null,
    constraint "only non-empty author" check (trim(author) <> '' and length(author) <= 100),
    content text not null,
    constraint "only non-empty comment" check (trim(content) <> '' and length(content) <= 10000),
    language regconfig not null default 'english',
    fts tsvector not null generated always as (
        setweight(to_tsvector('simple', author), 'A') ||
        setweight(to_tsvector(language::regconfig, content), 'B')
    ) stored,
    post_id uuid not null references post (post_id) on delete cascade,
    published_at timestamptz default now(),
    approved_at timestamptz default null
);

create index if not exists fts on comment using gin (fts);
create index if not exists post_id on comment (post_id);

grant select, insert on table comment to anon;

alter table comment enable row level security;

drop policy if exists "moderated" on comment;
create policy "moderated" on comment for all to anon
using ((
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select case when query->'qs' ? 'include_unmoderated' or comment.comment_id = coalesce(query->'qs'->>'comment_id', query->'body'->'params'->>0)::uuid
        then true
        else approved_at is not null
    end
    from query
))
with check (true);

create or replace function random_string(int)
returns text
as $$
    with corpus (corpus) as (
        select 'you are some cool person and I really like you abcdefghijklmnopqrstuvwxyz          '
    )
    select array_to_string(array(
        select substring(corpus from (random() * length(corpus))::int for 5)
        from corpus, generate_series(1, $1)
    ), '')
$$ language sql;

-- truncate post cascade;
-- insert into post (title, content, published_at)
-- select i::text, xmlelement(name p, random_string(random(200, 1000)))::text, case when i > 6 then null else now() end
-- from generate_series(1, 100) i;

-- insert into comment (author, content, post_id)
-- select format('example%s@example.org', i), xmlconcat(
--     xmlelement(name h3, 'comment '||i),
--     random_string(random(20, 100))::xml,
--     xmlelement(name script, 'alert(1)'),
--     xmlelement(name iframe, xmlattributes('https://wikipedia.fr' as src), ''),
--     xmlelement(name base, xmlattributes('https://wikipedia.fr' as href)),
--     xmlelement(name form, xmlattributes('https://wikipedia.fr' as action), xmlelement(name input, xmlattributes('submit' as type))),
--     xmlelement(name div,
--         xmlelement(name script, 'alert(2)'),
--         xmlelement(name style, 'body {color: red !important;}'),
--         xmlelement(name h4, 'sub h4 '||i)
--     ),
--     xmlelement(name p, 'test')
-- )::text, post_id
-- from generate_series(1, 5) i, post;

-- drop view if exists comment_html cascade;
create or replace view comment_html (post_id, comment_id, body)
with (security_invoker)
as with httpg (qs) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select
        query->'qs'
    from query
)
select post_id, comment_id, xmlelement(name article, xmlattributes('card' as class),
    xmlelement(name address, format('%s (%s)', author, published_at)),
    case when qs ? 'search'
        then xmlelement(name pre, ts_headline(language, xmltext(content)::text, websearch_to_tsquery(language, qs->'params'->>0), 'MaxFragments=100,FragmentDelimiter="<br/>[...]<br/>",MaxWords=10,MinWords=2')::xml)
        else xmltext(content)
    end
)
from comment, httpg
;

grant select on table comment_html to anon;


-- drop view if exists error cascade;
create or replace view error (target, html)
with (security_invoker)
as
with httpg (error, qs) as (
    select
        nullif(current_setting('httpg.errors', true), '')::jsonb->>'error',
        nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
),
c (attname, conname) as (
    select attname, conname::text
    from httpg, pg_constraint c
    join pg_attribute a on (a.attnum = any(c.conkey) and a.attrelid = c.conrelid)
    where conname = substring(error, 'violates check constraint "([^"]+)"')
    and connamespace = 'blog'::regnamespace
),
all_ (target, msg) as (
    table c
    union all
    select null, error
    from httpg
    where error is not null
)
select target, xmlelement(name article, xmlattributes(
    'card error' as class
),
    msg
)::text
from all_
where msg is not null;

grant select on table error to anon;

-- drop view if exists post_html cascade;
create or replace view post_html (post_id, title, body)
with (security_invoker)
as with httpg (qs, params, comment_id) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select
        query->'qs',
        query->'body'->'params',
        (query->'qs'->>'comment_id')::uuid
    from query
),
entry (post_id, title, xml) as (
    select post_id, title, xmlelement(name div,
        xmlelement(name article, xmlattributes('card' as class),
            xmlelement(name span, published_at::date),
            xmlelement(name a, xmlattributes(
                url('/blog/query', jsonb_build_object(
                    'sql', 'select * from blog.head union all select body::text from blog.post_html where title = $1',
                    'params[]', title
                )) || '#title' as href
            ),
                xmlelement(name h2, xmlattributes('title' as id), post.title)
            ),
            case when qs ? 'search'
                then xmlelement(name pre, ts_headline(post.language, post.content, websearch_to_tsquery(post.language, qs->'params'->>0), 'MaxFragments=100,FragmentDelimiter="<br/>[...]<br/>",MaxWords=10,MinWords=2')::xml)
                else post.content::xml
            end,
            xmlelement(name hr),
            xmlelement(name h4, xmlattributes('comments' as id), 'Comments'),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                '/blog/query#comments' as action
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    $$
                        insert into blog.comment (comment_id, author, content, post_id) values ($1::uuid, $2, $3, $4::uuid)
                        returning 303 status, hstore('Location', url.url('/blog/query', jsonb_build_object(
                            'sql', 'select * from blog.head union all select body::text from blog.post_html where post_id = $1::uuid',
                            'params[0]', post_id,
                            'comment_id', comment_id
                        )) || '#comments') header
                    $$ as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'on_error' as name,
                    'select * from blog.head union all select body::text from blog.post_html where post_id = $4::uuid' as value
                )),
                (select html::xml from error where target = 'author'),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'params[0]' as name,
                    'author' as placeholder,
                    coalesce(params->>0, uuidv7()::text) as value
                )),
                xmlelement(name input, xmlattributes(
                    'text' as type,
                    'params[1]' as name,
                    'author' as placeholder,
                    params->>1 as value
                )),
                (select html::xml from error where target = 'content'),
                xmlelement(name textarea, xmlattributes(
                    'params[2]' as name,
                    'comment' as placeholder,
                    7 as rows
                ), coalesce(params->>2, '')),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'params[3]' as name,
                    post_id as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'Comment' as value
                ))
            ),
            xmlelement(name a, xmlattributes(
                url('/blog/query', jsonb_build_object(
                    'sql', 'select * from blog.head union all select body::text from blog.post_html where title = $1',
                    'params[]', title,
                    'include_unmoderated', null
                )) || '#comments' as href
            ), 'Include unmoderated'),
            xmlelement(name div, xmlattributes('messages' as class), (
                select xmlagg(body order by published_at desc)
                from comment
                join comment_html c using (comment_id)
                where c.post_id = post.post_id
                and case when qs ? 'search'
                    then fts @@ websearch_to_tsquery(comment.language, qs->'params'->>0)
                    else true
                end
            ))
        )
    )
    from httpg, post
    -- group by post_id
)
select post_id, title, xml
from entry
;

grant select on table post_html to anon;

create or replace function search(query text)
returns setof text
security invoker
stable strict parallel safe
language sql
begin atomic
    select body::text
    from blog.post
    join blog.post_html using (post_id)
    where post.fts @@ websearch_to_tsquery(post.language, $1)
    or exists(
        select from blog.comment
        where comment.fts @@ websearch_to_tsquery(comment.language, $1)
        and comment.post_id = post.post_id
    );
end;

grant execute on function search to anon;
-- drop materialized view if exists ts_stat cascade;
create materialized view if not exists ts_stat (word, nentry, ratio)
as
    select word, nentry, nentry::numeric / max(nentry) over ()
    from ts_stat('select fts from blog.post')
;

grant select on table ts_stat to anon;

-- drop view if exists head cascade;
create or replace view head (html) as select null; -- to allow resolution of self-depending 'head'::regclass
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
    <meta http-equiv="Content-Security-Policy" content="
        default-src 'self';
        base-uri 'self';
        form-action 'self';
        style-src
            'self'
            'unsafe-inline'
        ;
    " />
    <link rel="stylesheet" href="/cpres/index.css?v=4" />
    <link rel="alternate" type="application/atom+xml"  title="Atom feed of blog posts"  href="/query?sql=select * from blog.atom" />
    <link rel="alternate" type="application/atom+xml"  title="Atom feed of comments"  href="/query?sql=select * from blog.atom_comment" />
    <style>
        pre:has(code) {
            max-height: 50vh;
            min-width: 100%;
            overflow: auto;
            white-space: pre;

            & code {
                border: 0;
            }
        }

        code {
            border: 1px solid grey;
            padding: 3px;
        }

         frea
    </style>
</head>
$html$
union all
select xmlelement(name nav, xmlelement(name ul,
    xmlelement(name li, xmlelement(name a, xmlattributes(
        url('/blog/query', jsonb_build_object(
            'sql', 'select * from blog.blog'
        )) as href
    ),
        xmlelement(name h1, 'docteurklein''s blog')
    )),
    xmlelement(name li, xmlelement(name a, xmlattributes(
        url('/blog/query', jsonb_build_object(
            'sql', 'select * from blog.atom'
        )) as href,
        'application/atom+xml' as type,
        'alternate' as rel
     ),
        'Atom feed of blog posts'
    )),
    xmlelement(name li, xmlelement(name a, xmlattributes(
        url('/blog/query', jsonb_build_object(
            'sql', 'select * from blog.atom_comment'
        )) as href,
        'application/atom+xml' as type,
        'alternate' as rel
     ),
        'Atom feed of comments'
    ))
))::text
union all
    select html from error where target is null
union all (
    with httpg (qs) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
    ),
    form (html) as (
        select xmlelement(name form, xmlattributes(
            'GET' as method,
            '/blog/query' as action
        ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                format($$
                select * from %s
                union all
                select * from %s($1)
                $$, 'head'::regclass, 'blog.search') as value
            )),
            xmlelement(name input, xmlattributes(
                'search' as type,
                'params[0]' as name,
                'query' as placeholder,
                case when qs ? 'search' then qs->'params'->>0 end as value
        
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'search' as name
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                'Search' as value
            ))
        )
        from httpg
    ),
    cloud (html) as (
        select xmlelement(name ul, xmlattributes('cloud' as class),
            xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
                url('/blog/query', jsonb_build_object(
                    'sql', 'select * from blog.head union all select * from blog.search($1)',
                    'params[]', word,
                    'search', null
                )) as href,
                format('font-size: calc(%s * 1ch', least(5, greatest(1, ratio * 4))) as style
            ),
                format('%s (%s)', word, nentry)
            ))
        ))
        from (
            with top as (
                select *
                from ts_stat
                order by nentry desc
                limit 5
            ),
            rand as (
                select *
                from ts_stat
                where not exists (select from top where ts_stat.word = top.word)
                order by random()
                limit 5
            )
            table top
            union all
            table rand
            order by word            
        )
    )
    select xmlelement(name div, xmlattributes('grid' as class),
        xmlelement(name div, form.html),
        cloud.html
    )::text
    from form, cloud
);

grant select on table head to anon;

-- drop view if exists blog cascade;
create or replace view blog (html)
with (security_invoker)
as table head
union all
select xmlelement(name a, xmlattributes(
    url('/blog/query', jsonb_build_object(
        'sql', 'select * from blog.head union all select body::text from blog.post_html where title = $1',
        'params[]', title
    )) || '#title' as href
),
    xmlelement(name h2, format('%s: %s', published_at::date, title))
)::text
from post
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
            'sql', 'select * from blog.head union all select body::text from blog.post_html where title = $1',
            'params[]', title
        )) as href)),
        xmlelement(name id, 'urn:uuid:' || post_id),
        xmlelement(name content, xmlattributes('html' as type), content)
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
select hstore('content-type', 'application/atom+xml'), null
union all
select null, e'<?xml version="1.0" encoding="UTF-8"?>\n'
union all
select null, xmlserialize(document xml as text indent)
from feed
;


grant select on table atom to anon;

-- drop view if exists atom_comment;
create or replace view atom_comment (header, body)
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
        xmlelement(name title, format('%s commented on %s', author, title)),
        xmlelement(name link, xmlattributes(url(format('%s://%s/query', scheme, host), jsonb_build_object(
            'sql', 'select * from blog.head union all select body::text from blog.post_html where title = $1',
            'params[]', post.title
        )) as href)),
        xmlelement(name id, 'urn:uuid:' || comment_id),
        xmlelement(name content, xmlattributes('html' as type), xmltext(comment.content)::text)
    ) order by comment.published_at desc)
    from httpg, comment
    join post using (post_id)
    limit 50
),
feed (xml) as (
    select xmlelement(name feed, xmlattributes('http://www.w3.org/2005/Atom' as xmlns),
        xmlelement(name title, 'Comments on docteurklein''s blog'),
        xmlelement(name link, url(format('%s://%s/query', scheme, host), jsonb_build_object(
            'sql', 'select * from blog.blog'
        ))),
        xmlelement(name id, 'urn:uuid:019ef8ba-51f7-7b44-a223-e85ddb5bedeb'),
        xml
    )
    from entry, httpg
)
select hstore('content-type', 'application/atom+xml'), null
union all
select null, e'<?xml version="1.0" encoding="UTF-8"?>\n'
union all
select null, xmlserialize(document xml as text indent)
from feed
;


grant select on table atom_comment to anon;
