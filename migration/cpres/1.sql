
\set ON_ERROR_STOP on

set search_path to cpres;

begin; 
alter table person drop constraint person_name_check;
alter table person add constraint person_name_check  check (trim(name) <> '' and position('@' in name) = 0) not valid;

alter table person drop constraint person_email_check;
alter table person add constraint person_email_check  check (trim(email) <> '' and position('@' in email) <> 0) not valid;

commit;

begin;
set local lock_timeout to '50ms';

alter table person validate constraint person_name_check;
alter table person validate constraint person_email_check;

commit;
