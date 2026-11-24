create or replace function public.index() returns table (status int, header jsonb)
volatile strict parallel safe -- leakproof
language sql
begin atomic
    select 307, jsonb_build_object(
        'Location', case httpg.query()->>'base_path'
            when 'grandroc' then url.url('/grandroc/query', jsonb_build_object(
                'sql', 'select * from grandroc.head'
            ))
        end
    );
end;

grant execute on function index() to anon, grandroc, jmeu;

