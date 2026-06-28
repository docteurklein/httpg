\set ON_ERROR_STOP on

set local search_path to gieze, public;

truncate client cascade;
truncate product cascade;
truncate admin cascade;

insert into client values
('maison du sichon', '1 rue du sichon', '1 rue du sichon'),
('bio coop', '1 rue de la coop', '1 rue de la coop');

insert into product values
('grand duc', 3.25::amount, 0.055),
('crotte de fée', 1.50::amount, 0.055);

insert into bl values
(1, 'maison du sichon', now() - interval '1 month', now()),
(2, 'maison du sichon', now(), null),
(3, 'bio coop', now(), null);

alter sequence bl_bl_seq restart with 4;

insert into bl_line values
(1, 'grand duc', 2),
(1, 'crotte de fée', 4),
(2, 'grand duc', 7),
(2, 'crotte de fée', 1),
(3, 'crotte de fée', 11);

with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into admin (name, password, salt)
select 'flopi', crypt('flopi', salt), salt
from salt;
with salt (salt) as (
    select gen_salt('sha512crypt')
)
insert into admin (name, password, salt)
select 'admin', crypt('admin', salt), salt
from salt;
