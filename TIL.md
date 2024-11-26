## 2024/11/24: tokio-postgres stream query and commit

rust's tokio-postgres has a stream api for queries.
However I think there is a (protocol?) problem where if you commit before consuming the stream,
it simply blocks.

It is anyway a good idea to not stream something that has not yet been committed.

c.f: https://github.com/sfackler/rust-postgres/issues/1191#issuecomment-2494096341
