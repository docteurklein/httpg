\set ON_ERROR_STOP on

set local search_path to grandroc, url, pg_catalog, public;

alter table place drop column if exists cleaning_price cascade;
alter table booking add column cleaning_price amount;

alter table booking drop constraint booking_place_fkey;
alter table booking add constraint booking_place_fkey  foreign key (place) references place (place) on update cascade on delete cascade;

alter table booking drop constraint booking_occupant_fkey;
alter table booking add constraint booking_occupant_fkey  foreign key (occupant) references occupant (occupant) on update cascade on delete cascade;


