-- 1) Ad süzgeci: baştaki ve sondaki rakam dizileri harfe çevrilmez, atılır. Önceden "Işık156759" → "isikists"
--    olup "sikis" içerdiği için reddediliyordu (otomatik adlar da "Önek1234" biçiminde). Sözcüğün içindeki rakamlar
--    eskisi gibi çevrilir: "S1kt1r42" → "siktir" yine yakalanır.
-- 2) Devir: var olan hesaba çakışmayan deneme bütünüyle değil, yalnız ceza bilgisiyle taşınır (güvenlik incelemesi).
--    Bütünüyle taşımak, adım adım ilerleyen oyunlarda (ör. Koz Hesabı) birkaç misafir oturumda başlatıp en iyi
--    giden yarım denemeyi ana hesapta bitirmeye izin veriyordu. Taşınan satır: aynı anahtar, sira 0, durum yalnız
--    `ipuclari`, `bitti` ve başlangıç zamanı (olusturma) korunur. Çakışan denemede kural değişmedi (hedefin durumu,
--    erken başlangıç, ipuçlarının birleşimi). Yeni açılan hesapta denemeler eskisi gibi bütünüyle taşınır (devir_ek).

create or replace function ortak.ad_uygun(ad text, ek text[] default '{}') returns boolean
language sql stable set search_path = '' as $$
  with h as (
    select regexp_replace(
             translate(regexp_replace(ortak.ad_anahtari(ad), '^[0-9]+|[0-9]+$', '', 'g'), '013457', 'oieast'),
             '[^a-z]', '', 'g') as v
  )
  select not exists (
    select 1 from h, ortak.yasakli_sozler y
    where (y.tur = 'icerir' and position(y.soz in h.v) > 0) or (y.tur = 'tam' and h.v = y.soz)
  ) and not exists (
    select 1 from h, unnest(ek) e
    where length(e) > 0 and position(ortak.ad_anahtari(e) in h.v) > 0
  )
$$;

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

  -- Çakışan denemeler: hedefin durumu kalır; erken başlangıç ve ipuçlarının tekrarsız birleşimi.
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

  -- Çakışmayan denemeler: yalnız ceza bilgisi (ipuçları, başlangıç, bitti); oyun durumu taşınmaz.
  insert into ortak.denemeler (oyun_id, kullanici_id, anahtar, sira, durum, bitti, olusturma, guncelleme)
    select e.oyun_id, yeni, e.anahtar, 0,
           case when jsonb_typeof(e.durum -> 'ipuclari') = 'array'
                then jsonb_build_object('ipuclari', e.durum -> 'ipuclari') else '{}'::jsonb end,
           e.bitti, e.olusturma, now()
    from ortak.denemeler e where e.kullanici_id = eski
    on conflict (oyun_id, kullanici_id, anahtar) do nothing;
end $$;

revoke execute on all functions in schema ortak from public;
grant execute on function ortak.ad_uygun(text, text[]) to anon, authenticated;
