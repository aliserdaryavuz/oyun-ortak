-- Halka Kelime'nin ortak kaydı (HK-2, HK-4, HK-5, HK-8). Halka henüz `public.hk_` tablolarını kullanıyor;
-- bu kayıt sayesinde ortak paketlere (ad, lig, ödeme, ödül, ölçüm) parça parça geçebilir. Verinin hk_ tablolarından
-- ortak tablolara taşınması Halka'nın yeni sürümüyle birlikte ayrı göçte yapılır (docs/GECIS.md §3).

create schema if not exists halka;
grant usage on schema halka to anon, authenticated, service_role;
alter default privileges in schema halka revoke all on tables from anon, authenticated, public;
alter default privileges in schema halka revoke execute on functions from anon, authenticated, public;
alter default privileges in schema halka grant all on tables to service_role;
alter default privileges in schema halka grant execute on functions to service_role;

insert into ortak.oyunlar (id, ad, ayarlar) values (
  'halka', 'Halka Kelime', '{
    "ad": { "en_az": 2, "en_cok": 20, "degistirme_gun": 30 },
    "hesap": { "baglama_odulu": "desen-porselen", "silme_fonksiyonu": "halka.oyuncu_verisini_sil" },
    "siralama": { "yon": "artan", "esitlik": "ortak", "dagilim_esigi": 50 },
    "lig": { "kademeler": ["Toprak", "Bakır", "Gümüş", "Altın", "Firuze"], "grup_boyu": 50,
             "cikis_orani": 0.2, "inis_orani": 0.2, "en_iyi_gun": 5, "esitlik": "ikincil", "bant_genisligi": 0 },
    "odeme": { "revenuecat_uygulamalari": [] }
  }'
) on conflict (id) do nothing;

-- Mağaza ürün kimliği Play Console'da kesinleşince değişebilir (ayrı göçle).
insert into ortak.urunler (urun, oyun_id, hak) values ('paket_tam', 'halka', 'paket_tam') on conflict do nothing;

-- "Bu oyundaki verimi sil": bugünkü hk_ tabloları. Kalıcı geçişte halka şemasına göre yeniden yazılır.
create function halka.oyuncu_verisini_sil(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.hk_daily_scores where user_id = u;
  delete from public.hk_daily_starts where user_id = u;
  delete from public.hk_level_progress where user_id = u;
  delete from public.hk_entitlements where user_id = u;
  delete from public.hk_profiles where id = u;
end $$;

revoke execute on all functions in schema halka from public, anon, authenticated;
