-- Güvenlik (Halka incelemesi, 2026-11-14): misafir (anonim) oturumlar bedava açılır; kalıcı yer kaplayan ya da
-- başkasını etkileyen yazımlar kalıcı hesaba bağlanır.
-- 1) odul_kaydet: anonimde reddedilir (istemci bekleyen ödülü yerelde tutar, girişten sonra eşitler);
--    oyun başına kullanıcı başına en çok 1000 ödül satırı (veritabanını doldurma saldırısı).
-- 2) ad_degistir: anonimde reddedilir (popüler adları misafir oturumlarla kapatma). otomatik_ad açık kalır.
-- 3) kayit_yaz: anonimde reddedilir (oturum başına 256 KB, sınırsız oturum).

create or replace function ortak.odul_kaydet(p_oyun text, p_oduller jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); n integer;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  if jsonb_typeof(p_oduller) <> 'array' or jsonb_array_length(p_oduller) > 100 then
    raise exception 'oduller_gecersiz';
  end if;
  if exists (select 1 from jsonb_array_elements(p_oduller) x where x ->> 'odul' like 'sira:%') then
    raise exception 'odul_yasak';
  end if;
  if not ortak.hiz_siniri('odul:' || u, 30, 60) then raise exception 'cok_istek' using errcode = '54000'; end if;
  if (select count(*) from ortak.oduller where oyun_id = p_oyun and kullanici_id = u)
     + jsonb_array_length(p_oduller) > 1000 then
    raise exception 'odul_tavan' using errcode = '54000';
  end if;
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak, kazanildi)
    select p_oyun, u, x ->> 'odul', x ->> 'kaynak',
           least(coalesce((x ->> 'kazanildi')::timestamptz, now()), now())
    from jsonb_array_elements(p_oduller) x
    on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ortak.ad_degistir(p_oyun text, p_ad text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  a jsonb;
  v_ad text := btrim(p_ad);
  o ortak.oyuncular;
  gun int;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  select coalesce(ayarlar -> 'ad', '{}') into a from ortak.oyunlar where id = p_oyun;
  if not found then raise exception 'oyun_yok'; end if;
  if not ortak.ad_bicimi(v_ad, coalesce((a ->> 'en_az')::int, 3), coalesce((a ->> 'en_cok')::int, 16)) then
    return jsonb_build_object('durum', 'bicim');
  end if;
  if not ortak.ad_uygun(v_ad, coalesce(array(select jsonb_array_elements_text(a -> 'yasakli')), '{}'))
     or exists (select 1 from ortak.engelli_adlar where oyun_id = p_oyun and ad_anahtari = ortak.ad_anahtari(v_ad)) then
    return jsonb_build_object('durum', 'uygunsuz');
  end if;

  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, u) on conflict do nothing;
  select * into o from ortak.oyuncular where oyun_id = p_oyun and kullanici_id = u for update;

  gun := coalesce((a ->> 'degistirme_gun')::int, 30);
  if o.ad_degisti is not null and o.ad_degisti > now() - make_interval(days => gun) then
    return jsonb_build_object('durum', 'bekle',
      'bekle_gun', ceil(extract(epoch from (o.ad_degisti + make_interval(days => gun) - now())) / 86400));
  end if;

  begin
    update ortak.oyuncular set ad = v_ad, ad_anahtari = ortak.ad_anahtari(v_ad), ad_otomatik = false, ad_degisti = now()
    where oyun_id = p_oyun and kullanici_id = u;
  exception when unique_violation then
    return jsonb_build_object('durum', 'alinmis');
  end;
  return jsonb_build_object('durum', 'ok', 'ad', v_ad);
end $$;

create or replace function ortak.kayit_yaz(p_oyun text, p_veri jsonb, p_surum integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); yeni integer;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  if octet_length(p_veri::text) > 262144 then raise exception 'kayit_buyuk' using errcode = '22001'; end if;
  if p_surum = 0 then
    insert into ortak.kayitlar (oyun_id, kullanici_id, veri) values (p_oyun, u, p_veri)
      on conflict do nothing returning surum into yeni;
  else
    update ortak.kayitlar set veri = p_veri, surum = surum + 1, guncelleme = now()
      where oyun_id = p_oyun and kullanici_id = u and surum = p_surum
      returning surum into yeni;
  end if;
  return yeni;
end $$;
