-- oyun-ortak v0.2: ödeme hakları (RevenueCat), korumalı içerik, etkinlik ödülleri.

-- ---------------------------------------------------------------- ödeme

-- Mağaza ürünü → oyun ve hak. Oyunun göçünde yazılır (ör. ('halka_paket_tam', 'halka', 'paket_tam')).
create table ortak.urunler (
  urun text primary key check (char_length(urun) between 1 and 100),
  oyun_id text not null references ortak.oyunlar on delete cascade,
  hak text not null check (hak ~ '^[a-z0-9_-]{1,40}$')
);
alter table ortak.urunler enable row level security;
create policy herkes_okur on ortak.urunler for select using (true);
grant select on ortak.urunler to anon, authenticated;

-- Hesaba bağlı haklar. Yalnız webhook (servis rolü) yazar; istemci `haklarim` ile okur.
-- Tek seferlik ürünlerde hak süresizdir; iade gelirse durum 'iade' olur (KM-12, KH-9, EN-10, HK-8).
create table ortak.haklar (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  hak text not null,
  durum text not null check (durum in ('aktif', 'iade')),
  kaynak text not null check (kaynak in ('play', 'appstore', 'web', 'elle')),
  urun text,
  dis_id text,                       -- mağazanın işlem kimliği
  guncelleme timestamptz not null default now(),
  primary key (oyun_id, kullanici_id, hak)
);
create index haklar_kullanici on ortak.haklar (kullanici_id);
alter table ortak.haklar enable row level security;

-- Webhook olaylarının tekrar işlenmemesi için (RevenueCat aynı olayı yeniden gönderebilir).
create table ortak.odeme_olaylari (
  olay_id text primary key,
  alindi timestamptz not null default now(),
  sonuc text not null
);
alter table ortak.odeme_olaylari enable row level security;

create function ortak.haklarim(p_oyun text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('hak', hak, 'durum', durum) order by hak), '[]')
  from ortak.haklar where oyun_id = p_oyun and kullanici_id = ortak.kim()
$$;

-- Depolama politikası için: oturumdaki kullanıcının bu oyunda etkin hakkı var mı.
create function ortak.hakki_var(p_oyun text, p_hak text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from ortak.haklar
                 where oyun_id = p_oyun and hak = p_hak and kullanici_id = auth.uid() and durum = 'aktif')
$$;

-- Webhook'un işlediği tek olay. p_tur: 'ver' | 'iade'. Dönüş: ok | tekrar | urun_yok | kullanici_yok.
create function ortak.odeme_olayi(
  p_olay_id text, p_kullanici uuid, p_urun text, p_tur text, p_kaynak text, p_dis_id text default null
) returns text
language plpgsql security definer set search_path = '' as $$
declare u ortak.urunler; sonuc text;
begin
  if exists (select 1 from ortak.odeme_olaylari where olay_id = p_olay_id) then return 'tekrar'; end if;
  select * into u from ortak.urunler where urun = p_urun;
  if not found then
    sonuc := 'urun_yok';
  elsif not exists (select 1 from auth.users where id = p_kullanici) then
    sonuc := 'kullanici_yok';
  elsif p_tur = 'ver' then
    insert into ortak.haklar (oyun_id, kullanici_id, hak, durum, kaynak, urun, dis_id)
    values (u.oyun_id, p_kullanici, u.hak, 'aktif', p_kaynak, p_urun, p_dis_id)
    on conflict (oyun_id, kullanici_id, hak) do update
      set durum = 'aktif', kaynak = excluded.kaynak, urun = excluded.urun, dis_id = excluded.dis_id, guncelleme = now();
    sonuc := 'ok';
  elsif p_tur = 'iade' then
    update ortak.haklar set durum = 'iade', guncelleme = now()
      where oyun_id = u.oyun_id and kullanici_id = p_kullanici and hak = u.hak;
    sonuc := 'ok';
  else
    raise exception 'odeme_turu: %', p_tur;
  end if;
  insert into ortak.odeme_olaylari (olay_id, sonuc) values (p_olay_id, sonuc) on conflict do nothing;
  return sonuc;
end $$;

-- RevenueCat TRANSFER: haklar bir mağaza kimliğinden ötekine geçer (ör. başka hesapta "geri yükle").
-- Tek webhook bütün oyunlara hizmet eder; aktarım yalnız olayı gönderen RevenueCat uygulamasının oyunuyla
-- sınırlıdır (oyunlar.ayarlar.odeme.revenuecat_uygulamalari dizisi). Eşleşme yoksa hiçbir şey taşınmaz.
create function ortak.hak_aktar(p_olay_id text, p_uygulama text, p_kimden uuid[], p_kime uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_oyun text; sonuc text;
begin
  if exists (select 1 from ortak.odeme_olaylari where olay_id = p_olay_id) then return 'tekrar'; end if;
  select id into v_oyun from ortak.oyunlar
    where ayarlar -> 'odeme' -> 'revenuecat_uygulamalari' ? p_uygulama;
  if v_oyun is null then
    sonuc := 'oyun_yok';
  elsif not exists (select 1 from auth.users where id = p_kime) then
    sonuc := 'kullanici_yok';
  else
    insert into ortak.haklar (oyun_id, kullanici_id, hak, durum, kaynak, urun, dis_id)
      select oyun_id, p_kime, hak, durum, kaynak, urun, dis_id from ortak.haklar
      where oyun_id = v_oyun and kullanici_id = any (p_kimden)
      on conflict (oyun_id, kullanici_id, hak) do update
        set durum = case when ortak.haklar.durum = 'aktif' or excluded.durum = 'aktif' then 'aktif' else 'iade' end,
            guncelleme = now();
    delete from ortak.haklar where oyun_id = v_oyun and kullanici_id = any (p_kimden) and kullanici_id <> p_kime;
    sonuc := 'ok';
  end if;
  insert into ortak.odeme_olaylari (olay_id, sonuc) values (p_olay_id, sonuc);
  return sonuc;
end $$;

-- Korumalı içerik (HK-8): ücretli dosyalar `korumali` kovasında `<oyun>/<hak>/...` yolunda.
-- Yalnız o hakkı etkin olan hesap okuyabilir; yükleme servis rolüyle (yerel betik).
insert into storage.buckets (id, name, public) values ('korumali', 'korumali', false) on conflict (id) do nothing;
create policy korumali_okuma on storage.objects for select to authenticated
  using (bucket_id = 'korumali'
         and ortak.hakki_var((storage.foldername(name))[1], (storage.foldername(name))[2]));

-- ---------------------------------------------------------------- etkinlik ödülleri

-- Kozmetik ödüller (KM-9, EN-9, HK-7): cihazda hesaplanır, sunucu yalnız kaydı tutar; ağsız kazanılan
-- ödül bağlanınca bir kez eşitlenir. Para birimi yok, bu yüzden istemcinin beyanı kabul edilir.
create table ortak.oduller (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  odul text not null check (odul ~ '^[a-z0-9_:.-]{1,64}$'),
  kaynak text check (char_length(kaynak) <= 64),
  kazanildi timestamptz not null default now(),
  primary key (oyun_id, kullanici_id, odul)
);
create index oduller_kullanici on ortak.oduller (kullanici_id);
alter table ortak.oduller enable row level security;

-- p_oduller: [{ odul, kaynak?, kazanildi? }], en çok 100. Var olan ödül tekrar yazılmaz. Dönüş: yeni kaydedilen sayı.
create function ortak.odul_kaydet(p_oyun text, p_oduller jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim(); n integer;
begin
  if jsonb_typeof(p_oduller) <> 'array' or jsonb_array_length(p_oduller) > 100 then
    raise exception 'oduller_gecersiz';
  end if;
  if not ortak.hiz_siniri('odul:' || u, 30, 60) then raise exception 'cok_istek' using errcode = '54000'; end if;
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak, kazanildi)
    select p_oyun, u, x ->> 'odul', x ->> 'kaynak',
           least(coalesce((x ->> 'kazanildi')::timestamptz, now()), now())
    from jsonb_array_elements(p_oduller) x
    on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create function ortak.odullerim(p_oyun text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('odul', odul, 'kaynak', kaynak, 'kazanildi', kazanildi) order by kazanildi), '[]')
  from ortak.oduller where oyun_id = p_oyun and kullanici_id = ortak.kim()
$$;

-- Sıralama ödülü (HK-3: etkinlik sıralamasında ilk %10): servis rolü ya da cron çağırır.
-- Sıra `ortak.siralama` ile aynı kuralla (yön, eşitlik); eşitler aynı sırayı paylaşır. Dönüş: ödül alan sayısı.
create function ortak.siralama_odulu_ver(p_oyun text, p_tur text, p_donem text, p_odul text, p_oran numeric)
returns integer
language plpgsql security definer set search_path = '' as $$
declare a jsonb; yon int; ikincilli boolean; toplam int; n int;
begin
  select coalesce(ayarlar -> 'siralama', '{}') into a from ortak.oyunlar where id = p_oyun;
  yon := case when a ->> 'yon' = 'artan' then -1 else 1 end;
  ikincilli := coalesce(a ->> 'esitlik', 'ortak') = 'ikincil';
  select count(*) into toplam from ortak.skorlar where oyun_id = p_oyun and tur = p_tur and donem = p_donem;
  with s as (
    select kullanici_id,
      rank() over (order by puan * yon desc, case when ikincilli then ikincil end asc nulls last) as sira
    from ortak.skorlar where oyun_id = p_oyun and tur = p_tur and donem = p_donem
  )
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak)
    select p_oyun, kullanici_id, p_odul, p_tur || ':' || p_donem from s
    where sira <= greatest(ceil(toplam * p_oran), 1)
    on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- devir ve silme

-- Haklar ve kozmetik ödüller her devirde taşınır (var olan hesaba da): satın alma gerçektir, ödül kozmetiktir.
create function ortak.devir_her_zaman(eski uuid, yeni uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into ortak.haklar (oyun_id, kullanici_id, hak, durum, kaynak, urun, dis_id)
    select oyun_id, yeni, hak, durum, kaynak, urun, dis_id from ortak.haklar where kullanici_id = eski
    on conflict (oyun_id, kullanici_id, hak) do update
      set durum = case when ortak.haklar.durum = 'aktif' or excluded.durum = 'aktif' then 'aktif' else 'iade' end;
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak, kazanildi)
    select oyun_id, yeni, odul, kaynak, kazanildi from ortak.oduller where kullanici_id = eski
    on conflict do nothing;
end $$;

-- hesap_devral: v0.1 gövdesi + `devir_her_zaman` çağrısı.
create or replace function ortak.hesap_devral(p_kod text) returns jsonb
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
  perform pg_advisory_xact_lock(hashtextextended('devir:' || yeni::text, 0));
  v_bos := not exists (select 1 from ortak.oyuncular where kullanici_id = yeni)
       and not exists (select 1 from ortak.kayitlar where kullanici_id = yeni)
       and not exists (select 1 from ortak.skorlar where kullanici_id = yeni)
       and not exists (select 1 from ortak.denemeler where kullanici_id = yeni)
       and not exists (select 1 from ortak.lig_uyeleri where kullanici_id = yeni);

  insert into ortak.profiller (kullanici_id, yas_onay)
    select yeni, yas_onay from ortak.profiller where kullanici_id = eski
    on conflict (kullanici_id) do update
      set yas_onay = coalesce(ortak.profiller.yas_onay, excluded.yas_onay);

  if v_bos then
    update ortak.oyuncular set kullanici_id = yeni where kullanici_id = eski;
  else
    with silinen as (
      delete from ortak.oyuncular where kullanici_id = eski
      returning oyun_id, ad, ad_otomatik
    )
    insert into ortak.oyuncular as y (oyun_id, kullanici_id, ad, ad_anahtari, ad_otomatik)
      select s.oyun_id, yeni, s.ad, ortak.ad_anahtari(s.ad), s.ad_otomatik from silinen s
    on conflict (oyun_id, kullanici_id) do update set
      ad = coalesce(y.ad, excluded.ad),
      ad_anahtari = coalesce(y.ad_anahtari, excluded.ad_anahtari),
      ad_otomatik = case when y.ad is null then excluded.ad_otomatik else y.ad_otomatik end;
  end if;

  update ortak.kayitlar e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.kayitlar y where y.oyun_id = e.oyun_id and y.kullanici_id = yeni);

  if v_bos then perform ortak.devir_ek(eski, yeni); end if;
  perform ortak.devir_her_zaman(eski, yeni);

  delete from auth.users where id = eski;
  return jsonb_build_object('oyunlar', to_jsonb(v_oyunlar), 'skorlar_tasindi', v_bos);
end $$;

create or replace function ortak.oyun_verisini_sil_ek(p_oyun text, u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from ortak.skorlar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.denemeler where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.lig_uyeleri where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.oduller where oyun_id = p_oyun and kullanici_id = u;
  -- Satın alma kaydı da silinir; mağazadaki satın alma durur, cihazda "geri yükle" ile hak döner.
  delete from ortak.haklar where oyun_id = p_oyun and kullanici_id = u;
end $$;

-- ---------------------------------------------------------------- saklama ve yetkiler

select cron.schedule('ortak-odeme-olaylari-temizle', '50 2 * * *',
  $$delete from ortak.odeme_olaylari where alindi < now() - interval '180 days'$$);

revoke execute on all functions in schema ortak from public;
grant execute on function ortak.haklarim(text), ortak.hakki_var(text, text),
  ortak.odul_kaydet(text, jsonb), ortak.odullerim(text) to authenticated;
