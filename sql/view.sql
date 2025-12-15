\set ON_ERROR_STOP on

set local search_path to cpres, url, pg_catalog, public;

create or replace function cpres._(id_ text, lang_ text = null)
returns text
immutable parallel safe -- leakproof
security definer
set search_path to cpres, pg_catalog
language sql
begin atomic
    select coalesce(
        (
            with a (accept_language) as (
                select substring(current_setting('httpg.query', true)::jsonb->>'accept_language' from '^(\w+)-?\w*,?.*')
            )
            select text
            from translation, a
            where (id, lang) = (id_, coalesce(lang_, accept_language, 'fr'))
            limit 1
        ),
        id_
    );
end;

create or replace function geojson(point point, props jsonb = '{}') returns jsonb
language sql 
immutable strict parallel safe -- leakproof
set search_path to cpres, pg_catalog
begin atomic;
    select jsonb_build_object(
        'type', 'Feature',
        'properties', props,
        'geometry', jsonb_build_object(
            'type', 'Point',
            'coordinates', array[point[1], point[0]]
        )
    );
end;

grant execute on function geojson to person;

create or replace view "good_detail" (html, location, bird_distance_km, good_id, receiver)
with (security_invoker)
as with receiver (location) as (
    select location from person_detail where person_id = current_person_id() limit 1
),
base as (
    select good.*, giver.name as giver_name,
        case when receiver.location is not null then (good.location <@> receiver.location) * 1.609347 end bird_distance_km
    from good
    join person giver on (good.giver = giver.person_id)
    left join receiver on true
)
select xmlelement(name article, xmlattributes(
    geojson(good.location) as "data-geojson"
),
    xmlelement(name h2, xmlelement(name a, xmlattributes(
        url('/query', jsonb_build_object(
            'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
            'params[]', good.good_id
        )) as href
    ), good.title)),
    xmlelement(name span, format(_('By %s'), giver_name)),
    xmlelement(name p, good.description),
    case when bird_distance_km is not null then
        xmlelement(name div, format('distance: %s km', round(bird_distance_km::numeric, 2)))
    end,
    xmlelement(name div, xmlattributes('grid media' as class), coalesce((
        select xmlagg(xmlelement(name article, xmlattributes('card' as class),
            (
                with url (url) as (
                    select url('/query', jsonb_build_object(
                        'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                        'params[]', content_hash,
                        'accept', content_type
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
        where good_id = good.good_id
    ), '')),
    (
        select xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object(
                'sql', format('call cpres.want(%L, $1)', good.good_id),
                'redirect', 'referer'
            )) as action,
            'grid' as class
        ),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'a little interested' as value,
                'submit' as type
            ), _('a little interested')),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'interested' as value,
                'submit' as type
            ), _('interested')),
            xmlelement(name button, xmlattributes(
                'params[]' as name,
                'highly interested' as value,
                'submit' as type
            ), _('highly interested'))
        )
        where not exists (
            select from interest
            where good.good_id = interest.good_id
            and interest.person_id = current_person_id()
        )
        and current_person_id() is not null
        and current_person_id() <> good.giver
    ),
    (
        select xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object(
                'sql', format('call cpres.unwant(%L)', good.good_id),
                'redirect', 'referer'
            )) as action,
            'grid' as class
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
        and current_person_id() <> good.giver
    )
)::text, good.location, 0, good.good_id, good.receiver
from base good;

grant select on table "good_detail" to person;

create or replace view nearby (geojson, bird_distance_km)
with (security_invoker)
as select geojson(location, jsonb_build_object(
    'description', html,
    'bird_distance_km', bird_distance_km
)) geojson, bird_distance_km
from "good_detail"
where receiver is null;
;

grant select on table nearby to person;

create or replace function good_form(id text, params jsonb, sql text) returns xml
security invoker
immutable parallel safe -- leakproof
language sql
begin atomic
with query (q, good_id, redirect, errors) as (
    with q (q, errors) as (
        select coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}'),
        coalesce(nullif(current_setting('httpg.errors', true), '')::jsonb, '{}')
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
                'sql', 'table cpres.head union all select html from cpres."good admin"',
                'flash[green]', _('Saved successfully')
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
        coalesce(q->'body'->>'on_error', q->'qs'->>'sql', 'table cpres.head union all select html from cpres."good admin"') as value
    )),
    xmlelement(name input, xmlattributes(
        'text' as type,
        'params[0]' as name,
        _('title') as placeholder,
        true as required,
        params->>0 as value
    )),
    xmlelement(name textarea, xmlattributes(
        'params[1]' as name,
        'description' as placeholder
    ), coalesce(params->>1, '')),
    xmlelement(name input, xmlattributes(
        'text' as type,
        'params[2]' as name,
        _('location: (lat,lng)') as placeholder,
        'location' as class,
        '\(.+,.+\)' as pattern,
        true as required,
        params->>2 as value
    )),
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
    select coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}')
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
            format('update cpres.good set title = $1::text, description = $2::text, location = $3::text::point where good_id = %L', good_id)
        ),
        xmlelement(name div, xmlattributes('grid media' as class), coalesce((
            select xmlagg(xmlelement(name article, xmlattributes('card' as class),
                (
                    with url (url) as (
                        select url('/query', jsonb_build_object(
                            'sql', 'select content from cpres.good_media where content_hash = $1::text::bytea',
                            'params[]', content_hash,
                            'accept', content_type
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
                    '/query' as action,
                    'grid' as class
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
                            delete from cpres.good_media
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
                'grid' as class,
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
                        insert into cpres.good_media (good_id, name, content, content_type)
                        select %L, convert_from(f[3], 'UTF8'), f[1], convert_from(f[2], 'UTF8')
                        from f
                        where f[1] <> ''
                        on conflict (good_id, content_hash) do nothing
                    $$, good_id) as value
                )),
                xmlelement(name input, xmlattributes(
                    'file' as type,
                    'file' as name,
                    true as required
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
            '/query' as action,
            'grid' as class
        ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'redirect' as name,
                'referer' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'delete from cpres.good where good_id = $1::uuid' as value
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
        'insert into cpres.good (title, description, location) values ($1, $2, $3::point)'
    ),
    xmlelement(name h2, _('Existing goods'))
)::text
from query
union all select xmlelement(name div, xmlattributes('grid good' as class),
    array_agg(html)
)::text
from result
-- group by good_id
union all select _('Nothing yet.') where not exists (select from result limit 1)
;

grant select on table "good admin" to person;

create or replace view "giving activity" (html)
with (security_invoker)
as with data (good_id, title, given) as (
    select good_id, title, exists (select from interest where good_id = good.good_id and state in ('approved', 'late', 'given'))
    from good
    where giver = current_person_id()
    and exists (select from interest where good_id = good.good_id)
    order by
        coalesce(good.updated_at, good.created_at) desc
),
html (html) as (
    select xmlelement(name article, xmlattributes('card' as class),
        xmlelement(name h2, xmlelement(name a, xmlattributes(
            url('/query', jsonb_build_object(
                'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
                'params[]', good_id
            )) as href
        ), title)),
        xmlelement(name div, xmlattributes('grid interest' as class), (
            select xmlagg(
                xmlelement(name article, xmlattributes('card' as class),
                    xmlelement(name div, xmlattributes('inline' as class),
                        xmlelement(name h4, format(_('%s is %s'), receiver.name, _(interest.level))),
                        case when receiver.phone is not null then
                            xmlconcat(xmlelement(name a, xmlattributes(
                                format('tel:%s', receiver.phone) as href,
                                'tel' as class
                            ), receiver.phone),
                            xmlelement(name a, xmlattributes(
                                format(_('https://wa.me/%s?text=About receiving %s'), receiver.phone, title) as href,
                                'whatsapp' as class
                            ), '✆'))
                        end
                    ),
                    (
                        with message as (
                            select *
                            from message
                            where (message.good_id, message.person_id) = (interest.good_id, interest.person_id)
                            order by at asc
                        )
                        select xmlelement(name div, xmlattributes('messages' as class), coalesce(xmlagg(xmlelement(name article,
                            format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))),
                            xmlelement(name pre, content)
                        )), ''))
                        from message
                        join person author on (author.person_id = message.author)
                    ),
                    xmlelement(name form, xmlattributes(
                        'POST' as method,
                        url('/query', jsonb_build_object(
                            'redirect', 'referer'
                        )) as action,
                        'grid' as class
                    ),
                        xmlelement(name input, xmlattributes(
                            'hidden' as type,
                            'sql' as name,
                            format('insert into cpres.message (good_id, person_id, content) values(%L, %L, $1)', interest.good_id, interest.person_id) as value
                        )),
                        xmlelement(name textarea, xmlattributes(
                            'params[]' as name,
                            'message' as placeholder
                        ), ''),
                        xmlelement(name input, xmlattributes(
                            'submit' as type,
                            _('Send message') as value
                        ))
                    ),
                    case when interest.state in ('approved', 'late', 'given')
                        then xmltext(_('Winner'))
                        when not given then xmlelement(name form, xmlattributes(
                            'POST' as method,
                            url('/query', jsonb_build_object(
                                'sql', 'call cpres.give($1::uuid, $2::uuid)',
                                'redirect', 'referer'
                            )) as action,
                            'grid' as class
                        ),
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
            left join person_detail receiver_detail on (receiver.person_id = receiver_detail.person_id)
            where data.good_id = interest.good_id
        ))
    )
    from data
)
select xmlelement(name h2, _('Giving activity'))::text
union all select xmlelement(name div, xmlattributes('grid good' as class), coalesce(xmlagg(html), ''))::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "giving activity" to person;

create or replace view "receiving activity" (html)
with (security_invoker)
as with data (good, giver, receiver_detail, interest) as (
    select good, row(giver_.name, giver_.phone)::public_person, receiver_detail, interest
    from interest
    join good using (good_id)
    join person giver_ on (good.giver = giver_.person_id)
    left join person_detail receiver_detail on (good.receiver = receiver_detail.person_id)
    where interest.person_id = current_person_id()
    order by
        coalesce(good.updated_at, good.created_at) desc
),
html (html) as (
    select xmlelement(name article, xmlattributes('interest card' as class),
        case when (interest).origin = 'automatic' then
            xmlelement(name div,
                xmlelement(name a, xmlattributes(
                    url('/query', jsonb_build_object(
                        'sql', 'table cpres.head union all table cpres."findings"',
                        'q', (interest).query,
                        'use_primary', true
                    )) as href
                ), format('found via search: %s', (interest).query))
            )
        end,
        xmlelement(name div, xmlattributes('inline' as class),
            xmlelement(name h2, xmlelement(name a, xmlattributes(
                (good).title as id,
                url('/query', jsonb_build_object(
                    'sql', 'table cpres.head union all select html from cpres."good_detail" where good_id = $1::uuid',
                    'params[]', (good).good_id
                )) as href
            ), (good).title)),
            xmlelement(name span, format(_('By %s'), (giver).name)),
            case when (giver).phone is not null then
                xmlconcat(
                    xmlelement(name a, xmlattributes(
                        format('tel:%s', (giver).phone) as href,
                        'tel' as class
                    ), (giver).phone),
                    xmlelement(name a, xmlattributes(
                        format(_('https://wa.me/%s?text=About giving %s'), (giver).phone, (good).title) as href,
                        'whatsapp' as class
                    ), '✆')
                )
            end
        ),
        (
            with message as (
                select *
                from message
                where (message.good_id, message.person_id) = ((interest).good_id, (interest).person_id)
                order by at asc
            )
                select xmlelement(name div, xmlattributes('messages' as class), coalesce(xmlagg(xmlelement(name article,
                format(_('%s at %s: '), author.name, to_char(message.at, _('HH24:MI, TMDay DD/MM'))),
                xmlelement(name pre, content)
            )), ''))
            from message
            join person author on (author.person_id = message.author)
        ),
        xmlelement(name form, xmlattributes(
            'POST' as method,
            url('/query', jsonb_build_object(
                'redirect', 'referer'
            )) as action,
            'grid' as class
        ),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                format('insert into cpres.message (good_id, person_id, content) values(%L, %L, $1)', (interest).good_id, (interest).person_id) as value
            )),
            xmlelement(name textarea, xmlattributes(
                'params[]' as name,
                'message' as placeholder
            ), ''),
            xmlelement(name input, xmlattributes(
                'submit' as type,
                _('Send message') as value
            ))
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'sql', format('call cpres.unwant(%L)', (good).good_id),
                    'redirect', 'referer'
                )) as action,
                'grid' as class
            ),
                xmlelement(name input, xmlattributes(
                    'submit' as type,
                    'destructive' as class,
                    format('return confirm(%L)', _('Are you sure?')) as onclick,
                    _('Not interested anymore') as value
                ))
            )
        )
    )
    from data
)
select xmlelement(name h2, _('Receiving activity'))::text
union all select xmlelement(name div, xmlattributes('grid good' as class), coalesce(xmlagg(html), ''))::text from html
union all select _('Nothing yet.') where not exists (select from html limit 1)
;

grant select on table "receiving activity" to person;

create or replace view "findings" (html)
with (security_invoker)
as with q (qs) as (
    select coalesce(nullif(current_setting('httpg.query', true), '')::jsonb, '{}')->'qs'
),
map (html) as (
    select $html$
        <div id="map-container">
            <div id="map"></div>
        </div>
        <script type="module" src="/cpres/map.js"></script>
    $html$::xml
),
head (html) as (
    select xmlelement(name div,
        xmlelement(name h2, _('Search')),
        xmlelement(name nav, xmlelement(name ul, (
            select coalesce(xmlagg(xmlelement(name li, xmlelement(name a, xmlattributes(
                url('/query', jsonb_build_object(
                    'q', query,
                    'sql', 'table cpres.head union all table cpres."findings"',
                    'use_primary', true
                )) as href
            ), query))), '')
            from search
        ))),
        xmlelement(name form, xmlattributes(
            'GET' as method,
            '/query' as action,
            'group' as role
        ),
            xmlelement(name input, xmlattributes(
                'q' as name,
                'search' as type,
                _('query') as placeholder,
                qs->>'q' as value
            )),
            xmlelement(name input, xmlattributes(
                'hidden' as type,
                'sql' as name,
                'table cpres.head union all table cpres."findings"' as value
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
                        'sql', 'table cpres.head union all table cpres."findings"'
                    ))
                )) as action),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'insert into cpres.search (query) values ($1)' as value
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
            and not exists (select from search where query = qs->>'q')
            and current_person_id() is not null
        ),
        (
            select xmlelement(name form, xmlattributes(
                'POST' as method,
                url('/query', jsonb_build_object(
                    'redirect', url('/query', jsonb_build_object(
                        'sql', 'table cpres.head union all table cpres."findings"'
                    ))
                )) as action,
                'grid' as class
            ),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    'delete from cpres.search where query = $1' as value
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
            where exists (select from search where query = qs->>'q')
        )
    )
    from q
),
result (good_id, rerank_distance) as (
    select good_id, case when qs->>'q' <> '' then
        rerank_distance(qs->>'q', passage)
        else -1
    end
    from q, good
    order by case when qs->>'q' <> '' then embedding <=> embed_query(qs->>'q') else 1 end
    limit 100
),
list (html) as (
    select xmlelement(name article, xmlattributes('card' as class), d.html::xml)
    from result
    join "good_detail" d using (good_id)
    where rerank_distance < 0
    and not exists (
        select from interest
        where good_id = d.good_id
        and state in ('approved', 'late', 'given')
    )
)
select html::text from head
union all select xmlelement(name div, xmlattributes('grid search-results' as class),
    xmlelement(name div, xmlattributes('list' as class), (select xmlagg(html) from list)),
    xmlelement(name div, (select html from map where exists (select from list limit 1)))
)::text
union all select _('Nothing yet.') where not exists (select from list limit 1)
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
    <link rel="stylesheet" href="/cpres/index.css" crossorigin="" />
</head>
<body>
  <script type="module" src="/cpres.js"></script>
  <main class="container-fluid">
$html$
union all (
    select xmlelement(name form, xmlattributes(
        'POST' as method,
        url('/email', jsonb_build_object(
            'redirect', url('/', jsonb_build_object(
                'flash[green]', _('Check your emails')
            ))
        )) as action
    ),
        xmlelement(name input, xmlattributes('hidden' as type, 'sql' as name, 'select * from cpres.send_login_email($1, $2)' as value)),
        xmlelement(name input, xmlattributes('email' as type, 'params[]' as name, 'email' as placeholder, true as required)),
        xmlelement(name input, xmlattributes('hidden' as type, 'params[]' as name, 'location' as class)),
        xmlelement(name input, xmlattributes('submit' as type, _('Send login challenge') as value))
    )::text
    from q
    where current_person_id() is null
)
union all (
    with m (color, m) as (
        select m.key, xmltext(m.value) from q, jsonb_each_text(q->'qs'->'flash') m
        union all (
            select 'yellow', xmlelement(name a, xmlattributes(
                (url('/query', jsonb_build_object(
                    'sql', 'table cpres.head union all table cpres."receiving activity"'
                )) || '#' || good.title) as href
            ), format(_('%s is waiting for you on %s'), giver.name, good.title))
            from interest
            join good using (good_id)
            join person giver on (giver.person_id = good.giver)
            where at < now() - interval '3 days'
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
union all select xmlelement(name nav,
    xmlelement(name ul, (
        with menu (name, sql, visible) as ( values
            (_('Search'), 'table cpres.head union all table cpres."findings"', true),
            (_('Giving activity'), 'table cpres.head union all table cpres."giving activity"', current_person_id() is not null),
            (_('Receiving activity'), 'table cpres.head union all table cpres."receiving activity"', current_person_id() is not null),
            (_('my goods'), 'table cpres.head union all select html from cpres."good admin"', current_person_id() is not null),
            (_('About'), 'table cpres.head union all select html::text from cpres.about', true)
        ),
        item (html) as (
            select xmlelement(name a, xmlattributes(
                url('/query', jsonb_build_object(
                    'sql', sql
                )) as href
            ), name)
            from menu, q
            where visible
        ),
        auth (html) as (
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
                    greatest(1, length(name)) as size,
                    true as required,
                    name as value
                )),
                xmlelement(name input, xmlattributes(
                    'tel' as type,
                    'params[]' as name,
                    'inline-name' as class,
                    _('phone') as placeholder,
                    greatest(1, length(phone)) as size,
                    true as required,
                    phone as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'sql' as name,
                    $$update cpres.person set name = $1, phone = nullif($2, '') where person_id = current_person_id()$$ as value
                )),
                xmlelement(name input, xmlattributes(
                    'hidden' as type,
                    'on_error' as name,
                    'table cpres.head union all table cpres."findings"' as value
                ))
            )
            from person
            where person_id = current_person_id()
        ),
        "all" (html) as (
            select html from auth
            union all
            select html from item
            union all 
            select xmlelement(name a, xmlattributes('/logout' as href), _('Logout'))
            where current_person_id() is not null
        )
        select xmlagg(xmlelement(name li, html))
        from "all"
        limit 1
    ))
)::text
;
grant select on table head to person;

create or replace view about (html)
as select xmlelement(name h2, _('About'))
union all select xmlelement(name p, 'Fait avec amour et passion par Florian Klein.')
union all select xmlelement(name a, xmlattributes('https://github.com/docteurklein/httpg' as href), 'code source')
;
grant select on table about to person;
