\set ON_ERROR_STOP on

set local search_path to cpres, url, pg_catalog, public;

create or replace function cpres._(id_ text, lang_ text = null)
returns text
immutable parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
language sql
begin atomic
    with t (text) as (
        select text
        from translation
        where (id, lang) = (id_, coalesce(
            lang_,
            substring(current_setting('httpg.query', true)::jsonb->>'accept_language' from '^(\w+)-?\w*,?.*')
        ))
        limit 1
    )
    select coalesce(
        (select text from t),
        id_
    );
end;

create or replace function max_interest_price(good good) returns xml
language sql
immutable strict parallel safe -- leakproof
set search_path to cpres, pg_catalog
security definer
begin atomic;
    with max(price) as (
        select max(price)
        from interest
        where good_id = good.good_id
        and person_id <> current_person_id()
    ) 
    select xmlelement(name div,
        format(_('current bid at %s€'), price)
    )
    from max
    where price > 0;
end;

create or replace function interest_control(good good, interest interest) returns xml
language sql
immutable parallel safe -- leakproof
set search_path to cpres, pg_catalog
begin atomic;
    select xmlconcat(
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'sql', format('call want(%L, $2::interest_level, $1)', good.good_id)
                )) as action,
                null as class
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'redirect' as name,
                    url('/webpush', jsonb_build_object(
                        'sql', 'select * from web_push_want($1::uuid, $2::uuid)',
                        'params[0]', interest.good_id,
                        'params[1]', interest.person_id,
                        'redirect', 'referer'
                    )) as value
                )),
                max_interest_price(good),
                _('propose '),
                xmlelement(name input, xmlattributes(
                    'price' as class,
                    'number' as type,
                    0 as min,
                    'any' as step,
                    'params[]' as name,
                    interest.price as value,
                    _('Price?') as placeholder
                )),
                xmlelement(name span, xmlattributes('inline' as class), '€'),
                (
                    select xmlagg(
                        xmlelement(name label, case when interest.level = value
                            then xmlelement(name input, xmlattributes('radio' as type, value, 'params[]' as name, 'required' as required, true as checked))
                            else xmlelement(name input, xmlattributes('radio' as type, value, 'params[]' as name, 'required' as required))
                    end, _(value::text)))
                    from unnest(enum_range(null::interest_level)) a (value)
                ),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    _('Interested') as value
                ))
            )
            where current_person_id() is not null
            and current_person_id() <> good.giver
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'sql', format('call unwant(%L)', (good).good_id),
                    'redirect', 'referer'
                )) as action
            ),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'destructive' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Not interested anymore') as value
                ))
            )
            where exists (
                select from interest
                where good.good_id = interest.good_id
                and interest.person_id = current_person_id()
            )
            and current_person_id() is not null
            and current_person_id() <> (good).giver
        )
    );
end;

create or replace view "good_detail" (html, location, bird_distance_km, good_id, receiver)
with (security_invoker)
as with q (qs) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
),
looker (location) as (
    select coalesce((qs->>'location')::point, location)
    from person_detail, q
    where person_id = current_person_id()
    limit 1
),
base as (
    select good, interest, giver.name as giver_name,
        case when looker.location is not null then (good.location <@> looker.location) * 1.609347 end bird_distance_km
    from good
    left join interest on (interest.good_id, interest.person_id) = (good.good_id, current_person_id())
    join person giver on (good.giver = giver.person_id)
    left join looker on true
)
select xmlelement(name article,
    xmlelement(name h2, xmlelement(name a, xmlattributes(
        url('/query', jsonb_build_object(
            'sql', 'table head union all select html from "good_detail" where good_id = $1::uuid',
            'params[]', (good).good_id,
            'show_map', true
        )) as href
    ), (good).title)),
    xmlelement(name img, xmlattributes(
        'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png' as src,
        'marker-icon' as class,
         (good).good_id as "for"
    )),
    xmlelement(name span, format(_('By %s'), giver_name)),
    ', ',
    xmlelement(name span, xmlattributes((good).created_at as title), format(_('at %s'), to_char((good).created_at, _('TMDay DD/MM')))),
    xmlelement(name p, (good).description),
    case when bird_distance_km is not null then
        xmlelement(name div, format('bird distance: %s km', round(bird_distance_km::numeric, 2)))
    end,
    xmlelement(name a, xmlattributes(
        format('https://www.google.com/maps/dir/?api=1&destination=%s,%s', (good).location[0], (good).location[1]) as href,
        '_blank' as target
    ), _('go with google maps')),
    case when qs->>'show_map' is not null then
        xmlelement(name input, xmlattributes('hidden' as type, true as readonly, 'cpres-map' as is, (good).location as value))
    end,
    xmlelement(name div, xmlattributes('grid media' as class), coalesce((
        select xmlagg(xmlelement(name article, xmlattributes('card' as class),
            (
                with url (url) as (
                    select url('/query', jsonb_build_object(
                        'sql', 'select content from good_media where content_hash = $1::text::bytea',
                        'params[]', content_hash,
                        'accept', content_type,
                        'cache_control', 'max-age=604800 immutable'
                    ))
                )
                select case
                    when starts_with(content_type, 'image/') then xmlelement(name a, xmlattributes(url as href),
                        xmlelement(name img, xmlattributes(url as src))
                    )
                    else xmlelement(name object, xmlattributes(url as data, content_type as type),
                        xmlelement(name a, xmlattributes(url as href), name)
                    )
                end
                from url
            )
        ))
        from good_media
        where good_id = (good).good_id
    ), '')),
    interest_control(good, interest)
)::text, (good).location, bird_distance_km::int, (good).good_id, (good).receiver
from base good, q;

grant select on table "good_detail" to person;

create or replace function good_form(id text, params jsonb, sql text) returns xml
security invoker
immutable parallel safe -- leakproof
language sql
begin atomic
with query (q, good_id, redirect, errors) as (
    with q (q, errors) as (
        select nullif(current_setting('httpg.query', true), '')::jsonb,
        nullif(current_setting('httpg.errors', true), '')::jsonb
    )
    select q,
    q->'body'->>'form.id',
    q->>'redirect',
    errors
    from q
)
select xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/query', jsonb_build_object(
            'redirect', url('/query', jsonb_build_object(
                'sql', 'table head union all select html from "good admin"',
                'flash[green]', 'Saved successfully'
            ))
        )) as action
    ),
    case when good_form.id = query.good_id then
        xmlelement(name article, xmlattributes(
            'card error' as class
        ), coalesce(_(errors->>'error'), ''))
    end,
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'form.id' as name,
        good_form.id as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'sql' as name,
        sql as value
    )),
    xmlelement(name input, xmlattributes(
        'hidden' as type,
        'on_error' as name,
        coalesce(q->'body'->>'on_error', q->'qs'->>'sql', 'table head union all select html from "good admin"') as value
    )),
    xmlelement(name div, xmlattributes('grid' as class),
        xmlelement(name div,
            xmlelement(name input, xmlattributes(
                'text' as type,
                'params[0]' as name,
                _('title') as placeholder,
                'required' as required,
                params->>0 as value
            )),
            xmlelement(name textarea, xmlattributes(
                'params[1]' as name,
                '10' as rows,
                'description' as placeholder
            ), coalesce(params->>1, ''))
        ),
        xmlelement(name input, xmlattributes(
            'text' as type,
            'cpres-map' as is,
            'params[2]' as name,
            _('location: (lat,lng)') as placeholder,
            'location' as class,
            '\(.+,.+\)' as pattern,
            'required' as required,
            params->>2 as value
        ))
    ),
    xmlelement(name input, xmlattributes(
        'submit' as type,
        _('Submit') as value
    ))
)
from query;
end;

grant execute on function good_form to person;

create or replace view "good admin" (html)
with (security_invoker)
as with query (q) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb
),
result (html, good_id) as (
    select xmlelement(name article, xmlattributes('card' as class),
        case when receiver.name is not null then xmltext(format(_('Given to %s'), receiver.name)) end,
        good_form(
            good_id::text,
            case q->'body'->>'form.id'
                when good_id::text then q->'body'->'params'
                else jsonb_build_array(title, description, good.location)
            end,
            format('update good set title = $1::text, description = $2::text, location = $3::text::point where good_id = %L', good_id)
        ),
        xmlelement(name div, xmlattributes('grid media' as class), coalesce((
            select xmlagg(xmlelement(name article, xmlattributes('card' as class),
                (
                    with url (url) as (
                        select url('/query', jsonb_build_object(
                            'sql', 'select content from good_media where content_hash = $1::text::bytea',
                            'params[]', content_hash,
                            'accept', content_type,
                            'cache_control', 'max-age=604800 immutable'
                        ))
                    )
                    select case
                        when starts_with(content_type, 'image/') then xmlelement(name a, xmlattributes(url as href),
                            xmlelement(name img, xmlattributes(url as src))
                        )
                        else xmlelement(name object, xmlattributes(url as data, content_type as type),
                            xmlelement(name a, xmlattributes(url as href), name)
                        )
                    end
                    from url
                ),
                xmlelement(name form, xmlattributes(
                    'POST' as method,
                    '/query' as action
                ),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'redirect' as name,
                        'referer' as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'params[]' as name,
                         encode(content_hash, 'base64') as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'hidden' as type,
                        'sql' as name,
                        format($$
                            delete from good_media
                            where content_hash = decode($1::text, 'base64')
                        $$, good_id) as value
                    )),
                    xmlelement(name input, xmlattributes(
                        'submit' as type,
                        'destructive' as class,
                        format('return confirm(%L)', _('Are you sure?')) as onclick,
                        _('X') as value
                    ))
                )
            ))
            from good_media
            where good_id = good.good_id
        ), '')),
        xmlelement(name article, xmlattributes('card' as class),
            xmlelement(name form, xmlattributes(
                'POST' as method,
                '/query' as action,
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
                        insert into good_media (good_id, name, content, content_type)
                        select %L, convert_from(f[3], 'UTF8'), f[1], convert_from(f[2], 'UTF8')
                        from f
                        where f[1] <> ''
                        on conflict (good_id, content_hash) do nothing
                    $$, good_id) as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'on_error' as name,
                    coalesce(q->'body'->>'on_error', q->'qs'->>'sql', 'table head union all select html from "good admin"') as value
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
        ),
        xmlelement(name form, xmlattributes(
            'POST' as method,
            '/query' as action
        ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'redirect' as name,
                'referer' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'delete from good where good_id = $1::uuid' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'params[]' as name,
                good_id as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                'destructive' as class,
                format('return confirm(%L)', _('Are you sure?')) as onclick,
                _('Remove this good') as value
            ))
        )
    ), good_id
    from query, good
    left join person receiver on (good.receiver = receiver.person_id)
    where giver = current_person_id()
    order by coalesce(updated_at, created_at) desc, title
)
select xmlelement(name div, xmlattributes('new' as class),
    xmlelement(name h2, _('New good')),
    good_form(
        'new',
        case q->'body'->>'form.id'
            when 'new' then q->'body'->'params'
            else '[]'
        end,
        'insert into good (title, description, location) values ($1, $2, $3::point)'
    ),
    xmlelement(name h2, _('Existing goods'))
)::text
from query
union all select xmlelement(name div, xmlattributes('grid good' as class),
    array_agg(html)
)::text
from result
union all select _('Nothing yet.') where not exists (select from result limit 1)
;

grant select on table "good admin" to person;

create or replace view "giving activity" (html)
with (security_invoker)
as with q (body) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'body'
),
data (good_id, giver_id, title, given) as (
    select good_id, good.giver, title, exists (select from interest where good_id = good.good_id and state in ('approved', 'late', 'given'))
    from good
    where giver = current_person_id()
    and exists (select from interest where good_id = good.good_id)
    order by
        coalesce(good.updated_at, good.created_at) desc
),
html (html) as (
    select xmlelement(name article, xmlattributes('card' as class),
        xmlelement(name h2, xmlelement(name a, xmlattributes(
            title as id,
            url('/query', jsonb_build_object(
                'sql', 'table head union all select html from "good_detail" where good_id = $1::uuid',
                'params[]', good_id,
                'show_map', true
            )) as href
        ), title)),
        xmlelement(name div, xmlattributes('grid interest' as class), (
            select xmlagg(
                xmlelement(name article, xmlattributes('card' as class, format('%s-%s', interest.good_id, interest.person_id) as id),
                    xmlelement(name div, xmlattributes('inline' as class),
                        xmlelement(name h4, format(_('%s is %s'), receiver.name, _(interest.level::text))),
                        case when interest.price is not null then
                            xmlelement(name div, format(_('For %s€'), interest.price))
                        end,
                        ' ',
                        case when receiver.phone is not null then
                            xmlconcat(xmlelement(name a, xmlattributes(
                                format('tel:%s', receiver.phone) as href,
                                'tel' as class
                            ), receiver.phone),
                            xmlelement(name a, xmlattributes(
                                format(_('https://wa.me/%s?text=About receiving %s'), receiver.phone, title) as href,
                                'whatsapp' as class,
                                'whatsapp' as title
                            ), '✆'))
                        end
                    ),
                    (
                        with message as (
                            select *
                            from message
                            where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
                        )
                        select xmlelement(name div, xmlattributes('messages' as class), coalesce(xmlagg(
                            xmlelement(name article, xmlattributes(message_id as id),
                                format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))),
                                xmlelement(name pre, content)
                            ) order by at), ''))
                        from message
                        join person author on (author.person_id = message.author)
                    ),
                    (with message_id (message_id) as (select gen_random_uuid())
                    select xmlelement(name form, xmlattributes(
                        'POST' as method,
                        '/query' as action
                    ),
                        xmlelement(name input, xmlattributes(
                            'hidden' as type,
                            'sql' as name,
                            format('insert into message (message_id, good_id, person_id, content) values (%L, %L, %L, $1)', message_id, interest.good_id, interest.person_id) as value
                        )),
                        xmlelement(name input, xmlattributes(
                            'hidden' as type,
                            'redirect' as name,
                            url('/webpush', jsonb_build_object(
                                'sql', 'select * from web_push_message($1::uuid, $2::uuid)',
                                'params[0]', message_id,
                                'params[1]', interest.person_id,
                                'redirect', url('/query', jsonb_build_object('sql', 'table head union all table "giving activity"'))
                            )) as value
                        )),
                        xmlelement(name textarea, xmlattributes(
                            'params[]' as name,
                            '10' as rows,
                            'message' as placeholder,
                            'required' as required
                        ), ''),
                        xmlelement(name input, xmlattributes(
                            'submit' as type,
                            _('Send message') as value
                        ))
                    ) from message_id),
                    case when interest.state in ('approved', 'late', 'given')
                        then xmltext(_('Winner'))
                        when not given then xmlelement(name form, xmlattributes(
                            'POST' as method,
                            '/query' as action
                        ),
                            xmlelement(name input, xmlattributes(
                                'hidden' as type,
                                'sql' as name,
                                'call give($1::uuid, $2::uuid)' as value
                            )),
                            xmlelement(name input, xmlattributes(
                                'hidden' as type,
                                'redirect' as name,
                                url('/webpush', jsonb_build_object(
                                    'sql', 'select * from web_push_gift($1::uuid, $2::uuid)',
                                    'params[0]', interest.good_id,
                                    'params[1]', interest.person_id,
                                    'redirect', url('/query', jsonb_build_object('sql', 'table head union all table "giving activity"'))
                                )) as value
                            )),
                            xmlelement(name input, xmlattributes(
                                'hidden' as type,
                                'params[]' as name,
                                interest.good_id as value
                            )),
                            xmlelement(name input, xmlattributes(
                                'hidden' as type,
                                'params[]' as name,
                                interest.person_id as value
                            )),
                            xmlelement(name input, xmlattributes(
                                'submit' as type,
                                -- format('return confirm(%L)', _('Are you sure?')) as onclick,
                                format(_('Give to %s'), receiver.name) as value
                            ))
                        )
                    end
                )
                order by
                    price desc nulls last,
                    case level
                        when 'highly interested' then 2
                        when 'interested' then 1
                        when 'a little interested' then 0
                    end desc,
                    at asc
            )
            from interest
            join person receiver on (interest.person_id = receiver.person_id)
            join person giver on (data.giver_id = giver.person_id)
            where data.good_id = interest.good_id
        ))
    )
    from data, q
)
select xmlelement(name h2, _('Giving activity'))::text
union all select xmlelement(name div, xmlattributes('grid good' as class), coalesce(xmlagg(html), ''))::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "giving activity" to person;

drop type if exists public_person cascade;
create type public_person as (name text, phone text);

create or replace view "receiving activity" (html)
with (security_invoker)
as with q (body) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'body'
),
data (good, giver, receiver, interest) as (
    select good, row(giver_.name, giver_.phone)::public_person, row(receiver_.name, receiver_.phone)::public_person, interest
    from interest
    join good using (good_id)
    join person giver_ on (good.giver = giver_.person_id)
    join person receiver_ on (interest.person_id = receiver_.person_id)
    where interest.person_id = current_person_id()
),
html (good, html) as (
    select good, xmlelement(name article, xmlattributes('interest card' as class),
        case when (interest).origin = 'automatic' then
            xmlelement(name div,
                xmlelement(name a, xmlattributes(
                    url('/query', jsonb_build_object(
                        'sql', 'table head union all table "findings"',
                        'q', (interest).query,
                        'use_primary', null
                    )) as href
                ), format('found via search: %s', (interest).query))
            )
        end,
        xmlelement(name div, xmlattributes('inline' as class),
            xmlelement(name h2, xmlelement(name a, xmlattributes(
                (good).title as id,
                url('/query', jsonb_build_object(
                    'sql', 'table head union all select html from "good_detail" where good_id = $1::uuid',
                    'params[]', (good).good_id,
                    'show_map', true
                )) as href
            ), (good).title)),
            xmlelement(name span, format(_('By %s'), (giver).name)),
            ' ',
            case when (giver).phone is not null then
                xmlconcat(
                    xmlelement(name a, xmlattributes(
                        format('tel:%s', (giver).phone) as href,
                        'tel' as class
                    ), (giver).phone),
                    xmlelement(name a, xmlattributes(
                        format(_('https://wa.me/%s?text=About giving %s'), (giver).phone, (good).title) as href,
                        'whatsapp' as class,
                        'whatsapp' as title
                    ), '✆')
                )
            end
        ),
        (
            with message as (
                select *
                from message
                where (message.good_id, message.person_id) = ((interest).good_id, (interest).person_id)
            )
            select xmlelement(name div, xmlattributes('messages' as class), coalesce(xmlagg(
                xmlelement(name article, xmlattributes(message_id as id),
                    format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))),
                    xmlelement(name pre, content)
                ) order by at asc), '')
            )
            from message
            join person author on (author.person_id = message.author)
        ),
        (with message_id (message_id) as (select gen_random_uuid())
        select xmlelement(name form, xmlattributes(
            'POST' as method,
            '/query' as action
        ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                format('insert into message (message_id, good_id, person_id, content) values (%L, %L, %L, $1)', message_id, (interest).good_id, (interest).person_id) as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'redirect' as name,
                url('/webpush', jsonb_build_object(
                    'sql', 'select * from web_push_message($1::uuid, $2::uuid)',
                    'params[0]', message_id,
                    'params[1]', (good).giver,
                    'redirect', url('/query', jsonb_build_object('sql', 'table head union all table "receiving activity"'))
                )) as value
            )),
            xmlelement(name textarea, xmlattributes(
                'params[]' as name,
                '10' as rows,
                'message' as placeholder,
                'required' as required
            ), ''),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Send message') as value
            ))
        ) from message_id),
        case when (interest).state in ('approved', 'given', 'late')
            then xmltext(_('Winner'))
            else interest_control(good, interest)
        end
    )
    from data, q
)
select xmlelement(name h2, _('Receiving activity'))::text
union all select xmlelement(name div, xmlattributes('grid good' as class),
    coalesce(xmlagg(html order by coalesce((good).updated_at, (good).created_at) desc), ''))::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "receiving activity" to person;

create or replace view finding_list (sort, good_id, location, html)
with (security_invoker)
as with q (qs) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
),
result (good_id, rerank_distance, sort) as (
    select good_id, case when qs->>'q' <> '' then
        rerank_distance(qs->>'q', passage)
        else -1
    end,
    case when qs->>'q' <> '' then embedding <=> embed_query(qs->>'q') else 1 end
    from q, good
    order by 3
    limit 500
)
select sort, good_id, location, xmlelement(name article, xmlattributes('card' as class), d.html::xml)
from q, result
join "good_detail" d using (good_id)
where rerank_distance < 0
and bird_distance_km < coalesce(nullif(qs->>'distance', '')::int, 50)
and not exists (
    select from interest
    where good_id = d.good_id
    and state in ('approved', 'late', 'given')
);

grant select on table finding_list to person;

-- drop table if exists osm_auvergne cascade;
create unlogged table if not exists osm_auvergne (
    geog geography,
    osm_type text,
    osm_id bigint,
    tags jsonb
);

-- drop materialized view if exists auvergne_boundary cascade;
create materialized view if not exists auvergne_boundary (geom, id) as
with polygon as (
    select ST_Multi(geog::geometry) as geom
    from osm_auvergne
    where osm_type = 'relation'
    and tags->>'boundary' = 'administrative'
    and tags->>'admin_level' in ('4', '8')
)
select ST_Union(geom), 'auvergne'
from polygon;

grant select on table auvergne_boundary to person;

-- drop table if exists auvergne_road_vertex cascade;
-- create table if not exists auvergne_road_vertex as
-- select *
-- from pgr_extractvertices($$
--     select osm_id id, geog::geometry geom
--     from osm_auvergne
--     where osm_type = 'way'
--     and tags ? 'highway'
--     and tags->>'highway' not in ('footway', 'pedestrian')
-- $$);

-- drop materialized view if exists auvergne_network cascade;
create materialized view if not exists auvergne_network (id, geog, source, target, cost, reverse_cost) as
with edge (id, geog, startpoint, endpoint, cost) as (
    select osm_id, geog, st_startpoint(geog::geometry), st_endpoint(geog::geometry), st_length(geog)
    from osm_auvergne
    where osm_type = 'way'
    and tags ? 'highway'
    and tags->>'highway' in (
        'primary',
        'primary_link',
        'secondary',
        'secondary_link',
        'tertiary',
        'tertiary_link',
        'motorway',
        'motorway_link',
        'road',
        'living_street',
        -- 'track',
        'trunk',
        'trunk_link',
        'residential'
    )
),
node (id, geom) as (
    select row_number() over (order by geom), geom
    from (
        select startpoint from edge
        union all
        select endpoint from edge
    ) _ (geom)
    group by geom
)
select edge.id, edge.geog, source.id, target.id, edge.cost, edge.cost r
from edge
join node as source on edge.startpoint = source.geom
join node as target on edge.endpoint = target.geom;

-- with in_edge (id, in_id) as (
--     select id, unnest(in_edges)
--     from auvergne_road_vertex
-- ),
-- out_edge (id, out_id) as (
--     select id, unnest(out_edges)
--     from auvergne_road_vertex
-- )
-- select osm_id, geog, out_edge.id, in_edge.id, st_length(geog)
-- from osm_auvergne e
-- join in_edge on (e.osm_id = in_id)
-- join out_edge on (e.osm_id = out_id);

grant select on table auvergne_network to person;

create index if not exists auvergne_network_geog on auvergne_network using gist (geog);
create index if not exists auvergne_network_source on auvergne_network (source);
create index if not exists auvergne_network_target on auvergne_network (target);

-- drop view if exists route cascade;
create or replace view route (geom, cost, "group", style, tooltip)
with (security_invoker) as
with q (qs) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
),
palette (palette) as materialized (
    select array_agg(format(
        '#%s00%s',
        lpad(to_hex(r), 2, '0'),
        lpad(to_hex(0xff - r), 2, '0')
    ))
    from generate_series(0, 0xff) r
),
location (point) as (
    select coalesce((qs->>'location')::point, location)
    from person_detail, q
    where person_id = current_person_id()
),
start (vid) as (
    select source
    from auvergne_network, location
    order by geog <-> ST_Point(point[1], point[0], 4326)
    limit 1
),
"end" (vid) as (
    select target
    from finding_list,
    lateral (
        select target
        from auvergne_network
        order by geog <-> ST_Point(location[1], location[0], 4326)
        limit 1
    )
)
-- start (h3) as (
--     select h3
--     from roads_h3_r8 r, location
--     order by h3_latlng_to_cell(point(point[1], point[0]), 8) <-> r.h3
--     limit 1
-- ),
-- "end" (h3, cost) as (
--     select h3, road_length_m
--     from finding_list, lateral (
--         select h3, road_length_m
--         from roads_h3_r8 r
--         order by h3_latlng_to_cell(location, 8) <-> r.h3
--         limit 1
--     ) l
-- )
-- select h3_cell_to_geometry(h3_grid_path_cells(
--     -- h3_latlng_to_cell(point(location.point[1], location.point[0]), 8),
--     start.h3,
--     "end".h3
-- )), cost, 'route',
-- jsonb_build_object(
--     'color', palette[width_bucket(cost, 0, max(cost) over (), 0xff)]
-- ),
-- cost::text
-- from start, "end", palette

select ST_LineMerge(edge.geog::geometry), path.agg_cost, 'route', jsonb_build_object(
    'color', palette[width_bucket(path.agg_cost + 1, 0, max(path.agg_cost) over () + 1, 0xff)]
), jsonb_set(tags, '{length}', path.agg_cost::text::jsonb)::text
from palette, start, pgr_dijkstra(
    'select id, source, target, cost, reverse_cost from auvergne_network', 
    start.vid,
    array(select vid from "end"),
    directed => true
) path
join auvergne_network edge on (path.edge = edge.id)
join osm_auvergne a on (a.osm_id = edge.id)
;

grant select on table route to person;

create or replace view good_marker (geom, id, popup, "group")
with (security_invoker) as
select ST_Point(location[1], location[0], 4326), good_id, html, 'good' -- why is lat-lng inverted?
from finding_list;

grant select on table good_marker to person;

create or replace view "findings" (html)
with (security_invoker)
as with q (qs) as (
    select nullif(current_setting('httpg.query', true), '')::jsonb->'qs'
),
control (html) as (
    select xmlelement(name div,
        xmlelement(name div, xmlattributes('flashes onhover' as class),
            xmlelement(name article, xmlattributes('blue card' as class), _('findings.help')::xml)
        ),
        xmlelement(name div, xmlattributes('grid searches' as class),
            xmlelement(name nav,
                xmlelement(name h4, _('Mes alertes en cours: ')),
                xmlelement(name ul, (
                    with result as (
                        select *
                        from search
                        where person_id = current_person_id()
                        order by at desc, query asc
                        limit 100
                    )
                    select coalesce(xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
                        url('/query', jsonb_build_object(
                            'q', query,
                            'sql', 'table head union all table "findings"',
                            'use_primary', null
                        )) as href
                    ), query)) order by at desc, query asc), '')
                    from result
                )),
                (select _('Nothing yet.')::xml where not exists (
                    select from search
                    where person_id = current_person_id()
                    limit 1
                ))
            ),
            xmlelement(name div,
                xmlelement(name h4, _('Ce que d''autres cherchent: ')),
                xmlelement(name ul, (
                    with result as (
                        select person.name, search.*
                        from search
                        join person using (person_id)
                        where person_id <> current_person_id()
                        order by at desc, query asc
                        limit 100
                    )
                    select coalesce(xmlagg(
                        xmlelement(name li, format(_('%s asks for %s'), name, query))
                        order by at desc, query asc
                    ), '')
                    from result
                )),
                (select _('Nothing yet.')::xml where not exists (
                    select from search
                    where person_id <> current_person_id()
                    limit 1
                ))
            )
        ),
        xmlelement(name h2, xmlattributes('hashover showhover' as class),  _('Search')),
        xmlelement(name form, xmlattributes(
            'grid' as class,
            'GET' as method,
            '/query' as action
        ),
            xmlelement(name input, xmlattributes(
                'q' as name,
                'search' as type,
                _('query') as placeholder,
                qs->>'q' as value
            )),
            xmlelement(name label, xmlattributes('inline' as class),
                '<span>rayon (km)</span>'::xml,
                xmlelement(name input, xmlattributes(
                    'distance' as name,
                    'number' as type,
                    -- '1' as min,
                    -- '500' as max,
                    -- '1' as step,
                    _('distance') as placeholder,
                    coalesce(nullif(nullif(qs->>'distance', 'null'), '')::int, 50) as value
                ))
            ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'table head union all table "findings"' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'use_primary' as name,
                null as value
            )),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Search') as value
            ))
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'redirect', url('/query', jsonb_build_object(
                        'sql', 'table head union all table "findings"',
                        'q', qs->>'q',
                        'use_primary', null
                    ))
                )) as action),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'insert into search (query) values ($1)' as value
                )),
                xmlelement(name input, xmlattributes(
                    'params[]' as name,
                    'hidden' as type,
                    qs->>'q' as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    _('Create alert') as value
                ))
            )
            where qs->>'q' <> ''
            and not exists (select from search where query = qs->>'q' and person_id = current_person_id())
            and current_person_id() is not null
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'redirect', url('/query', jsonb_build_object(
                        'sql', 'table head union all table "findings"'
                    ))
                )) as action
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'delete from search where query = $1' as value
                )),
                xmlelement(name input, xmlattributes(
                    'params[]' as name,
                    'hidden' as type,
                    qs->>'q' as value
                )),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'destructive' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Remove alert') as value
                ))
            )
            where exists (select from search where query = qs->>'q' and person_id = current_person_id())
        )
    )
    from q
),
map (html) as (
    select xmlelement(name input, xmlattributes(
        'cpres-map' as is,
        -- 'readonly' as readonly,
        'hidden' as type,
        'map' as id,
        url('/query', jsonb_build_object('sql', $$
            select coalesce(jsonb_agg(feature), '[]')::text
            from (
                select ST_AsGeoJSON(route)::jsonb from route
                union all
                select ST_AsGeoJSON(good_marker)::jsonb from good_marker
            ) _ (feature)
        $$)) as href,
        location as value,
        (
            select coalesce(jsonb_agg(feature), '[]')
            from (
                select ST_AsGeoJSON(route)::jsonb from route
                union all
                select ST_AsGeoJSON(good_marker)::jsonb from good_marker
                union all
                select ST_AsGeoJSON(b)::jsonb from auvergne_boundary b
                -- union all
                -- select ST_AsGeoJSON(n)::jsonb from (
                --     select edge.geog geom, a.tags::text tooltip
                --     from auvergne_network edge
                --     join osm_auvergne a on (edge.id = a.osm_id)
                -- ) n
                -- limit 10000
            ) _ (feature)
        ) as "data-geojson",
        (
            with extent (geom) as (
                select ST_Extent(b.geom)::geometry from auvergne_boundary b
            )
            select ST_AsGeoJSON(e)::jsonb from extent e
        ) as "data-bounds"
    ), '')
    from person_detail
    where person_id = current_person_id()
)
select html::text from control
union all select xmlelement(name div, format(_('%s results'), count(*)))::text from finding_list
union all select xmlelement(name div, xmlattributes('grid search-results' as class),
    xmlelement(name div, (select xmlagg(html) from map where exists (select from finding_list limit 1))),
    xmlelement(name div, xmlattributes('list' as class), (select xmlagg(html order by sort) from finding_list))
)::text
union all select _('Nothing yet.') where not exists (select from finding_list limit 1)
;

grant select on table "findings" to person;

create or replace view head (html)
with (security_invoker)
as with q (q) as (
    select current_setting('httpg.query', true)::jsonb
)
select $html$<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>cpres</title>
    <meta name="color-scheme" content="dark light" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css" />
    <link rel="stylesheet" href="/cpres/index.css?v=4" />
    <script type="module" src="/cpres/webcomponent/map.js?v=2"></script>
    <script type="module" src="/cpres/cpres.js?v=5"></script>
</head>
$html$
union all (
    select xmlelement(name form, xmlattributes(
        'grid hashover' as class,
        'POST' as method,
        url('/email', jsonb_build_object(
            'redirect', url('/', jsonb_build_object(
                'flash[green]', 'Check your emails'
            ))
        )) as action
    ),
        xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, 'select * from cpres.send_login_email($1, $2, $3)' as value)),
        xmlelement(name input, xmlattributes(
            'email' as type,
            'params[]' as name,
            'email' as placeholder,
            'required' as required,
            'Notification.requestPermission()' as onfocus
        )),
        xmlelement(name input, xmlattributes('hidden' as type, 'params[]' as name, 'location' as class, 'off' as autocomplete)),
        xmlelement(name input, xmlattributes('hidden' as type, 'params[]' as name, 'push_endpoint' as class, 'off' as autocomplete)),
        xmlelement(name input, xmlattributes('submit' as type, _('Send login challenge') as value))
    )::text
    from q
    where current_person_id() is null
)
union all (
    select xmlelement(name div, xmlattributes('flashes onhover' as class),
        xmlelement(name article, xmlattributes('blue card' as class), _('Authentifiez vous pour pouvoir ajouter des annonces, mémoriser vos recherches et discuter de vos dons et demandes.'))
    )::text
    where current_person_id() is null
)
union all (
    select $html$
        <form method="GET" action="/login">
            <input type="text" name="login_challenge" placeholder="login_challenge" />
            <input type="hidden" name="redirect" value="referer" />
            <input type="submit" value="Login" />
        </form>
    $html$
    from q
    where (q->'qs'->>'debug') is not null
)
union all select xmlelement(name nav, xmlattributes('menu' as class),
    xmlelement(name ul, (
        with menu (name, sql, visible) as ( values
            (
                'Search',
                'table head union all table "findings"',
                true
            ),
            (
                'Giving activity',
                'table head union all table "giving activity"',
                current_person_id() is not null
            ),
            (
                'Receiving activity',
                'table head union all table "receiving activity"',
                current_person_id() is not null
            ),
            (
                'my goods',
                'table head union all select html from "good admin"',
                current_person_id() is not null
            ),
            (
                'About',
                'table head union all select html::text from about',
                true
            )
        ),
        item (html) as (
            select xmlelement(name a, xmlattributes(
                url('/query', jsonb_build_object(
                    'sql', sql
                )) as href
            ), _(name))
            from menu, q
            where visible
        ),
        profile (html) as (
            select xmlelement(name form, xmlattributes(
                    'POST' as method,
                    '/query?redirect=/' as action,
                    'inline' as class,
                    'this.submit()' as onchange
            ),
                _('Welcome '),
                xmlelement(name input, xmlattributes(
                    'text' as type,
                    'params[]' as name,
                    'inline-name' as class,
                    _('name') as placeholder,
                    greatest(4, length(name)) as size,
                    'required' as required,
                    name as value
                )),
                ' ',
                xmlelement(name input, xmlattributes(
                    'tel' as type,
                    'params[]' as name,
                    'inline-name' as class,
                    _('phone') as placeholder,
                    greatest(4, length(phone)) as size,
                    'required' as required,
                    phone as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    $$update person set name = $1, phone = nullif($2, '') where person_id = current_person_id()$$ as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'on_error' as name,
                    'table head union all table "findings"' as value
                ))
            )
            from person
            where person_id = current_person_id()
        ),
        "all" (html) as (
            select html from profile
            union all
            select html from item
            union all
            select xmlelement(name a, xmlattributes('/logout' as href), _('Logout'))
            where current_person_id() is not null
            union all
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'sql', 'call delete_account()',
                    'redirect', '/logout'
                )) as action
            ),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'destructive' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Delete account') as value
                ))
            )
            where current_person_id() is not null
        )
        select xmlagg(xmlelement(name li, html))
        from "all"
        limit 1
    ))
)::text
union all (
    with m (color, m) as (
        select m.key, xmltext(_(m.value)) from q, jsonb_each_text(q->'qs'->'flash') m
        union all (
            select 'yellow', xmlelement(name a, xmlattributes(
                (url('/query', jsonb_build_object(
                    'sql', 'table head union all table "receiving activity"'
                )) || '#' || good.title) as href
            ), format(_('%s is waiting for you on %s'), giver.name, good.title))
            from interest
            join good using (good_id)
            join person giver on (giver.person_id = good.giver)
            where at < now()
            and state in ('approved', 'late')
            and interest.person_id = current_person_id()
            order by at desc
            limit 10
        )
        union all (
            with error (error) as (
                select nullif(current_setting('httpg.errors', true), '')::jsonb
            )
            select 'red', _(error->>'error')::xml
            from error
            where error is not null
        )
    )
    select xmlelement(name div, xmlattributes('flashes' as class), coalesce(xmlagg(xmlelement(name article, xmlattributes(
        color || ' card' as class
    ), m))), '')::text
    from m
)
;
grant select on table head to person;

create or replace view about (html)
with (security_invoker)
as select xmlelement(name h2, _('About'))
union all select xmlelement(name p, 'Fait avec amour et passion par Florian Klein.')
union all select xmlelement(name a, xmlattributes('https://github.com/docteurklein/httpg' as href), 'code source')
union all select xmlelement(name h2, 'Mentions légales')
union all select xmlelement(name p, '
    Editeur: Florian Klein <br/>
    florian.klein@free.fr <br/>
    Hébergé en europe sur google cloud et neon.tech.
'::xml)
union all select xmlelement(name h2, 'Politique de confidentialité')
union all select xmlelement(name pre, $$
Les administrateurs s’engagent à ce que la collecte et le traitement de vos données, effectués à partir du portail economie.gouv.fr, soient conformes au règlement général sur la protection des données (RGPD) et à la loi Informatique et Libertés.

En application de la réglementation relative à la protection des données personnelles (le Règlement UE 2016/679 et la Loi Informatique et Libertés du 6 janvier 1978), le Bureau de l'assistance et des technologies numériques traite les données recueillies pour gérer et traiter vos demandes. Vous disposez d'un droit d'accès, de rectification, d'effacement, de limitation et d'opposition sur vos données. Vous pouvez exercer ce droit en envoyant un courrier à :

Ministères économiques et financiers
SG-SIRCOM, Bureau de l'assistance et des technologies numériques
teledoc 581
139 rue de Bercy
75572 Paris cedex 12

En cas de non-conformité relative au traitement de vos données, vous avez le droit d'introduire une réclamation auprès de l’autorité de contrôle, la CNIL, 3, Place de Fontenoy TSA 80715 75334 PARIS Cedex 07.
$$)
union all select xmlelement(name h2, 'Cookies')
union all select xmlelement(name pre, $$
Seul 1 cookie essentiel est utilisé pour maintenir l'utilisateur connecté.
$$)
union all select xmlelement(name h2, 'Données personnelles')
union all select xmlelement(name pre, $$
Seul votre email est nécessairement stocké pour garantir de pouvoir se reconnecter.
vous pouvez optionnellement stocker votre pseudonyme et votre numéro de téléphone si vous souhaitez être contacté par les autres utilisatuers du site.
Votre position géographique (tel que renseignée par votre navigateur) peut être sauvegardée si vous le désirez pour faciliter la recherche locale de biens et calculer les distances de trajets.

Vous pouvez à tout moment effacer ces données optionnelles, voire même l'entiereté de votre compte, auquel cas **toutes** vos données sont instantanément éffacées.
$$)
;
grant select on table about to person;
