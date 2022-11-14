# httpg

## what ?

An http server written in rust with tokio/axum, to make postgres objects accessible via http.  
Similar to postgREST, except it tries to be more restful (content negotiation, server-side html templating, json, in-band links to ease graph traversal and discovery).

Very much a work in progress.

## why ?

Because postgREST is painful to work with as soon as you want something else than JSON, and I wanted to play with rust one more time.  

## how ?

`httpg` will introspect postgres schema using `pg_catalog` objects and use this to form valid sql queries out of http request.  
It will then transform the sql execution result in an http response.

It will rely on postgres's own security capabilities to hide stuff you're not authorized to use, by using http authorization headers and transform that into a `set local role` in the corresponding transaction.  
It's up to you to grant correct permissions, be it row-level policies or table and column permissions.

Select queries are run in read-only transactions (and rollbacked once done, even tho ["it doesn't matter"](https://www.postgresql.org/message-id/flat/07FDEE0ED7455A48AC42AC2070EDFF7C67EBDF%40corpsrv2.tazznetworks.com).

```
HTTPG_SCHEMA=public \
HTTPG_ANON_ROLE=florian \
HTTPG_CONN="host=localhost user=florian password=$PGPASS" \
cargo run

curl '0:3000/select/public.spatial_ref_sys?spatial_ref_sys.auth_name=EPSG' \
    -H 'accept: text/html' \
    -H 'template: test' \ # use templates/test.hbs to render result as html
    -H 'limit: 20' \
    -H 'authorization: app'

curl -X POST '0:3000/procedure/public.divide?a=1&b=2' -H 'authorization: app'
```
