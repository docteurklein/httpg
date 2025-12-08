\set ON_ERROR_STOP on

set local search_path to cpres, pg_catalog, public;

\ir url.sql
\ir ddl.sql
\ir view.sql
\ir fixtures.sql
