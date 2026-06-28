\set ON_ERROR_STOP on

set local search_path to gieze, url, pg_catalog, public;

grant usage on schema gieze to anon, gieze_admin;
grant usage on schema url to anon, gieze_admin;
grant execute on all functions in schema url to anon, gieze_admin;

create extension if not exists pgcrypto with schema public cascade;

create or replace view future_invoice_line(client, month, bl, shipped_at, product, quantity, unit_price_ht, total_price_ht, tva_rate, total_tva, total_price_ttc) as
select
  client,
  date_trunc('month', shipped_at)::date,
  bl.bl,
  shipped_at,
  product,
  quantity,
  unit_price_ht,
  unit_price_ht * quantity,
  tva_rate,
  (unit_price_ht * quantity) * tva_rate,
  (unit_price_ht * quantity) * (1 + tva_rate)
from bl_line
join bl using (bl)
join product using (product)
where shipped_at is not null
and not bl.invoiced;

grant select on future_invoice_line to gieze_admin;

create or replace view future_invoice(client, month, total_ht, total_tva, total_ttc) as
select client.client, date_trunc('month', bl.shipped_at)::date, sum(total_price_ht), sum(total_tva), sum(total_price_ttc)
from client
join future_invoice_line using (client)
join bl using (bl)
where future_invoice_line.month = date_trunc('month', bl.shipped_at)::date
group by 1, 2
order by 2 asc, 1 asc;

grant select on future_invoice to gieze_admin;
grant execute on function hstore(text, text) to anon, gieze_admin;

create or replace view todo(html) as
select xmlelement(name h1, 'TODO')::text
union all
(select xmlelement(name div, format('%s %s pour %s', sum(quantity), product, client))::text
from bl_line
join bl using (bl)
where bl.shipped_at is null
group by product, client
order by sum(quantity) desc, product, client);

grant select on todo to gieze_admin;

create or replace procedure invoice(client_ text, month_ date)
language sql
set default_transaction_isolation = 'serializable'
set search_path from current
begin atomic
with next(number) as (
  select
    coalesce(max(increment) + 1, 1)
  from invoice
  where client = client_
  and date_trunc('year', month) = date_trunc('year', month_)
),
new_invoice as (
  insert into invoice(increment, invoice, client, address, client_address, month, invoiced_at, deadline_at, total_ht, total_tva, total_ttc, bank_info, legal_infos) 
  select
    next.number,
    format('%s %s-%s', client, to_char(month, 'YY-MM'), to_char(next.number, 'fm000')),
    (select client from client where client = fi.client), -- not a FK so check manually
    (select billing_address from client where client = fi.client), -- not a FK so check manually
    (select shipping_address from client where client = fi.client), -- not a FK so check manually
    fi.month,
    now(),
    now() + interval '1 month',
    fi.total_ht,
    fi.total_tva,
    fi.total_ttc,
    'bank info',
    'legal infos'
  from future_invoice fi, next
  where fi.client = client_
  and fi.month = month_
  returning client, month, invoice
)
insert into invoice_line(invoice, bl, shipped_at, product, quantity, unit_price_ht, total_price_ht, tva_rate, total_tva, total_price_ttc)
select ni.invoice, fil.bl, fil.shipped_at, fil.product, fil.quantity, unit_price_ht, total_price_ht, tva_rate, total_tva, total_price_ttc
from new_invoice ni
join future_invoice_line fil using (client, month);

update bl set invoiced = true
where date_trunc('month', shipped_at)::date = month_
and client = client_
and shipped_at is not null;
end;

grant execute on procedure invoice to gieze_admin;

create or replace view head (html)
with (security_invoker)
as
with httpg (error) as (
    select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>La Gièze</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="stylesheet" href="/cpres/index.css?v=1" />
    <link rel="stylesheet" href="/gieze/index.css?v=1" />
</head>
$html$
union all
select xmlelement(name form, xmlattributes(
    'grid' as class,
    'POST' as method,
    url('/gieze/login', jsonb_build_object(
        'sql', 'select 1',
        'redirect', url('/gieze/query', jsonb_build_object(
            'sql', 'select * from gieze.head union all select * from gieze.todo'
        )),
        'params[0]', 'gieze'
    )) as action
),
    xmlelement(name input, xmlattributes(
        'text' as type,
        'name' as name,
        'name' as placeholder,
        'required' as required
    )),
    xmlelement(name input, xmlattributes(
        'password' as type,
        'password' as name,
        'password' as placeholder,
        'required' as required
    )),
    xmlelement(name input, xmlattributes('submit' as type, 'login' as value))
)::text
where current_role <> 'gieze_admin'
union all
select xmlelement(name article, xmlattributes('card error' as class), error)::text
from httpg
where error is not null
union all
select xmlelement(name nav, xmlelement(name ul,
  coalesce(xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
    coalesce(href, url('/gieze/query', jsonb_build_object(
      'sql', format('select * from gieze.head union all select * from gieze.%I', rel)
    ))) as href
  ), name))), '')
))::text
from (values
    ('TODO', 'todo', null, current_role = 'gieze_admin'),
    ('BLs', 'bl_admin', null, current_role = 'gieze_admin'),
    ('Factures', 'invoice_admin', null, current_role = 'gieze_admin'),
    ('Clients', 'client_admin', null, current_role = 'gieze_admin'),
    ('Produits', 'product_admin', null, current_role = 'gieze_admin'),
    ('Logout', null, '/gieze/logout?sql=select 1&redirect=/gieze/query?sql=select * from gieze.head', current_role = 'gieze_admin')
) menu (name, rel, href, visible)
where visible
;

grant select on table head to anon, gieze_admin;

create or replace view bl_admin (html)
with (security_invoker)
as
with httpg (error) as (
  select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name h1, 'Bons de livraison')::text
union all
select xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
  xmlelement(name input, xmlattributes(
      'clients' as list,
      'params[0]' as name,
      'client' as placeholder
  )),
  xmlelement(name input, xmlattributes(
    'hidden' as type,
    'on_error' as name,
    'select * from gieze.head union all select * from gieze.bl_admin' as value
  )),
  xmlelement(name input, xmlattributes(
    'hidden' as type,
    'sql' as name,
    $$
      insert into gieze.bl (client) values ($1) returning
        303 status,
        hstore('Location', url.url('/gieze/query', jsonb_build_object(
          'sql', 'select * from gieze.head union all select * from gieze.bl_admin'
        ))) header
    $$ as value
  )),
  xmlelement(name datalist, xmlattributes('clients' as id),
    (select xmlagg(xmlelement(name option, xmlattributes(client as value)) order by client) from client)
  ),
  xmlelement(name input, xmlattributes(
      'submit' as type,
      'New BL' as value
  ))
)::text
union all
select xmlelement(name div, xmlattributes('grid' as class),
  coalesce(xmlagg(xmlelement( name article, xmlattributes('card' as class),
    xmlelement(name h3, format('BL #%s for %s', bl.bl, bl.client)),
    case when shipped_at is null then xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
      xmlelement(name input, xmlattributes(
          'hidden' as type,
          'params[0]' as name,
          bl.bl as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from gieze.head union all select * from gieze.bl_admin' as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$
          update gieze.bl set shipped_at = now()
          where bl = $1::bigint
          returning
            303 status,
            hstore('Location', url.url('/gieze/query', jsonb_build_object(
              'sql', 'select * from gieze.head union all select * from gieze.bl_admin'
            ))) header
        $$ as value
      )),
      xmlelement(name input, xmlattributes(
          'submit' as type,
          'Ship' as value
      ))
    ) else xmltext(format('Livré le %s', shipped_at)) end,
    xmlelement(name datalist, xmlattributes('products' as id),
      (select xmlagg(xmlelement(name option, xmlattributes(product as value)) order by product) from product)
    ),
    (
      select coalesce(xmlagg(
        xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
          xmlelement(name input, xmlattributes(
              'hidden' as type,
              'params[0]' as name,
              bl.bl as value
          )),
          xmlelement(name input, xmlattributes(
              'products' as list,
              'params[1]' as name,
              'product' as placeholder,
              product as value
          )),
          xmlelement(name input, xmlattributes(
              'number' as type,
              'params[2]' as name,
              quantity as value
          )),
          xmlelement(name input, xmlattributes(
            'hidden' as type,
            'sql' as name,
            $$
              insert into gieze.bl_line (bl, product, quantity) values ($1::bigint, $2, $3::int)
              on conflict (bl, product) do update
                set quantity = excluded.quantity
              returning
                303 status,
                hstore('Location', url.url('/gieze/query', jsonb_build_object(
                  'sql', 'select * from gieze.head union all select * from gieze.bl_admin'
                ))) header
            $$ as value
          )),
          xmlelement(name input, xmlattributes(
            'hidden' as type,
            'on_error' as name,
            'select * from gieze.head union all select * from gieze.bl_admin' as value
          )),
          xmlelement(name input, xmlattributes(
              'submit' as type,
              button as value
          ))
      )))
      from (
        values (bl.bl, null, 1, 'Add')
        union all
        select bl, product, quantity, 'Edit' from bl_line l where l.bl = bl.bl
      ) _ (bl, product, quantity, button)
    )
  ) order by bl.bl desc), '')
)::text
from bl
;

grant select on table bl_admin to gieze_admin;

create or replace view invoice_admin (html)
with (security_invoker)
as
with httpg (error) as (
  select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name h1, 'A facturer')::text
union all
select xmlelement(name div, xmlattributes('grid' as class),
  coalesce(xmlagg(xmlelement(name article, xmlattributes('card future-invoice' as class),
    xmlelement(name h3, format('%s #%s', client, month)),
    xmlelement(name table,
      xmlelement(name thead,
        xmlelement(name tr,
          xmlelement(name th, 'Libellé'),
          xmlelement(name th, 'Qté'),
          xmlelement(name th, 'PU HT'),
          xmlelement(name th, 'Prix HT'),
          xmlelement(name th, '% TVA'),
          xmlelement(name th, 'TVA'),
          xmlelement(name th, 'TTC')
        )
      ),
      xmlelement(name tbody, (
        with grouped (bl, shipped_at, lines) as (
          select bl, shipped_at, xmlagg(
            xmlelement(name tr,
              xmlelement(name td, product),
              xmlelement(name td, quantity),
              xmlelement(name td, unit_price_ht),
              xmlelement(name td, total_price_ht),
              xmlelement(name td, round(tva_rate * 100, 2)),
              xmlelement(name td, round(total_tva, 2)),
              xmlelement(name td, round(total_price_ttc, 2))
            )
          )
          from future_invoice_line l
          where l.client = future_invoice.client
          and l.month = future_invoice.month
          group by 1, 2
        )
        select xmlagg(xmlelement(name tr,
          xmlelement(name th, format('BL #%s du %s', bl, shipped_at::date)),
          lines
        ))
        from grouped
      )),
      xmlelement(name tfoot,
        xmlelement(name tr,
          xmlelement(name th, xmlattributes(3 as colspan), 'Total €'),
          xmlelement(name td, total_ht),
          xmlelement(name td, ''),
          xmlelement(name td, round(total_tva, 2)),
          xmlelement(name td, xmlelement(name b, round(total_ttc, 2)))
        )
      )
    ),
    xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$call gieze.invoice($1, $2::date)$$ as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from gieze.head union all select * from gieze.invoice_admin' as value
      )),
      xmlelement(name input, xmlattributes(
          'hidden' as type,
          'params[0]' as name,
          client as value
      )),
      xmlelement(name input, xmlattributes(
          'hidden' as type,
          'params[1]' as name,
          month as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'redirect' as name,
        'referer' as value
      )),
      xmlelement(name input, xmlattributes(
          'submit' as type,
          'Facturer' as value
      ))
    )
  )), '')
)::text
from future_invoice
union all
select xmlelement(name h1, 'Factures passées')::text
union all
select xmlelement(name div, xmlattributes('grid' as class),
  coalesce(xmlagg(xmlelement(name article, xmlattributes('card' as class),
    xmlelement(name h3, invoice),
    xmlelement(name a, xmlattributes('this.nextSibling.contentWindow.print()' as onclick), 'print'),
    xmlelement(name iframe, xmlattributes(url('/gieze/query', jsonb_build_object(
      'sql', $$select html from gieze.invoice_detail where invoice in ('head', $1)$$,
      'params[0]', invoice
    )) as src), '')
  )), '')
)::text
from invoice
;

grant select on table invoice_admin to gieze_admin;

create or replace view client_admin (html)
with (security_invoker)
as
with httpg (error) as (
  select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name h1, 'Clients')::text
union all
select xmlserialize(document xmlelement(name div, xmlattributes('grid' as class),
  coalesce(xmlagg(xmlelement(name article, xmlattributes('card' as class),
    xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$
          insert into gieze.client (client, billing_address, shipping_address, phone)
          values (nullif($1, ''), nullif($2, ''), nullif($3, ''), nullif($4, ''))
          on conflict (client) do update set
            billing_address = excluded.billing_address,
            shipping_address = excluded.shipping_address,
            phone = excluded.phone
          returning
            303 status,
            hstore('Location', url.url('/gieze/query', jsonb_build_object(
              'sql', 'select * from gieze.head union all select * from gieze.client_admin'
            ))) header
        $$ as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from gieze.head union all select * from gieze.client_admin' as value
      )),
      xmlelement(name input, xmlattributes(
          'text' as type,
          'params[0]' as name,
          'client' as placeholder,
          client as value
      )),
      xmlelement(name input, xmlattributes(
          'text' as type,
          'params[1]' as name,
          'Adresse de facturation' as placeholder,
          billing_address as value
      )),
      xmlelement(name input, xmlattributes(
          'text' as type,
          'params[2]' as name,
          'Adresse de livraison' as placeholder,
          shipping_address as value
      )),
      xmlelement(name input, xmlattributes(
          'tel' as type,
          'params[3]' as name,
          'Téléphone' as placeholder,
          phone as value
      )),
      xmlelement(name input, xmlattributes(
          'submit' as type,
          button as value
      ))
    ))
), '')) as text indent)
from (
  values (null, null, null, null, 'Add')
  union all
  select client, billing_address, shipping_address, phone, 'Edit'
  from client
) _ (client, billing_address, shipping_address, phone, button)
;

grant select on table client_admin to gieze_admin;

create or replace view product_admin (html)
with (security_invoker)
as
with httpg (error) as (
  select nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select xmlelement(name h1, 'Produits')::text
union all
select xmlelement(name div, xmlattributes('grid' as class),
  coalesce(xmlagg(xmlelement(name article, xmlattributes('card' as class),
    xmlelement(name form, xmlattributes('POST' as method, '/gieze/query' as action),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        $$
          insert into gieze.product (product, unit_price_ht, tva_rate)
          values (nullif($1, ''), nullif($2, '')::numeric, nullif($3, '')::numeric / 100)
          on conflict (product) do update set
            unit_price_ht = excluded.unit_price_ht,
            tva_rate = excluded.tva_rate
          returning
            303 status,
            hstore('Location', url.url('/gieze/query', jsonb_build_object(
              'sql', 'select * from gieze.head union all select * from gieze.product_admin'
            ))) header
        $$ as value
      )),
      xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        'select * from gieze.head union all select * from gieze.product_admin' as value
      )),
      xmlelement(name input, xmlattributes(
          'text' as type,
          'params[0]' as name,
          'produit' as placeholder,
          product as value
      )),
      xmlelement(name input, xmlattributes(
          'number' as type,
          '0.01' as step,
          'params[1]' as name,
          'Prix Unitaire HT' as placeholder,
          unit_price_ht as value
      )),
      xmlelement(name input, xmlattributes(
          'number' as type,
          '0.01' as step,
          'params[2]' as name,
          'Taux TVA (%)' as placeholder,
          round(tva_rate * 100, 2) as value
      )),
      xmlelement(name input, xmlattributes(
          'submit' as type,
          button as value
      ))
    ))
 order by product nulls first), ''))::text
from (
  values (null, null::numeric, null::numeric, 'Add')
  union all
  select product, unit_price_ht, tva_rate, 'Edit'
  from product
) _ (product, unit_price_ht, tva_rate, button)
;

grant select on table product_admin to gieze_admin;

create or replace view invoice_detail (html, invoice)
with (security_invoker)
as
with httpg (error) as (
  select
    nullif(current_setting('httpg.errors', true), '')::jsonb->>'error'
)
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>La Gièze</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="stylesheet" href="/cpres/index.css?v=1" />
    <link rel="stylesheet" href="/gieze/index.css?v=1" />
</head>
$html$, 'head'
union all
select xmlelement(name div, xmlattributes(true as contenteditable),
  xmlelement(name header, xmlattributes('grid' as class),
    xmlelement(name div,
      xmlelement(name img, xmlattributes('/gieze/logo-gieze.png' as src)),
      xmlelement(name h2, 'La Gièze'),
      xmlelement(name p, '03250 Ferrières-sur-Sichon'),
      xmlelement(name p, '06 60 77 09 97')
    ),
    xmlelement(name div,
      xmlelement(name h2, format('Facture %s-%s', to_char(month, 'YY-MM'), to_char(increment, 'fm000'))),
      xmlelement(name p, format('Facturé: %s', invoiced_at::date)),
      xmlelement(name p, format('Echéance: %s', deadline_at::date)),
      xmlelement(name h3, client),
      xmlelement(name p, client_address)
    )
  ),
  xmlelement(name table,
    xmlelement(name thead,
      xmlelement(name tr,
        xmlelement(name th, 'Libellé'),
        xmlelement(name th, 'Qté'),
        xmlelement(name th, 'PU HT'),
        xmlelement(name th, 'Prix HT'),
        xmlelement(name th, '% TVA'),
        xmlelement(name th, 'TVA'),
        xmlelement(name th, 'TTC')
      )
    ),
    xmlelement(name tbody, (
      with grouped (bl, shipped_at, lines) as (
        select bl, shipped_at, xmlagg(
          xmlelement(name tr,
            xmlelement(name td, product),
            xmlelement(name td, quantity),
            xmlelement(name td, unit_price_ht),
            xmlelement(name td, total_price_ht),
            xmlelement(name td, round(tva_rate * 100, 2)),
            xmlelement(name td, total_tva),
            xmlelement(name td, total_price_ttc)
          )
        )
        from invoice_line l
        where l.invoice = invoice.invoice
        group by 1, 2
      )
      select xmlagg(xmlelement(name tr,
        xmlelement(name th, format('BL #%s du %s', bl, shipped_at::date)),
        lines
      ))
      from grouped
    )),
    xmlelement(name tfoot,
      xmlelement(name tr,
        xmlelement(name th, xmlattributes(3 as colspan), 'Total €'),
        xmlelement(name td, total_ht),
        xmlelement(name td, ''),
        xmlelement(name td, round(total_tva, 2)),
        xmlelement(name td, xmlelement(name b, round(total_ttc, 2)))
      )
    )
  ),
  xmlelement(name footer,
    xmlelement(name pre, 'Notes'),
    xmlelement(name div, xmlattributes('grid' as class),
      xmlelement(name p, bank_info),
      xmlelement(name p, legal_infos)
    )
  )
)::text, invoice
from invoice
;

grant select on table invoice_detail to gieze_admin;

create or replace function login() returns setof text
volatile strict parallel safe -- leakproof
language sql
security definer
set search_path to gieze, pg_catalog
begin atomic
with httpg (body) as (
  select current_setting('httpg.query', true)::jsonb->'body'
)
select 'set local role to gieze_admin'
from admin, httpg
where name = body->>'name'
and password = crypt(body->>'password', salt);
end;

grant execute on function login() to anon, gieze_admin;
