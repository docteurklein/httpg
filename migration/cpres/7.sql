
set search_path to cpres;
set lock_timeout to '50ms';

select exists (
    select from pg_constraint
    where conname in ('interest_state_check', 'interest_origin_check')
    and connamespace = to_regnamespace('cpres')
    limit 1
) needs_work;
\gset

select :'needs_work';

\if :needs_work
    \timing on
    begin;

    drop procedure want;
    drop procedure give;
    drop procedure mark_late_interests;
    drop function interest_control cascade;
    drop view "giving activity";
    drop view head;

    alter domain interest_level rename to interest_level_old;
    create type interest_level as enum ('a little interested', 'interested', 'highly interested');
    create type interest_state as enum ('in progress', 'late', 'approved', 'given');
    create type interest_origin as enum ('automatic', 'manual');
    
    alter table interest drop constraint if exists interest_level_check;
    alter table interest alter column level type interest_level using level::interest_level;
    alter table interest alter column level set default 'interested';
    
    alter table search alter column interest type interest_level using interest::interest_level;
    alter table search alter column interest set default 'interested';

    alter table interest drop constraint if exists interest_state_check;
    alter table interest alter column state drop default;
    alter table interest alter column state type interest_state using state::interest_state;
    alter table interest alter column state set default 'in progress';

    alter table interest drop constraint if exists interest_origin_check;
    alter table interest alter column origin type interest_origin using origin::interest_origin;

    drop domain interest_level_old;
    commit;
\endif

