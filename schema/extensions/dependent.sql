-- require: extensions.sql
create extension if not exists pgrouting with schema public cascade;
create extension if not exists postgis_raster with schema public cascade;
create extension if not exists h3_postgis with schema public cascade;

