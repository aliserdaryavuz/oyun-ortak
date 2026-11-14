-- 1) Beat Greedy ad yolu (sezgi.profiles tetikleyicisi) da misafire kapalı: ortak.ad_degistir ile aynı kural
--    (20261120000300). Beat Greedy istemcisi anonim oturum açmaz; profil yalnız e-posta/Google girişinden sonra yazılır.
-- 2) HK-17: Halka'nın artık kullanılmayan eski hk_ nesneleri kalkar (taslak ve kullanım kanıtı: halka-kelime
--    supabase/hk17_temizlik.sql). Kalanlar: hk_plays, hk_opens, hk_errors, hk_throttle, hk_retention, hk_funnel,
--    hk_entitlements, hk_push ve hk_push_* işlevleri.
-- 3) Halka hatırlatma aboneliği (hk_push_save/remove) anon role ve misafire kapanır (sahte adreslerle 100 bin tavanı
--    doldurma, adresi bilinen aboneliği silme). Hatırlatma şu an kapalı (VITE_PUSH yok).

-- ---------------------------------------------------------------- 1
create or replace function sezgi.ad_denetle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a jsonb; o ortak.oyuncular; gun int; v text := new.username::text;
begin
  -- Şikâyetle sıfırlamanın kendi yazdığı yer tutucu ad denetlenmez ve ortağa yansımaz.
  if current_setting('ortak.ad_yansitma', true) = 'kapali' then return new; end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username then return new; end if;
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli' using errcode = 'P0001'; end if;

  select coalesce(ayarlar -> 'ad', '{}') into a from ortak.oyunlar where id = 'sezgi';
  if not ortak.ad_bicimi(v, coalesce((a ->> 'en_az')::int, 3), coalesce((a ->> 'en_cok')::int, 20))
     or not ortak.ad_uygun(v, coalesce(array(select jsonb_array_elements_text(a -> 'yasakli')), '{}'))
     or exists (select 1 from ortak.engelli_adlar where oyun_id = 'sezgi' and ad_anahtari = ortak.ad_anahtari(v)) then
    raise exception 'ad_uygunsuz' using errcode = 'P0001';
  end if;

  insert into ortak.oyuncular (oyun_id, kullanici_id) values ('sezgi', new.id) on conflict do nothing;
  select * into o from ortak.oyuncular where oyun_id = 'sezgi' and kullanici_id = new.id for update;
  gun := coalesce((a ->> 'degistirme_gun')::int, 30);
  if tg_op = 'UPDATE' and o.ad_degisti is not null and o.ad_degisti > now() - make_interval(days => gun) then
    raise exception 'ad_bekle' using errcode = 'P0001',
      hint = ceil(extract(epoch from (o.ad_degisti + make_interval(days => gun) - now())) / 86400)::text;
  end if;

  begin
    update ortak.oyuncular set ad = v, ad_anahtari = ortak.ad_anahtari(v), ad_otomatik = false, ad_degisti = now()
      where oyun_id = 'sezgi' and kullanici_id = new.id;
  exception when unique_violation then
    raise exception 'ad_alinmis' using errcode = 'P0001';
  end;
  return new;
end $$;

-- ---------------------------------------------------------------- 2
drop view if exists public.hk_leaderboard;

drop function if exists public.hk_start_daily(date);
drop function if exists public.hk_hint_daily(date);
drop function if exists public.hk_submit_daily(date, int[], boolean[], int, int);
drop function if exists public.hk_load_puzzles(text, text);
drop function if exists public.hk_delete_account();
drop function if exists public.hk_istanbul_today();

drop table if exists public.hk_daily_scores;
drop table if exists public.hk_daily_starts;
drop table if exists public.hk_daily_puzzles;
drop table if exists public.hk_level_progress;
drop table if exists public.hk_profiles;
drop table if exists public.hk_admin;
drop function if exists public.hk_name_key(text); -- hk_profiles_name_unique dizini tabloyla gitti

-- "Bu oyundaki verimi sil" (ortak.oyun_verisini_sil → oyunlar.ayarlar.hesap.silme_fonksiyonu): hk_ tarafında yalnız hak kaldı.
-- Ölçüm tabloları (hk_plays/opens/errors) kimliksiz, hk_push abonelik adresi: kullanıcıya bağlı satır yok.
create or replace function halka.oyuncu_verisini_sil(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.hk_entitlements where user_id = u;
end $$;
revoke execute on function halka.oyuncu_verisini_sil(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3

create or replace function public.hk_push_save(p_endpoint text, p_p256dh text, p_auth text, p_hour int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  -- Tavan: tablo sahte aboneliklerle sınırsız büyüyemesin.
  if not hk_push_host_ok(p_endpoint) then raise exception 'bilinmeyen bildirim servisi'; end if;
  if (select count(*) from hk_push) >= 100000 and not exists (select 1 from hk_push where endpoint = p_endpoint) then
    raise exception 'abonelik sınırı dolu';
  end if;
  insert into hk_push (endpoint, p256dh, auth, hour) values (p_endpoint, p_p256dh, p_auth, p_hour)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, hour = excluded.hour;
end $$;

create or replace function public.hk_push_remove(p_endpoint text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  delete from hk_push where endpoint = p_endpoint;
end $$;

revoke execute on function public.hk_push_save(text, text, text, int), public.hk_push_remove(text) from public, anon;
grant execute on function public.hk_push_save(text, text, text, int), public.hk_push_remove(text) to authenticated;
