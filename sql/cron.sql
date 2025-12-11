\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

create extension if not exists pg_cron;

select cron.alter_job(
    cron.schedule(
        'remind-interest',
        '0 * * * *',  -- every hour
        'call cpres.mark_late_interests()'
    ),
    username => 'httpg'
);
