\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

create extension if not exists pg_cron;

SELECT cron.schedule(
    'remind-interest',
    '0 * * * *',  -- every hour
    'call cpres.mark_late_interests()'
);
