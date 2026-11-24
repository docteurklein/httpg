create or replace function public.login(name text) returns setof text
volatile strict parallel safe -- leakproof
language plpgsql
security definer
set search_path to cpres, gieze, pg_catalog
as $$
begin
    case name
        when 'cpres' then return query select * from cpres.login_cpres();
        when 'gieze' then return query select * from gieze.login();
        when 'grandroc' then return query select * from grandroc.login();
        when 'jmeu' then return query select * from jmeu.login();
    end case;
end;
$$;

grant execute on function login(text) to person, httpg, anon;
