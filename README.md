# httpg

## what ?

An http server written in rust with tokio/axum, to make postgres objects accessible via http.  
Similar to postgREST or sqlpage.

## why ?

To provide a flexible bridge between http and sql.

## how ?

Stream arbitrary sql using `GET /query?sql=select something`. The first column will be sent as the body to the client.  
Modify arbitrary sql using `POST /query?sql=insert into something`.  
Control response status, headers and body using `/raw?sql=select 400 as status, 'content'::bytea as body`.
Send emails using `/email?sql=select 'sender@example.org' "from", 'receiver@example.org' to, 'test' subjet, 'content' html`.
Send web push notifications using `/web_push?sql=select 'https://...' endpoint, '...' p256dh,  '...' auth, 'test'::bytea content`.
Send http requests notifications using `/http?sql=select 'POST' method, 'https://...' url`.
Set encrypted cookies (biscuits) using `/login?sql=select 'set local role to ...'`. This will store and execute the returned values as sql statements for each http request.
 
It will rely on postgres's own security capabilities to hide stuff you're not authorized to use, by looking at http authorization headers and transform that into a `set local role` in the corresponding transaction.  
It's up to you to grant correct permissions, be it row-level policies or table and column permissions.

Select queries are run in read-only transactions (and rollbacked once done, even tho ["it doesn't matter"](https://www.postgresql.org/message-id/flat/07FDEE0ED7455A48AC42AC2070EDFF7C67EBDF%40corpsrv2.tazznetworks.com)).

```
nix develop . -c $SHELL

generate keypair: https://doc.biscuitsec.org/usage/command-line.html
export HTTPG_PRIVATE_KEY=private-key-file

nix run .#container -- create --update-changed --restart-changed --start

```

visit http://0:3000
