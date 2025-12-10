\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

\ir url.sql
\ir ddl.sql
\ir translation.sql
\ir proc.sql
\ir view.sql
\ir fixtures.sql
\ir cron.sql
