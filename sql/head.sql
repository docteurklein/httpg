drop view if exists head;
create or replace view head(html) as
select $html$<!DOCTYPE html>
<html>
<head>
    <style>
        body {
          max-width: 90%;
          margin: auto;
        }
        .menu {
            //display: flex;
            //flex-wrap: wrap;
            //gap: 1rem 2rem;
        }
    </style>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" />
</head>
<body>
<script type="module">
    console.log(document);
    document.addEventListener('click', console.log);
</script>
$html$
union all select $html$
<form method="POST" action="/login">
    <input type="text" name="user" />
    <input type="password" name="password" />
    <input type="submit" value="login" />
</form>
$html$
where current_role = 'anon'
union all select xmlelement(name ul, xmlattributes('menu' as class), (
    select xmlagg(
        xmlelement(name li,
            xmlelement(name a, xmlattributes(
                format(
                    $$/query?sql=select html from head union all ( select html('%1$s', to_jsonb(r), current_setting('httpg.query', true)::jsonb) from %1$s r limit 100)$$,
                    fqn
                ) as href
            ), fqn)
            -- , xmlelement(name a, xmlattributes(
            --     format(
            --         $sql$/query?sql=table head union all ( select html('%1$s', to_jsonb(r), $2) from %1$s r limit 100)$sql$,
            --         fqn
            --     ) as href,
            --     'portal-' || fqn as target
            -- ), 'in iframe')
            -- , xmlelement(name iframe, xmlattributes(
            --     'portal-' || fqn as name
            -- ), '')
            )
        )
        from rel
    ), '')::text
    where current_role <> 'anon'
;
