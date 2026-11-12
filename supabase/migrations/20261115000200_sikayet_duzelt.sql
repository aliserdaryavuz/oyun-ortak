-- Şikâyet düzeltmeleri (güvenlik incelemesi):
-- 1) Yalnız şu anki ada yapılan 'ad' şikâyetleri sayılır; oyuncu adını değiştirince eski şikâyetler yeni adı etkilemez.
-- 2) Sayılan şikâyetçi o oyunda en az `ayarlar.sikayet.en_az_gun` (varsayılan 2) gündür oynayan kalıcı hesaptır.
--    E-postayla kalıcı hesap açmak da bedava; yeni hesapların şikâyeti kaydedilir ama sayılmaz.
-- 3) Devirde (misafir → kalıcı hesap) şikâyetler yeni hesaba taşınır; anonim hesap silinince kaybolmaz.

create or replace function ortak.sikayet_et(p_oyun text, p_ad text, p_neden text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  h ortak.oyuncular;
  a jsonb;
  esik int;
  en_az_gun int;
  sayi int;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  if p_neden not in ('ad', 'hile', 'diger') then raise exception 'neden_gecersiz'; end if;
  if not ortak.hiz_siniri('sikayet:' || u, 20, 86400) then raise exception 'cok_istek' using errcode = '54000'; end if;

  select * into h from ortak.oyuncular
    where oyun_id = p_oyun and ad_anahtari = ortak.ad_anahtari(p_ad) for update;
  if not found then return jsonb_build_object('durum', 'bulunamadi'); end if;
  if h.kullanici_id = u then return jsonb_build_object('durum', 'kendin'); end if;

  insert into ortak.sikayetler (oyun_id, sikayet_eden, hedef, neden, hedef_ad)
    values (p_oyun, u, h.kullanici_id, p_neden, h.ad)
    on conflict (oyun_id, sikayet_eden, hedef, neden) do update
      set hedef_ad = excluded.hedef_ad, olusturma = now()
      where ortak.ad_anahtari(ortak.sikayetler.hedef_ad) is distinct from ortak.ad_anahtari(excluded.hedef_ad);
  if not found then return jsonb_build_object('durum', 'zaten'); end if;
  if p_neden <> 'ad' then return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', false); end if;

  select coalesce(ayarlar -> 'sikayet', '{}') into a from ortak.oyunlar where id = p_oyun;
  esik := coalesce((a ->> 'ad_esigi')::int, 3);
  en_az_gun := coalesce((a ->> 'en_az_gun')::int, 2);
  select count(*) into sayi
  from ortak.sikayetler s
  join auth.users k on k.id = s.sikayet_eden
  join ortak.oyuncular o on o.oyun_id = s.oyun_id and o.kullanici_id = s.sikayet_eden
  where s.oyun_id = p_oyun and s.hedef = h.kullanici_id and s.neden = 'ad'
    and ortak.ad_anahtari(s.hedef_ad) = h.ad_anahtari
    and not k.is_anonymous
    and o.olusturma <= now() - make_interval(days => en_az_gun);
  if sayi < esik then return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', false); end if;

  update ortak.oyuncular set ad = null, ad_anahtari = null, ad_otomatik = true, ad_degisti = null
    where oyun_id = p_oyun and kullanici_id = h.kullanici_id;
  delete from ortak.sikayetler where oyun_id = p_oyun and hedef = h.kullanici_id and neden = 'ad';
  return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', true);
end $$;

-- v0.2 gövdesi + şikâyetlerin yeni hesaba taşınması.
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
end $$;

revoke execute on all functions in schema ortak from public;
grant execute on function ortak.sikayet_et(text, text, text) to authenticated;
