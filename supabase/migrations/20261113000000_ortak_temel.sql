-- oyun-ortak: ortak şema, temel (oyunlar, profiller, oyuncular, takma ad, bulut kaydı, istek sınırı, hesap devri, silme).
-- İlke: istemci tablolara doğrudan dokunmaz; her şey security definer RPC'lerle. RLS yine de her tabloda açık.

create schema if not exists ortak;
grant usage on schema ortak to anon, authenticated, service_role;

-- Varsayılan yetkiler YALNIZ bu şema için (sezgi'deki şemasız revoke bütün veritabanını etkiliyordu).
alter default privileges in schema ortak revoke all on tables from anon, authenticated, public;
alter default privileges in schema ortak revoke all on sequences from anon, authenticated, public;
alter default privileges in schema ortak revoke execute on functions from anon, authenticated, public;
alter default privileges in schema ortak grant all on tables to service_role;
alter default privileges in schema ortak grant all on sequences to service_role;
alter default privileges in schema ortak grant execute on functions to service_role;

-- ---------------------------------------------------------------- yardımcılar

-- İstanbul takvim günü (Türkiye'de yaz saati yok, UTC+3 sabit; yine de saat dilimi adıyla).
create function ortak.bugun() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Europe/Istanbul')::date
$$;

-- ISO haftasının pazartesisi.
create function ortak.iso_hafta(d date) returns date
language sql immutable set search_path = '' as $$
  select d - (extract(isodow from d)::int - 1)
$$;

-- Oturumdaki kullanıcı; yoksa hata.
create function ortak.kim() returns uuid
language plpgsql stable set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'giris_gerekli' using errcode = '28000'; end if;
  return u;
end $$;

create function ortak.anonim() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

grant execute on function ortak.bugun(), ortak.iso_hafta(date) to anon, authenticated;

-- ---------------------------------------------------------------- oyunlar

-- ayarlar (hepsi isteğe bağlı):
--   ad:       { en_az: 3, en_cok: 16, degistirme_gun: 30, yasakli: ["koz"] }
--   hesap:    { baglama_odulu: "desen-porselen", silme_fonksiyonu: "halka.oyuncu_verisini_sil" }
--   siralama: { yon: "azalan" | "artan", esitlik: "ortak" | "ikincil", dagilim_esigi: 50 }
--   lig:      { kademeler: [..adlar], grup_boyu: 50, cikis_orani: 0.2, inis_orani: 0.2,
--               en_iyi_gun: 5, esitlik: "ortak" | "ikincil", bant_genisligi: 0 }
create table ortak.oyunlar (
  id text primary key check (id ~ '^[a-z][a-z0-9-]{1,30}$'),
  ad text not null,
  ayarlar jsonb not null default '{}'
);
alter table ortak.oyunlar enable row level security;
create policy herkes_okur on ortak.oyunlar for select using (true);
grant select on ortak.oyunlar to anon, authenticated;

-- ---------------------------------------------------------------- profil ve oyuncu

create table ortak.profiller (
  kullanici_id uuid primary key references auth.users on delete cascade,
  yas_onay timestamptz,              -- 13+ beyanı (KH-7, EN-7, HK-4)
  olusturma timestamptz not null default now()
);
alter table ortak.profiller enable row level security;

create table ortak.oyuncular (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  ad text,
  ad_anahtari text,
  ad_otomatik boolean not null default true,
  ad_degisti timestamptz,            -- son ELLE değiştirme; otomatik ad bu hakkı harcamaz
  kademe smallint not null default 0,
  seviye_puani integer not null default 0,
  baglama_odulu text,                -- verilen ödül kimliği; null = henüz verilmedi (HK-5)
  olusturma timestamptz not null default now(),
  son_gorulme timestamptz not null default now(),
  primary key (oyun_id, kullanici_id)
);
create unique index oyuncular_ad_benzersiz on ortak.oyuncular (oyun_id, ad_anahtari) where ad_anahtari is not null;
create index oyuncular_kullanici on ortak.oyuncular (kullanici_id);
alter table ortak.oyuncular enable row level security;

-- Benzersizlik anahtarı: Türkçe katlama ("Işık" = "Isik" = "ışık"), boşluk ve noktalama düşer.
create function ortak.ad_anahtari(ad text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(
    translate(lower(translate(ad, 'İIı', 'iii')), 'şğüöçâîû', 'sguocaiu'),
    '[^a-z0-9]', '', 'g')
$$;

-- Uygunsuz sözler. tur = 'icerir': adın harflerinde herhangi bir yerde geçemez;
-- tur = 'tam': yalnız adın harflerinin tamamıysa engellenir (Memet, Seksen gibi yanlış pozitif olmasın).
create table ortak.yasakli_sozler (
  soz text primary key check (soz ~ '^[a-z]+$'),
  tur text not null check (tur in ('icerir', 'tam'))
);
alter table ortak.yasakli_sozler enable row level security;
insert into ortak.yasakli_sozler (soz, tur) values
  -- Türkçe (sifre-burosu kaba.json, sezgi username_allowed, koz-hesabi YASAKLI birleşimi)
  ('orospu','icerir'), ('yarrak','icerir'), ('amcik','icerir'), ('aminakoy','icerir'), ('amina','icerir'),
  ('siktir','icerir'), ('sikis','icerir'), ('sikerim','icerir'), ('sikeyim','icerir'), ('sikik','icerir'),
  ('hassiktir','icerir'), ('pezevenk','icerir'), ('kahpe','icerir'), ('gavat','icerir'), ('kaltak','icerir'),
  ('surtuk','icerir'), ('serefsiz','icerir'), ('fahise','icerir'), ('ibne','icerir'), ('anasini','icerir'),
  ('porno','icerir'), ('tecavuz','icerir'), ('taciz','icerir'), ('uyusturucu','icerir'),
  ('sik','tam'), ('got','tam'), ('pic','tam'), ('amk','tam'), ('aq','tam'), ('oc','tam'), ('bok','tam'),
  ('seks','tam'), ('lan','tam'), ('ulan','tam'),
  -- İngilizce
  ('fuck','icerir'), ('bitch','icerir'), ('nigger','icerir'), ('nigga','icerir'), ('faggot','icerir'),
  ('whore','icerir'), ('pussy','icerir'), ('asshole','icerir'), ('cunt','icerir'), ('hitler','icerir'),
  ('dick','tam'), ('cock','tam'), ('fag','tam'), ('sex','tam'), ('nazi','tam'),
  -- Para ve bahis çağrışımı (KH-6)
  ('bahis','icerir'), ('kumar','icerir'), ('iddaa','icerir'), ('casino','icerir'), ('kazino','icerir'), ('bet','tam'),
  -- Yetkili taklidi
  ('admin','icerir'), ('yonetici','icerir'), ('moderator','icerir'), ('destek','tam'), ('support','tam'),
  ('sistem','tam'), ('system','tam'), ('root','tam'), ('mod','tam');

-- Ad uygun mu: harfler (rakamlar leet katlamasıyla harfe çevrilip) yasaklı listeye ve oyunun ek listesine bakılır.
create function ortak.ad_uygun(ad text, ek text[] default '{}') returns boolean
language sql stable set search_path = '' as $$
  with h as (
    select regexp_replace(translate(ortak.ad_anahtari(ad), '013457', 'oieast'), '[^a-z]', '', 'g') as v
  )
  select not exists (
    select 1 from h, ortak.yasakli_sozler y
    where (y.tur = 'icerir' and position(y.soz in h.v) > 0) or (y.tur = 'tam' and h.v = y.soz)
  ) and not exists (
    select 1 from h, unnest(ek) e
    where length(e) > 0 and position(ortak.ad_anahtari(e) in h.v) > 0
  )
$$;

-- Biçim: harf (Latin + Türkçe), rakam, tek boşluk, . _ -; en az bir harf; baş ve sonda boşluk yok.
create function ortak.ad_bicimi(ad text, en_az int, en_cok int) returns boolean
language sql immutable set search_path = '' as $$
  select char_length(ad) between en_az and en_cok
     and ad ~ '^[A-Za-z0-9ÇĞİÖŞÜÂÎÛçğıöşüâîû._-]+( [A-Za-z0-9ÇĞİÖŞÜÂÎÛçğıöşüâîû._-]+)*$'
     and ad ~ '[A-Za-zÇĞİÖŞÜÂÎÛçğıöşüâîû]'
$$;

grant execute on function ortak.ad_anahtari(text), ortak.ad_uygun(text, text[]), ortak.ad_bicimi(text, int, int)
  to anon, authenticated;

-- Oyuncu satırını açar (yoksa), son görülmeyi günceller, oyuncunun kendi bilgisini döner.
create function ortak.ben(p_oyun text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); o ortak.oyuncular; p ortak.profiller;
begin
  insert into ortak.profiller (kullanici_id) values (u) on conflict do nothing;
  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, u)
    on conflict (oyun_id, kullanici_id) do update set son_gorulme = now()
    returning * into o;
  select * into p from ortak.profiller where kullanici_id = u;
  return jsonb_build_object(
    'ad', o.ad, 'ad_otomatik', o.ad_otomatik, 'ad_degisti', o.ad_degisti,
    'kademe', o.kademe, 'seviye_puani', o.seviye_puani, 'baglama_odulu', o.baglama_odulu,
    'yas_onay', p.yas_onay, 'anonim', ortak.anonim());
end $$;

create function ortak.yas_onayla() returns void
language sql security definer set search_path = '' as $$
  insert into ortak.profiller (kullanici_id, yas_onay) values (ortak.kim(), now())
  on conflict (kullanici_id) do update set yas_onay = coalesce(ortak.profiller.yas_onay, now())
$$;

-- Takma ad (oyun başına). Dönüş: { durum: ok | bicim | uygunsuz | alinmis | bekle, ad?, bekle_gun? }
-- Elle değiştirme; 30 günde bir (ayar: ad.degistirme_gun). Otomatik ad için `ortak.otomatik_ad`.
create function ortak.ad_degistir(p_oyun text, p_ad text) returns jsonb
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
  if not ortak.ad_uygun(v_ad, coalesce(array(select jsonb_array_elements_text(a -> 'yasakli')), '{}')) then
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
    update ortak.oyuncular set
      ad = v_ad,
      ad_anahtari = ortak.ad_anahtari(v_ad),
      ad_otomatik = false,
      ad_degisti = now()
    where oyun_id = p_oyun and kullanici_id = u;
  exception when unique_violation then
    return jsonb_build_object('durum', 'alinmis');
  end;
  return jsonb_build_object('durum', 'ok', 'ad', v_ad);
end $$;

-- Otomatik ad (KM-4, EN-6): sunucu üretir; önekler oyunun ayarından (ad.onekler) + 4 hane.
-- Yalnız adı olmayan oyuncuya verilir; istemci adın metnini seçemez ve 30 gün hakkı harcanmaz.
create function ortak.otomatik_ad(p_oyun text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  onekler text[];
  o ortak.oyuncular;
  v_ad text;
begin
  select coalesce(array(select jsonb_array_elements_text(ayarlar -> 'ad' -> 'onekler')), '{}')
    into onekler from ortak.oyunlar where id = p_oyun;
  if not found then raise exception 'oyun_yok'; end if;
  if cardinality(onekler) = 0 then onekler := array['Oyuncu']; end if;
  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, u) on conflict do nothing;
  select * into o from ortak.oyuncular where oyun_id = p_oyun and kullanici_id = u for update;
  if o.ad is not null then return jsonb_build_object('durum', 'ok', 'ad', o.ad); end if;
  for i in 1..10 loop
    v_ad := onekler[1 + floor(random() * cardinality(onekler))::int] || (1000 + floor(random() * 9000))::int;
    begin
      update ortak.oyuncular set ad = v_ad, ad_anahtari = ortak.ad_anahtari(v_ad), ad_otomatik = true
        where oyun_id = p_oyun and kullanici_id = u;
      return jsonb_build_object('durum', 'ok', 'ad', v_ad);
    exception when unique_violation then
      null;
    end;
  end loop;
  return jsonb_build_object('durum', 'alinmis');
end $$;

-- İlk kalıcı hesapta bir kez verilen kozmetik ödül (HK-5, KH-7). Verildiyse ödül kimliği, verilmediyse null.
create function ortak.baglama_odulu_al(p_oyun text) returns text
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); odul text;
begin
  if ortak.anonim() then return null; end if;
  select ayarlar -> 'hesap' ->> 'baglama_odulu' into odul from ortak.oyunlar where id = p_oyun;
  if odul is null then return null; end if;
  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, u) on conflict do nothing;
  update ortak.oyuncular set baglama_odulu = odul
    where oyun_id = p_oyun and kullanici_id = u and baglama_odulu is null;
  return case when found then odul else null end;
end $$;

-- ---------------------------------------------------------------- bulut kaydı

-- Oyunun opak kaydı (yedek/eşitleme). Birleştirme istemcide, oyunun işleviyle (KM-3, EN-5, HK-4).
create table ortak.kayitlar (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  veri jsonb not null,
  surum integer not null default 1,
  guncelleme timestamptz not null default now(),
  primary key (oyun_id, kullanici_id)
);
alter table ortak.kayitlar enable row level security;

create function ortak.kayit_oku(p_oyun text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('veri', veri, 'surum', surum, 'guncelleme', guncelleme)
  from ortak.kayitlar where oyun_id = p_oyun and kullanici_id = ortak.kim()
$$;

-- İyimser kilit: p_surum okunan sürüm (hiç kayıt yoksa 0). Eşleşmezse null döner; istemci yeniden okuyup birleştirir.
create function ortak.kayit_yaz(p_oyun text, p_veri jsonb, p_surum integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); yeni integer;
begin
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

-- ---------------------------------------------------------------- istek sınırı

create table ortak.hiz_sinirlari (
  anahtar text not null,
  pencere timestamptz not null,
  sayi integer not null,
  primary key (anahtar, pencere)
);
alter table ortak.hiz_sinirlari enable row level security;

-- Atomik sayaç: sınır aşılmadıysa true. Yalnız servis rolü (Edge Function) ve definer fonksiyonlar çağırır.
create function ortak.hiz_siniri(p_anahtar text, p_sinir integer, p_saniye integer) returns boolean
language sql security definer set search_path = '' as $$
  insert into ortak.hiz_sinirlari (anahtar, pencere, sayi)
  values (p_anahtar, to_timestamp(floor(extract(epoch from now()) / p_saniye) * p_saniye), 1)
  on conflict (anahtar, pencere) do update set sayi = ortak.hiz_sinirlari.sayi + 1
  returning sayi <= p_sinir
$$;

-- ---------------------------------------------------------------- hesap devri (misafir → kalıcı hesap)

-- Anonim oturum kısa ömürlü bir kod alır; oyuncu Google/Apple/e-postayla girince yeni oturum kodu
-- `hesap_devral`'a verir, anonim hesabın sunucu satırları taşınır ve anonim hesap silinir.
-- Yeni hesap ister yeni açılmış ister eskiden var olsun aynı yol çalışır.
create table ortak.devirler (
  kod_ozeti bytea primary key,
  anonim_id uuid not null references auth.users on delete cascade,
  bitis timestamptz not null
);
alter table ortak.devirler enable row level security;

create function ortak.devir_kodu_al() returns text
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); kod text;
begin
  if not ortak.anonim() then raise exception 'anonim_degil'; end if;
  if not ortak.hiz_siniri('devir:' || u, 10, 3600) then raise exception 'cok_istek' using errcode = '54000'; end if;
  kod := encode(extensions.gen_random_bytes(24), 'hex');
  delete from ortak.devirler where anonim_id = u or bitis < now();
  insert into ortak.devirler values (sha256(convert_to(kod, 'UTF8')), u, now() + interval '30 minutes');
  return kod;
end $$;

create function ortak.hesap_devral(p_kod text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  yeni uuid := ortak.kim();
  eski uuid;
  v_oyunlar text[];
  v_bos boolean;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  delete from ortak.devirler
    where kod_ozeti = sha256(convert_to(p_kod, 'UTF8')) and bitis > now()
    returning anonim_id into eski;
  if eski is null then raise exception 'devir_kodu_gecersiz'; end if;
  if eski = yeni then return jsonb_build_object('oyunlar', '[]'::jsonb); end if;

  select coalesce(array_agg(oyun_id), '{}') into v_oyunlar from ortak.oyuncular where kullanici_id = eski;
  -- Hedef hesap yeni mi (hiçbir oyunda izi yok)? Var olan hesaba skor taşınmaz: yoksa birkaç anonim
  -- oturumda günlüğü oynayıp en iyisini ana hesaba taşımak mümkün olurdu.
  v_bos := not exists (select 1 from ortak.oyuncular where kullanici_id = yeni)
       and not exists (select 1 from ortak.kayitlar where kullanici_id = yeni);

  insert into ortak.profiller (kullanici_id, yas_onay)
    select yeni, yas_onay from ortak.profiller where kullanici_id = eski
    on conflict (kullanici_id) do update
      set yas_onay = coalesce(ortak.profiller.yas_onay, excluded.yas_onay);

  -- Oyuncu: yeni hesapta o oyunda satır yoksa taşınır; varsa yeni hesabınki kalır, adı boşsa eski ad alınır.
  update ortak.oyuncular e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.oyuncular y where y.oyun_id = e.oyun_id and y.kullanici_id = yeni);
  with silinen as (
    delete from ortak.oyuncular where kullanici_id = eski
    returning oyun_id, ad, ad_otomatik, kademe
  )
  update ortak.oyuncular y set
    ad = coalesce(y.ad, s.ad),
    ad_anahtari = coalesce(y.ad_anahtari, ortak.ad_anahtari(s.ad)),
    ad_otomatik = case when y.ad is null then s.ad_otomatik else y.ad_otomatik end
  from silinen s where y.oyun_id = s.oyun_id and y.kullanici_id = yeni;

  -- Bulut kaydı: yeni hesapta yoksa taşınır (varsa istemci yerel kayıtla birleştirir).
  update ortak.kayitlar e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.kayitlar y where y.oyun_id = e.oyun_id and y.kullanici_id = yeni);

  -- Sıralama tabloları ikinci göçte; onların taşıması `ortak.devir_ek` kancasında (yalnız yeni hesaba).
  if v_bos then perform ortak.devir_ek(eski, yeni); end if;

  delete from auth.users where id = eski;
  return jsonb_build_object('oyunlar', to_jsonb(v_oyunlar), 'skorlar_tasindi', v_bos);
end $$;

-- Sonraki göçler bu kancayı genişletir (create or replace).
create function ortak.devir_ek(eski uuid, yeni uuid) returns void
language plpgsql security definer set search_path = '' as $$ begin end $$;

-- ---------------------------------------------------------------- silme

-- Oyuncunun verisi olan oyunlar (tam silme onayında listelenir).
create function ortak.hesap_ozeti() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('oyun_id', g.id, 'ad', g.ad) order by g.ad), '[]')
  from ortak.oyunlar g
  where exists (select 1 from ortak.oyuncular o where o.oyun_id = g.id and o.kullanici_id = ortak.kim())
     or exists (select 1 from ortak.kayitlar k where k.oyun_id = g.id and k.kullanici_id = ortak.kim())
$$;

-- "Bu oyundaki verimi sil". Oyunun kendi şemasındaki satırlar için oyunun silme fonksiyonu çağrılır.
create function ortak.oyun_verisini_sil(p_oyun text) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); fn text;
begin
  select ayarlar -> 'hesap' ->> 'silme_fonksiyonu' into fn from ortak.oyunlar where id = p_oyun;
  if not found then raise exception 'oyun_yok'; end if;
  perform ortak.oyun_verisini_sil_ek(p_oyun, u);
  delete from ortak.kayitlar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.oyuncular where oyun_id = p_oyun and kullanici_id = u;
  if fn is not null then
    if to_regprocedure(fn || '(uuid)') is null then raise exception 'silme_fonksiyonu_yok: %', fn; end if;
    execute format('select %s($1)', to_regprocedure(fn || '(uuid)')::regproc) using u;
  end if;
end $$;

create function ortak.oyun_verisini_sil_ek(p_oyun text, u uuid) returns void
language plpgsql security definer set search_path = '' as $$ begin end $$;

-- "Hesabımı tamamen sil": auth kaydı silinir; bütün ortak ve oyun tabloları auth.users'a cascade bağlıdır.
create function ortak.hesabi_sil() returns void
language sql security definer set search_path = '' as $$
  delete from auth.users where id = ortak.kim()
$$;

-- ---------------------------------------------------------------- istemci yetkileri

grant execute on function
  ortak.ben(text), ortak.yas_onayla(), ortak.ad_degistir(text, text), ortak.otomatik_ad(text), ortak.baglama_odulu_al(text),
  ortak.kayit_oku(text), ortak.kayit_yaz(text, jsonb, integer),
  ortak.devir_kodu_al(), ortak.hesap_devral(text),
  ortak.hesap_ozeti(), ortak.oyun_verisini_sil(text), ortak.hesabi_sil()
to authenticated;

-- Postgres her fonksiyona varsayılan olarak PUBLIC çalıştırma yetkisi verir ve şema bazında
-- `alter default privileges` bunu geri alamaz. Bu yüzden her göç kendi sonunda PUBLIC yetkisini açıkça kaldırır;
-- istemciye açık olanlar yukarıda adıyla anon/authenticated'a verilmiştir (tests/sunucu/yetki.test.ts denetler).
revoke execute on all functions in schema ortak from public;
