-- Devirde denemeler var olan hesaba da taşınır (Halka isteği; ipucu cezası kaybolmasın).
--
-- v0.1 güvenlik düzeltmesinde var olan hesaba skor/deneme/lig taşınmıyordu (birkaç anonim oturumda oynayıp en iyisini
-- ana hesaba taşıma hilesi). Bunun yan etkisi: misafirken ipucu alıp sonra var olan hesabına giren oyuncunun ipuçları
-- kayboluyor, dogrula-* "ipucusuz" skor yazıyordu. Denemeler cezayı taşıdığı için birleştirme hile yönünde değil:
--   - Aynı anahtar iki hesapta varsa hedefteki satır kalır; erken başlangıç (olusturma) ve ipuçlarının birleşimi
--     (`durum.ipuclari` dizisi, tekrarsız) yazılır.
--   - Çakışmayan deneme olduğu gibi taşınır. Bitmiş bir misafir denemesi taşınınca o gün yeniden oynanamaz
--     (cevabı bilerek tekrar oynanmasın); misafirken yazılan skor ise var olan hesaba taşınmaz.
-- Skorlar ve lig eskisi gibi yalnız yeni açılan hesaba taşınır (devir_ek).
-- Not: `ipuclari` dışındaki oyuna özgü durum alanları birleştirilmez; hedefteki değer kalır.

create or replace function ortak.devir_her_zaman(eski uuid, yeni uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into ortak.haklar (oyun_id, kullanici_id, hak, durum, kaynak, urun, dis_id)
    select oyun_id, yeni, hak, durum, kaynak, urun, dis_id from ortak.haklar where kullanici_id = eski
    on conflict (oyun_id, kullanici_id, hak) do update
      set durum = case when ortak.haklar.durum = 'aktif' or excluded.durum = 'aktif' then 'aktif' else 'iade' end;
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak, kazanildi)
    select oyun_id, yeni, odul, kaynak, kazanildi from ortak.oduller where kullanici_id = eski
    on conflict do nothing;
  insert into ortak.sikayetler (oyun_id, sikayet_eden, hedef, neden, hedef_ad, olusturma)
    select oyun_id, sikayet_eden, yeni, neden, hedef_ad, olusturma from ortak.sikayetler
    where hedef = eski and sikayet_eden <> yeni
    on conflict do nothing;

  -- Denemeler: çakışanlarda erken başlangıç ve ipuçlarının tekrarsız birleşimi.
  update ortak.denemeler y set
    olusturma = least(y.olusturma, e.olusturma),
    durum = case
      when jsonb_typeof(e.durum -> 'ipuclari') = 'array' then
        y.durum || jsonb_build_object('ipuclari', (
          select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
          from jsonb_array_elements(
            case when jsonb_typeof(y.durum -> 'ipuclari') = 'array' then y.durum -> 'ipuclari' else '[]'::jsonb end
            || (e.durum -> 'ipuclari')) x))
      else y.durum end,
    guncelleme = now()
  from ortak.denemeler e
  where e.kullanici_id = eski and y.kullanici_id = yeni and y.oyun_id = e.oyun_id and y.anahtar = e.anahtar;

  update ortak.denemeler e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.denemeler y
                      where y.oyun_id = e.oyun_id and y.anahtar = e.anahtar and y.kullanici_id = yeni);
end $$;

revoke execute on all functions in schema ortak from public;
