set local search_path to jmeu, pg_catalog, public;

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into tenant (tenant_id, name, password, salt)
select '01a163a9-dc7b-7d9c-9ef6-febdafae6ccb', 'jmeu', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into tenant (name, password, salt)
select 'other', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;


with grandmother as (
    insert into animal (tenant_id, number, lot, birth, sex)
    select tenant_id, random(), random(1, 4), now() - format('%s years', random(2, 10))::interval, 'Femelle'
    from tenant, generate_series(1, 3)
    returning *
),
mother as (
    insert into animal (tenant_id, number, lot, mother, birth, sex)
    select tenant_id, random(), random(1, 4), number, now() - format('%s months', random(7, 20))::interval, 'Femelle'
    from grandmother, generate_series(1, 4)
    returning *
)
insert into animal (tenant_id, number, lot, mother, birth, sex)
select tenant_id, name || random(), random(1, 4), number, now() - format('%s days', random(20, 300))::interval, 'Mâle'
from generate_series(1, 5), mother
join tenant using (tenant_id)
;

insert into medication (tenant_id, name, posology)
select tenant_id, 'medoc ' || random(2, 200), format('%smL par kg', random(10, 70))
from tenant, generate_series(1, 3);

insert into treatment (tenant_id, number, at, ordonnance, medication_id)
select tenant_id, number, now() - format('%s days', random(20, 300))::interval, 'ordonnance ' || random(20, 800), medication_id
from animal
join medication using (tenant_id);


