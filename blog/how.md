
Using SQL. Yes, I know.
Did you know that postgres is fun?

Afer using [postgREST](https://docs.postgrest.org/en/v14/) for years, I wanted to see if I could make something even more flexible,
by [exposing SQL](#:~:text=you%20say) as the sole way to handle hypermedia content.  

### httpg

So I built [httpg](https://github.com/docteurklein/httpg/), a rust app that sits between the browser and postgres.  
It's a small [axum](https://docs.rs/axum/latest/axum/) http server that:
- extracts parameters from HTTP requests
- injects them in the session
- `SET LOCAL ROLE` based on [encrypted cookies](https://www.biscuitsec.org/)
- execute a parametrized statement with `$1`, `$2`, ... being the request's `&params[]=&params[]=...`
- decodes status code, headers and body from SQL results.

It sends the response as a non-blocking stream, so `union all` queries allow to send the headers before the body is done processing, improving TFFB.

It separates reads from writes, each with its own connection pool.

- A `GET /query` request will execute in a read-only transaction targeting read replicas
- A `POST /query` will open a `SERIALIZABLE` one on the primary and retry if necessary

In addtion to `params`, The transaction receives a setting named `httpg.query`, whose contract is:

```rust
#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct Query {
    pub sql: String,
    pub cookies: BTreeMap<String, String>,
    #[serde(skip)]
    pub params: Vec<Param>,
    #[serde(skip)]
    pub files: Vec<File>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
    pub scheme: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept_language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub qs: serde_json::Map<String, serde_json::Value>,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub body: serde_json::Map<String, serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub use_primary: Option<String>,
}
```

It allows me to write server-side rendered HTML (or json or anything) using views, Set-Returning Functions and procedures.

### Forms

Here is a simple form that inserts comments for a blog post:

```sql
with httpg (qs, params, comment_id) as (
    with query (query) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb
    )
    select
        query->'qs',
        query->'body'->'params',
        (query->'qs'->>'comment_id')::uuid
    from query
)
select xmlelement(name form, xmlattributes(
    'POST' as method,
    '/blog/query' as action
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
            ))) header
        $$ as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from blog.head union all select body::text from blog.post_html where post_id = $4::uuid' as value
    )),
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
)
from httpg
```

By composing views, procedures and functions, I can handle this entire blog, atom feed, full text search and comments,  
in a few hundreds lines of code,  
without having to leave my beloved `psql` prompt.  

[See for yourself!](https://github.com/docteurklein/httpg/blob/main/sql/blog/index.sql)

### File uploads

Requests whose `Content-Type` is `multipart/form-data` pass the file as a `bytea[content, type, name]` array in `$1`:

```sql
select xmlelement(name form, xmlattributes(
    'POST' as method,
    '/cpres/query' as action,
    'multipart/form-data' as enctype
),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'redirect' as name,
        'referer' as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        format($$
            with f (f) as (
                select $1::bytea[]
            )
            insert into cpres.good_media (good_id, name, content, content_type)
            select %L, convert_from(f[3], 'UTF8'), f[1], convert_from(f[2], 'UTF8')
            from f
            where f[1] <> ''
            on conflict (good_id, content_hash) do nothing
        $$, good_id) as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        coalesce(q->'body'->>'on_error', q->'qs'->>'sql', 'select * from cpres.head union all select html from cpres."good admin"') as value
    )),
    xmlelement(name input, xmlattributes(
        'file' as type,
        'file' as name,
        'required' as required
        -- true as multiple
    )),
    xmlelement(name input, xmlattributes(
        'submit' as type,
        _('Add file') as value
    ))
)
```

### Full text search

The DDL includes a `STORED` generated column of type `tsvector`, weighting title and content:

```sql
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
    updated_at timestamptz default now()
);

create index if not exists fts on post using gin (fts);
```

A SRF is used for querying:

```sql
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
```

#### Word cloud

The word cloud is generated using `ts_stat`:

```sql
select xmlelement(name ul, xmlattributes('cloud' as class),
    xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
        url('/blog/query', jsonb_build_object(
            'sql', 'select * from blog.head union all select * from blog.search($1)',
            'params[]', word,
            'search', null
        )) as href,
        format('font-size: calc(%s * 1ch', least(2, nentry::float)) as style
    ),
        format('%s (%s)', word, nentry)
    ))
))
from (
    with stat as (
        select * from ts_stat('select fts from blog.post')
    ),
    top as (
        select word, nentry
        from stat
        order by nentry desc
        limit 5
    ),
    rand as (
        select word, nentry
        from stat
        where not exists (select from top where stat.word = top.word)
        order by random()
        limit 5
    )
    table top
    union table rand
)
```

### Exposing SQL you say?

It is known to not expose SQL to a public network. How crazy would it be?!

By exploiting postgres role and permission system, `statement_timeout` (and stuff), Row-Level policies and an [sql parser](https://github.com/apache/datafusion-sqlparser-rs) upstream,
we can limit the attack surface to a potentially manageable level.

#### An allow-list of statements

Using the afformentioned datafusion's sqlparser, we can write a visitor to refuse some statements:

```rust
pub struct AllowList(pub Result<(), HttpgError>);

impl Visitor for AllowList {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        self.0 = match expr {
            Expr::Function(Function { name, ..}) if name.to_string() == "set_config" => Err(HttpgError::RefusedSql {
                query: expr.to_string(),
                reason: Some("illegal set_config".to_string()),
            }),
            _ => Ok(()),
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_statement(&mut self, statement: &Statement) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*statement,
              Statement::Query(_)
            | Statement::Call(_)
            | Statement::Insert(_)
            | Statement::Update(_)
            | Statement::Delete(_)
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: statement.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*query.body,
              SetExpr::Select(_)
            | SetExpr::Values(_)
            | SetExpr::Insert(_)
            | SetExpr::Update(_)
            | SetExpr::Delete(_)
            | SetExpr::Merge(_)
            | SetExpr::Table(_)
            | SetExpr::SetOperation {..}
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: query.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }
}
```

I'd be interested to see the limits of this idea :)
