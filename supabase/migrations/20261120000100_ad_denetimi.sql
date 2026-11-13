-- Ad denetimi (güvenlik incelemesi, 20261120000000 sonrası):
-- 1) Şikâyetle sıfırlanan ad o oyunda engelli listesine girer; ortak.ad_degistir de oyunun kendi yolu da onu kabul etmez.
--    (Önce sıfırlanan oyuncu, 30 gün sınırı da sıfırlandığı için aynı adı hemen yeniden seçebiliyordu.)
-- 2) Şikâyetle sıfırlamada oyunun kendi tablosundaki ad da temizlenir: ayarlar.hesap.ad_sifirlandi_fonksiyonu (uuid).
-- 3) Beat Greedy: sezgi.profiles.username yazılmadan ÖNCE ortak kurallarla denetlenir (biçim, süzgeç, engelli liste,
--    30 gün, benzersizlik); uymazsa kayıt reddedilir (ad_uygunsuz / ad_bekle / ad_alinmis). Önceki AFTER tetikleyici
--    sezgi'nin sınırsız ve daha gevşek ad değiştirmesini ortak sıralamaya taşıyordu.
-- 4) Halka için kademe ödülü açık (Halka LIVEOPS L1/L2).

create table ortak.engelli_adlar (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  ad_anahtari text not null,
  olusturma timestamptz not null default now(),
  primary key (oyun_id, ad_anahtari)
);
alter table ortak.engelli_adlar enable row level security;

-- ---------------------------------------------------------------- ad_degistir (+ engelli liste)

create or replace function ortak.ad_degistir(p_oyun text, p_ad text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  a jsonb;
  v_ad text := btrim(p_ad);
  o ortak.oyuncular;
  gun int;
begin
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

-- ---------------------------------------------------------------- sikayet_et (+ engelli liste, oyun kancası)

create or replace function ortak.sikayet_et(p_oyun text, p_ad text, p_neden text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  h ortak.oyuncular;
  a jsonb;
  esik int;
  en_az_gun int;
  sayi int;
  fn text;
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

  select coalesce(ayarlar -> 'sikayet', '{}'), ayarlar -> 'hesap' ->> 'ad_sifirlandi_fonksiyonu'
    into a, fn from ortak.oyunlar where id = p_oyun;
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

  insert into ortak.engelli_adlar (oyun_id, ad_anahtari) values (p_oyun, h.ad_anahtari) on conflict do nothing;
  update ortak.oyuncular set ad = null, ad_anahtari = null, ad_otomatik = true, ad_degisti = null
    where oyun_id = p_oyun and kullanici_id = h.kullanici_id;
  delete from ortak.sikayetler where oyun_id = p_oyun and hedef = h.kullanici_id and neden = 'ad';
  if fn is not null and to_regprocedure(fn || '(uuid)') is not null then
    execute format('select %s($1)', to_regprocedure(fn || '(uuid)')::regproc) using h.kullanici_id;
  end if;
  return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', true);
end $$;

-- ---------------------------------------------------------------- Beat Greedy: ad yazılmadan önce denetim

drop trigger if exists ortak_ad_yansit on sezgi.profiles;
drop function if exists sezgi.ortak_ad_yansit();

create function sezgi.ad_denetle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a jsonb; o ortak.oyuncular; gun int; v text := new.username::text;
begin
  -- Şikâyetle sıfırlamanın kendi yazdığı yer tutucu ad denetlenmez ve ortağa yansımaz.
  if current_setting('ortak.ad_yansitma', true) = 'kapali' then return new; end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username then return new; end if;

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
create trigger ad_denetle before insert or update of username on sezgi.profiles
  for each row execute function sezgi.ad_denetle();

-- Şikâyetle sıfırlamada Beat Greedy'nin kendi tablosundaki ad da nötr bir yer tutucuya çevrilir.
create function sezgi.ad_sifirlandi(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('ortak.ad_yansitma', 'kapali', true);
  update sezgi.profiles set username = 'oyuncu_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
    where id = u;
  perform set_config('ortak.ad_yansitma', '', true);
end $$;

-- ---------------------------------------------------------------- ayarlar

update ortak.oyunlar set ayarlar = jsonb_set(ayarlar, '{hesap,ad_sifirlandi_fonksiyonu}', '"sezgi.ad_sifirlandi"')
  where id = 'sezgi';
update ortak.oyunlar set ayarlar = jsonb_set(ayarlar, '{lig,kademe_odulu}', 'true')
  where id = 'halka';

revoke execute on all functions in schema ortak from public;
revoke execute on all functions in schema sezgi from public;
revoke execute on function sezgi.ad_denetle(), sezgi.ad_sifirlandi(uuid) from anon, authenticated;
grant execute on function ortak.ad_degistir(text, text), ortak.sikayet_et(text, text, text) to authenticated;
