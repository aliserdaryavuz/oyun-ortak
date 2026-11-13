-- HK-15: hk_ verisi ortak tablolara (Halka karar V1). Kaynak: halka-kelime supabase/hk15_veri_tasima.sql; testi tests/sql.test.ts "hk15". Yalnız ekleme, hk_ tabloları değişmez.
-- HK-15 / SUNUCU_GECISI Adım 5: eski hk_ verisinin ortak tablolara taşınması (V1, aynı veritabanı; auth taşıması yok).
-- oyun-ortak'a göç olarak taşınır. Tekrar çalıştırılabilir: var olan satır atlanır. hk_ tabloları silinmez (temizlik Adım 7).
-- Testi: tests/sql.test.ts "hk15".

-- 1) hk_profiles → ortak.oyuncular. Ad elle seçilmiş sayılır (ad_otomatik = false); değiştirme hakkı açık (ad_degisti boş).
--    ortak ad anahtarı daha geniş katlar ("Işık" = "Isik"): çakışan adlardan en eskisi adını alır, ötekiler adsız girer
--    (ilk girişte ad sorulur). Anahtarı başka oyuncuda olan ad da adsız girer.
insert into ortak.profiller (kullanici_id)
select p.id from public.hk_profiles p
on conflict do nothing;

with aday as (
  select p.id, p.name, p.created_at, nullif(ortak.ad_anahtari(p.name), '') k,
         row_number() over (partition by ortak.ad_anahtari(p.name) order by p.created_at, p.id) sira
  from public.hk_profiles p
), uygun as (
  -- Ad, oyuncunun kendi seçtiğindeki denetimlerden geçmeli (biçim, uzunluk, yasaklı/uygunsuz): geçmeyen adsız taşınır,
  -- ilk girişte yeniden sorulur (güvenlik incelemesi: taşıma ad denetimini atlamasın).
  select a.*, a.k is not null and a.sira = 1
    and ortak.ad_bicimi(btrim(a.name), coalesce((oy.ayarlar -> 'ad' ->> 'en_az')::int, 3), coalesce((oy.ayarlar -> 'ad' ->> 'en_cok')::int, 16))
    and ortak.ad_uygun(btrim(a.name), coalesce(array(select jsonb_array_elements_text(oy.ayarlar -> 'ad' -> 'yasakli')), '{}'))
    and not exists (
    select 1 from ortak.oyuncular o where o.oyun_id = 'halka' and o.ad_anahtari = a.k and o.kullanici_id <> a.id) ad_ok
  from aday a cross join (select ayarlar from ortak.oyunlar where id = 'halka') oy
)
insert into ortak.oyuncular as y (oyun_id, kullanici_id, ad, ad_anahtari, ad_otomatik, olusturma)
select 'halka', id, case when ad_ok then btrim(name) end, case when ad_ok then k end, not ad_ok, created_at from uygun
on conflict (oyun_id, kullanici_id) do update
  set ad = excluded.ad, ad_anahtari = excluded.ad_anahtari, ad_otomatik = false
  where y.ad is null and excluded.ad is not null;

-- 2) hk_level_progress + hk_daily_scores → ortak.kayitlar: kullanıcı başına tek blob, istemcinin biçimi (src/app/store.ts Bulut):
--    { v: 1, seviye: { "<zorluk>-<n>": [yıldız, hamle, süre] }, gunluk: { "YYYY-MM-DD": [hamle, ipucu, süre, gününde] } }.
--    Yıldız eski tabloda yok (par istemcide): 0 = bilinmiyor; seviye çözülmüş sayılır, yıldızsız görünür.
--    hk_daily_scores yalnız gününde çözülenleri tutar: gününde = 1. Buluttan kaydı olan oyuncu atlanır.
insert into ortak.kayitlar (oyun_id, kullanici_id, veri)
select 'halka', u.id, jsonb_build_object(
  'v', 1,
  'seviye', coalesce((select jsonb_object_agg(l.key, jsonb_build_array(0, l.moves, l.seconds))
                      from public.hk_level_progress l where l.user_id = u.id), '{}'::jsonb),
  'gunluk', coalesce((select jsonb_object_agg(s.date::text, jsonb_build_array(s.moves, s.hints, s.seconds, 1))
                      from public.hk_daily_scores s where s.user_id = u.id), '{}'::jsonb))
from (select user_id id from public.hk_level_progress union select user_id from public.hk_daily_scores) u
on conflict (oyun_id, kullanici_id) do nothing;

-- 3) hk_daily_scores → ortak.skorlar: tür 'gunluk', dönem gün, puan = rank_seconds (süre + 30 sn/ipucu), ikincil = hamle
--    (dogrula-halka gibi). run_id yeni. Lig puanı boş: hedef (par) eski tabloda yok, geçmiş haftalar lige girmez.
insert into ortak.skorlar (oyun_id, kullanici_id, tur, donem, puan, ikincil, run_id, ayrinti, olusturma)
select 'halka', s.user_id, 'gunluk', s.date::text, s.rank_seconds, s.moves, gen_random_uuid(),
       jsonb_build_object('kaynak', 'hk_daily_scores', 'sure', s.seconds, 'ipucu', s.hints, 'hamle', s.moves), s.created_at
from public.hk_daily_scores s
on conflict (oyun_id, tur, donem, kullanici_id) do nothing;
