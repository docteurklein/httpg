with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into admin (name, password, salt)
select 'admin', crypt(:'password', salt), salt
from salt
on conflict (name) do nothing;


