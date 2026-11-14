-- Sticky Ten istekleri (ISTEKLER.md, 2026-11-14).
-- ST-6: sticky.rating_uygula: rating artışı ve rating_log kaydı tek işlemde; okuyup mutlak değer yazmaz
--       (aynı anda biten iki oyun birbirinin üstüne yazamaz; günlük yazılamazsa rating de değişmez). Yalnız servis rolü.
-- ST-7: sticky.siralama p_kullanici alır (yalnız servis rolünde geçerli): `ben` satırı ilk 500 dışında da gelir.

create function sticky.rating_uygula(p_kullanici uuid, p_delta real, p_gun text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if p_kullanici is null or p_delta is null or p_gun !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'gecersiz'; end if;
  insert into sticky.stats as s (user_id, rating, rated_games, rated_day, rated_today)
    values (p_kullanici, 1200 + p_delta, 1, p_gun, 1)
    on conflict (user_id) do update set
      rating = s.rating + p_delta,
      rated_games = s.rated_games + 1,
      rated_today = case when s.rated_day = p_gun then s.rated_today + 1 else 1 end,
      rated_day = p_gun
    returning s.rating, s.rated_games, s.rated_today into r;
  insert into sticky.rating_log (user_id, delta) values (p_kullanici, p_delta);
  return jsonb_build_object('rating', r.rating, 'rated_games', r.rated_games, 'rated_today', r.rated_today);
end $$;
revoke execute on function sticky.rating_uygula(uuid, real, text) from public, anon, authenticated;
grant execute on function sticky.rating_uygula(uuid, real, text) to service_role;

drop function sticky.siralama(text, int, timestamptz);
create function sticky.siralama(p_donem text, p_ilk int default 100, p_baslangic timestamptz default null,
                                p_kullanici uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  bas timestamptz := coalesce(p_baslangic, sticky.donem_baslangici(p_donem));
  en_az int := case p_donem when 'gun' then 3 when 'hafta' then 5 when 'ay' then 10 else 10 end;
  -- ST-7: servis rolü (Sticky sunucusu) oyuncunun kimliğini verir; başka çağıranda p_kullanici yok sayılır.
  ben uuid := coalesce(case when auth.role() = 'service_role' then p_kullanici end, auth.uid());
  r jsonb;
begin
  if p_donem not in ('gun', 'hafta', 'ay', 'tum') then raise exception 'donem_gecersiz'; end if;
  p_ilk := least(greatest(p_ilk, 1), 500);
  with s as (
    select x.user_id, x.deger, x.oyun, o.ad
    from (
      select st.user_id, st.rating::numeric as deger, st.rated_games as oyun
      from sticky.stats st where p_donem = 'tum' and st.rated_games >= en_az
      union all
      select l.user_id, sum(l.delta)::numeric, count(*)::int
      from sticky.rating_log l where p_donem <> 'tum' and l.at >= bas
      group by l.user_id having count(*) >= en_az
    ) x
    join ortak.oyuncular o on o.oyun_id = 'sticky' and o.kullanici_id = x.user_id and o.ad is not null
  ),
  sirali as (select s.*, row_number() over (order by deger desc, oyun desc) as sira from s)
  select jsonb_build_object(
    'toplam', (select count(*) from sirali),
    'ben', (select jsonb_build_object('sira', sira, 'deger', deger, 'oyun', oyun) from sirali where user_id = ben),
    'satirlar', coalesce((select jsonb_agg(jsonb_build_object('sira', sira, 'ad', ad, 'deger', deger, 'oyun', oyun,
                                                              'ben', coalesce(user_id = ben, false)) order by sira)
                          from sirali where sira <= p_ilk), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke execute on function sticky.siralama(text, int, timestamptz, uuid) from public;
grant execute on function sticky.siralama(text, int, timestamptz, uuid) to anon, authenticated, service_role;
