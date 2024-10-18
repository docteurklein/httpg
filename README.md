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

It will rely on postgres's own security capabilities to hide stuff you're not authorized to use, by looking at http authorization headers and transform that into a `set local role` in the corresponding transaction.  
It's up to you to grant correct permissions, be it row-level policies or table and column permissions.

Select queries are run in read-only transactions (and rollbacked once done, even tho ["it doesn't matter"](https://www.postgresql.org/message-id/flat/07FDEE0ED7455A48AC42AC2070EDFF7C67EBDF%40corpsrv2.tazznetworks.com)).

```
nix develop --impure -c $SHELL

devenv up --tui=false

HTTPG_SCHEMA=public \
HTTPG_ANON_ROLE=florian \
HTTPG_CONN="" \
cargo run
```

visit ://0:3000
