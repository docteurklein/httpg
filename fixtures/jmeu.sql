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


