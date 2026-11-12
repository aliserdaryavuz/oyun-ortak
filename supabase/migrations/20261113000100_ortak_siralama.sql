-- oyun-ortak: skorlar, durum tutan denemeler, haftalık lig, zamanlanmış işler.
-- Skoru yalnız servis rolü yazar (dogrula-<oyun> Edge Function); istemcinin bildirdiği puan kullanılmaz.

create table ortak.skorlar (
  id bigserial primary key,
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  tur text not null check (tur in ('gunluk', 'etkinlik')),
  donem text not null check (char_length(donem) between 1 and 64),  -- gün (YYYY-MM-DD) ya da etkinlik kimliği
  puan numeric not null,
  ikincil numeric,                   -- eşitlik bozucu (ör. toplam süre), küçük olan önde
  lig_puani numeric,                 -- lig için o günün puanı (oyunun formülü, HK-2)
  run_id uuid not null unique,       -- aynı gönderim iki skor üretmez (EN-1)
  ayrinti jsonb,                     -- denetim için; 90 gün sonra boşaltılır
  bayraklar text[] not null default '{}',
  olusturma timestamptz not null default now(),
  unique (oyun_id, tur, donem, kullanici_id)  -- ilk gönderim resmî, sonrakiler prova
);
create index skorlar_kullanici on ortak.skorlar (kullanici_id);
alter table ortak.skorlar enable row level security;

-- Durum tutan deneme (KH-1; Halka başlat/ipucu; sezgi attempts). `sira` iyimser kilittir.
create table ortak.denemeler (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  kullanici_id uuid not null references auth.users on delete cascade,
  anahtar text not null check (char_length(anahtar) between 1 and 128),
  sira integer not null default 0,
  durum jsonb not null default '{}',
  bitti boolean not null default false,
  olusturma timestamptz not null default now(),
  guncelleme timestamptz not null default now(),
  primary key (oyun_id, kullanici_id, anahtar)
);
create index denemeler_kullanici on ortak.denemeler (kullanici_id);
alter table ortak.denemeler enable row level security;

create table ortak.lig_gruplari (
  id bigserial primary key,
  oyun_id text not null references ortak.oyunlar on delete cascade,
  hafta date not null,
  kademe smallint not null,
  bant integer not null default 0,   -- seviye bandı (KH-4)
  kapandi boolean not null default false,
  olusturma timestamptz not null default now()
);
create index lig_gruplari_acik on ortak.lig_gruplari (oyun_id, hafta, kademe, bant) where not kapandi;
alter table ortak.lig_gruplari enable row level security;

create table ortak.lig_uyeleri (
  grup_id bigint not null references ortak.lig_gruplari on delete cascade,
  oyun_id text not null,
  hafta date not null,
  kullanici_id uuid not null references auth.users on delete cascade,
  puan numeric not null default 0,
  ikincil numeric not null default 0,
  sira integer,                      -- kapanışta yazılır
  sonuc text check (sonuc in ('cikti', 'kaldi', 'indi')),
  primary key (oyun_id, hafta, kullanici_id)
);
create index lig_uyeleri_grup on ortak.lig_uyeleri (grup_id);
create index lig_uyeleri_kullanici on ortak.lig_uyeleri (kullanici_id);
alter table ortak.lig_uyeleri enable row level security;

-- ---------------------------------------------------------------- lig

-- Haftanın grubu: aynı kademe ve seviye bandında dolmamış en eski grup, yoksa yeni grup.
-- Danışma kilidi eş zamanlı katılımda grubun taşmasını önler.
create function ortak.lig_ata(p_oyun text, p_kullanici uuid, p_hafta date) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  a jsonb;
  o ortak.oyuncular;
  v_bant integer;
  boy integer;
  g bigint;
begin
  select grup_id into g from ortak.lig_uyeleri where oyun_id = p_oyun and hafta = p_hafta and kullanici_id = p_kullanici;
  if g is not null then return g; end if;

  select ayarlar -> 'lig' into a from ortak.oyunlar where id = p_oyun;
  if a is null then return null; end if;
  select * into o from ortak.oyuncular where oyun_id = p_oyun and kullanici_id = p_kullanici;
  v_bant := case when coalesce((a ->> 'bant_genisligi')::int, 0) > 0
                 then coalesce(o.seviye_puani, 0) / (a ->> 'bant_genisligi')::int else 0 end;
  boy := coalesce((a ->> 'grup_boyu')::int, 50);

  perform pg_advisory_xact_lock(hashtextextended(p_oyun || '|' || p_hafta || '|' || coalesce(o.kademe, 0) || '|' || v_bant, 0));

  select gr.id into g from ortak.lig_gruplari gr
  where gr.oyun_id = p_oyun and gr.hafta = p_hafta and gr.kademe = coalesce(o.kademe, 0) and gr.bant = v_bant
    and not gr.kapandi
    and (select count(*) from ortak.lig_uyeleri u where u.grup_id = gr.id) < boy
  order by gr.id limit 1;
  if g is null then
    insert into ortak.lig_gruplari (oyun_id, hafta, kademe, bant)
    values (p_oyun, p_hafta, coalesce(o.kademe, 0), v_bant) returning id into g;
  end if;
  insert into ortak.lig_uyeleri (grup_id, oyun_id, hafta, kullanici_id) values (g, p_oyun, p_hafta, p_kullanici);
  return g;
end $$;

-- Haftalık lig puanı: haftanın en iyi N gününün lig puanı toplamı (KM-6, EN-3, HK-2). Kapanmış grup değişmez.
create function ortak.lig_puani_guncelle(p_oyun text, p_kullanici uuid, p_hafta date) returns void
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  select coalesce((ayarlar -> 'lig' ->> 'en_iyi_gun')::int, 5) into n from ortak.oyunlar where id = p_oyun;
  update ortak.lig_uyeleri u set (puan, ikincil) = (
    select coalesce(sum(x.lig_puani), 0), coalesce(sum(x.ikincil), 0) from (
      select s.lig_puani, coalesce(s.ikincil, 0) as ikincil from ortak.skorlar s
      where s.oyun_id = p_oyun and s.kullanici_id = p_kullanici and s.tur = 'gunluk'
        and s.donem between p_hafta::text and (p_hafta + 6)::text and s.lig_puani is not null
      order by s.lig_puani desc, s.ikincil asc nulls last limit n) x)
  where u.oyun_id = p_oyun and u.hafta = p_hafta and u.kullanici_id = p_kullanici
    and not exists (select 1 from ortak.lig_gruplari g where g.id = u.grup_id and g.kapandi);
end $$;

-- Kapanış: geçmiş haftaların açık grupları. Puanı 0 olan sıraya girmez ve kademesi değişmez.
-- İlk %cikis bir kademe çıkar, son %inis bir kademe iner; uçlarda kalır. Tekrar çağrılması zararsız.
create function ortak.lig_kapat() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  g ortak.lig_gruplari;
  a jsonb;
  ust int;
  n int;
  kapanan int := 0;
begin
  for g in
    select * from ortak.lig_gruplari
    where not kapandi and hafta < ortak.iso_hafta(ortak.bugun())
    order by id for update skip locked
  loop
    select ayarlar -> 'lig' into a from ortak.oyunlar where id = g.oyun_id;
    ust := greatest(coalesce(jsonb_array_length(a -> 'kademeler'), 1) - 1, 0);

    with r as (
      select kullanici_id,
        rank() over (order by puan desc,
          case when coalesce(a ->> 'esitlik', 'ortak') = 'ikincil' then ikincil end asc nulls last) as sira
      from ortak.lig_uyeleri where grup_id = g.id and puan > 0
    ), sayi as (select count(*)::int as c from r)
    update ortak.lig_uyeleri u set
      sira = r.sira,
      sonuc = case
        when r.sira <= floor(sayi.c * coalesce((a ->> 'cikis_orani')::numeric, 0.2)) and g.kademe < ust then 'cikti'
        when r.sira > sayi.c - floor(sayi.c * coalesce((a ->> 'inis_orani')::numeric, 0.2)) and g.kademe > 0 then 'indi'
        else 'kaldi' end
    from r, sayi
    where u.grup_id = g.id and u.kullanici_id = r.kullanici_id;

    update ortak.lig_uyeleri set sonuc = 'kaldi' where grup_id = g.id and sonuc is null;

    update ortak.oyuncular o set kademe = o.kademe + case u.sonuc when 'cikti' then 1 else -1 end
    from ortak.lig_uyeleri u
    where u.grup_id = g.id and u.sonuc in ('cikti', 'indi')
      and o.oyun_id = g.oyun_id and o.kullanici_id = u.kullanici_id;

    update ortak.lig_gruplari set kapandi = true where id = g.id;
    kapanan := kapanan + 1;
  end loop;
  return kapanan;
end $$;

-- Oyuncunun bu haftaki grubu ve geçen haftanın sonucu.
create function ortak.lig_durumu(p_oyun text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  v_hafta date := ortak.iso_hafta(ortak.bugun());
  a jsonb;
  g bigint;
  o ortak.oyuncular;
  onceki jsonb;
  uyeler jsonb;
begin
  select ayarlar -> 'lig' into a from ortak.oyunlar where id = p_oyun;
  if a is null then raise exception 'lig_yok'; end if;
  select * into o from ortak.oyuncular where oyun_id = p_oyun and kullanici_id = u;
  select jsonb_build_object('hafta', l.hafta, 'sira', l.sira, 'sonuc', l.sonuc, 'puan', l.puan) into onceki
    from ortak.lig_uyeleri l join ortak.lig_gruplari gr on gr.id = l.grup_id
    where l.oyun_id = p_oyun and l.kullanici_id = u and gr.kapandi
    order by l.hafta desc limit 1;
  select grup_id into g from ortak.lig_uyeleri where oyun_id = p_oyun and hafta = v_hafta and kullanici_id = u;

  if g is not null then
    select jsonb_agg(jsonb_build_object('sira', x.sira, 'ad', x.ad, 'puan', x.puan, 'ben', x.ben) order by x.sira, x.ad)
    into uyeler from (
      select rank() over (order by l.puan desc,
               case when coalesce(a ->> 'esitlik', 'ortak') = 'ikincil' then l.ikincil end asc nulls last) as sira,
             oy.ad, l.puan, l.kullanici_id = u as ben
      from ortak.lig_uyeleri l
      left join ortak.oyuncular oy on oy.oyun_id = p_oyun and oy.kullanici_id = l.kullanici_id
      where l.grup_id = g) x;
  end if;

  return jsonb_build_object(
    'hafta', v_hafta,
    'kademe', coalesce(o.kademe, 0),
    'kademe_adi', a -> 'kademeler' ->> coalesce(o.kademe, 0),
    'katildi', g is not null,
    'uyeler', coalesce(uyeler, '[]'::jsonb),
    'onceki', onceki);
end $$;

-- ---------------------------------------------------------------- skor yazımı (yalnız servis rolü)

-- Dönüş: { durum: 'yeni' | 'tekrar' | 'prova', id }
--   tekrar: aynı run_id daha önce yazılmış (yeniden gönderim);
--   prova: bu dönemde resmî skor zaten var, bu gönderim sayılmaz.
create function ortak.skor_yaz(
  p_oyun text, p_kullanici uuid, p_tur text, p_donem text, p_puan numeric, p_run_id uuid,
  p_ikincil numeric default null, p_lig_puani numeric default null, p_ayrinti jsonb default null,
  p_bayraklar text[] default '{}', p_seviye_puani integer default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id bigint; hafta date;
begin
  select id into v_id from ortak.skorlar where run_id = p_run_id;
  if v_id is not null then return jsonb_build_object('durum', 'tekrar', 'id', v_id); end if;

  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, p_kullanici)
    on conflict (oyun_id, kullanici_id) do update set son_gorulme = now();
  if p_seviye_puani is not null then
    update ortak.oyuncular set seviye_puani = p_seviye_puani where oyun_id = p_oyun and kullanici_id = p_kullanici;
  end if;

  insert into ortak.skorlar (oyun_id, kullanici_id, tur, donem, puan, ikincil, lig_puani, run_id, ayrinti, bayraklar)
  values (p_oyun, p_kullanici, p_tur, p_donem, p_puan, p_ikincil, p_lig_puani, p_run_id, p_ayrinti, p_bayraklar)
  on conflict (oyun_id, tur, donem, kullanici_id) do nothing
  returning id into v_id;
  if v_id is null then return jsonb_build_object('durum', 'prova'); end if;

  if p_tur = 'gunluk' and p_lig_puani is not null
     and exists (select 1 from ortak.oyunlar where id = p_oyun and ayarlar ? 'lig') then
    hafta := ortak.iso_hafta(p_donem::date);
    perform ortak.lig_ata(p_oyun, p_kullanici, hafta);
    perform ortak.lig_puani_guncelle(p_oyun, p_kullanici, hafta);
  end if;
  return jsonb_build_object('durum', 'yeni', 'id', v_id);
end $$;

-- ---------------------------------------------------------------- denemeler (yalnız servis rolü)

create function ortak.deneme_al(p_oyun text, p_kullanici uuid, p_anahtar text) returns ortak.denemeler
language sql security definer set search_path = '' as $$
  insert into ortak.denemeler (oyun_id, kullanici_id, anahtar) values (p_oyun, p_kullanici, p_anahtar)
  on conflict (oyun_id, kullanici_id, anahtar) do update set guncelleme = ortak.denemeler.guncelleme
  returning *
$$;

-- p_sira okunan sıra; eşleşirse durum yazılır ve sıra bir artar. Eşleşmezse ya da bittiyse null.
create function ortak.deneme_ilerlet(
  p_oyun text, p_kullanici uuid, p_anahtar text, p_sira integer, p_durum jsonb, p_bitti boolean default false
) returns ortak.denemeler
language sql security definer set search_path = '' as $$
  update ortak.denemeler set sira = sira + 1, durum = p_durum, bitti = p_bitti, guncelleme = now()
  where oyun_id = p_oyun and kullanici_id = p_kullanici and anahtar = p_anahtar and sira = p_sira and not bitti
  returning *
$$;

revoke execute on function ortak.skor_yaz(text, uuid, text, text, numeric, uuid, numeric, numeric, jsonb, text[], integer),
  ortak.deneme_al(text, uuid, text), ortak.deneme_ilerlet(text, uuid, text, integer, jsonb, boolean),
  ortak.lig_ata(text, uuid, date), ortak.lig_puani_guncelle(text, uuid, date), ortak.lig_kapat(),
  ortak.hiz_siniri(text, integer, integer)
from anon, authenticated;

-- ---------------------------------------------------------------- sıralama okuma

-- İlk N + oyuncunun çevresi. user_id dönmez; oyuncunun satırı `ben` ile işaretlenir.
-- Eşit puana aynı sıra (ya da ayarla ikincil ölçüt). Toplam dagilim_esigi'nin altındaysa yüzdelik dönmez (KH-3).
create function ortak.siralama(p_oyun text, p_tur text, p_donem text, p_ilk integer default 10, p_cevre integer default 3)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a jsonb;
  yon int;
  ikincilli boolean;
  esik int;
  ben uuid := auth.uid();
  r jsonb;
begin
  select coalesce(ayarlar -> 'siralama', '{}') into a from ortak.oyunlar where id = p_oyun;
  if not found then raise exception 'oyun_yok'; end if;
  yon := case when a ->> 'yon' = 'artan' then -1 else 1 end;
  ikincilli := coalesce(a ->> 'esitlik', 'ortak') = 'ikincil';
  esik := coalesce((a ->> 'dagilim_esigi')::int, 50);
  p_ilk := least(greatest(p_ilk, 1), 100);
  p_cevre := least(greatest(p_cevre, 0), 10);

  with s as (
    select sk.kullanici_id, sk.puan, sk.ikincil,
      rank() over (order by sk.puan * yon desc, case when ikincilli then sk.ikincil end asc nulls last) as sira,
      row_number() over (order by sk.puan * yon desc, case when ikincilli then sk.ikincil end asc nulls last, sk.id) as sn
    from ortak.skorlar sk
    where sk.oyun_id = p_oyun and sk.tur = p_tur and sk.donem = p_donem
  ),
  t as (select count(*)::int as c from s),
  b as (select sn, sira from s where s.kullanici_id = ben)
  select jsonb_build_object(
    'toplam', t.c,
    'ben', (select jsonb_build_object('sira', b.sira,
              'ust_yuzde', case when t.c >= esik then ceil(100.0 * b.sira / t.c) end) from b),
    'satirlar', coalesce((
      select jsonb_agg(jsonb_build_object('sira', s.sira, 'ad', o.ad, 'puan', s.puan, 'ikincil', s.ikincil,
                                          'ben', coalesce(s.kullanici_id = ben, false)) order by s.sn)
      from s left join ortak.oyuncular o on o.oyun_id = p_oyun and o.kullanici_id = s.kullanici_id
      where s.sn <= p_ilk or exists (select 1 from b where abs(s.sn - b.sn) <= p_cevre)), '[]'::jsonb))
  into r from t;
  return r;
end $$;

grant execute on function ortak.siralama(text, text, text, integer, integer) to anon, authenticated;
grant execute on function ortak.lig_durumu(text) to authenticated;

-- ---------------------------------------------------------------- devir ve silme kancaları

create or replace function ortak.devir_ek(eski uuid, yeni uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  update ortak.skorlar e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.skorlar y
                      where y.oyun_id = e.oyun_id and y.tur = e.tur and y.donem = e.donem and y.kullanici_id = yeni);
  update ortak.denemeler e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.denemeler y
                      where y.oyun_id = e.oyun_id and y.anahtar = e.anahtar and y.kullanici_id = yeni);
  update ortak.lig_uyeleri e set kullanici_id = yeni
    where e.kullanici_id = eski
      and not exists (select 1 from ortak.lig_uyeleri y
                      where y.oyun_id = e.oyun_id and y.hafta = e.hafta and y.kullanici_id = yeni);
  for r in select distinct oyun_id, hafta from ortak.lig_uyeleri where kullanici_id = yeni loop
    perform ortak.lig_puani_guncelle(r.oyun_id, yeni, r.hafta);
  end loop;
end $$;

create or replace function ortak.oyun_verisini_sil_ek(p_oyun text, u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from ortak.skorlar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.denemeler where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.lig_uyeleri where oyun_id = p_oyun and kullanici_id = u;
end $$;

-- ---------------------------------------------------------------- zamanlanmış işler

create extension if not exists pg_cron with schema pg_catalog;

-- Lig kapanışı: Pazartesi 04:00 İstanbul (01:00 UTC). Geç gönderim pencereleri (gün + 3 saat) kapandıktan sonra.
select cron.schedule('ortak-lig-kapat', '0 1 * * 1', $$select ortak.lig_kapat()$$);
-- İstek sınırı sayaçları.
select cron.schedule('ortak-hiz-temizle', '*/10 * * * *',
  $$delete from ortak.hiz_sinirlari where pencere < now() - interval '2 hours'$$);
-- Bağlanmamış, 90 gündür görünmeyen anonim hesaplar (MAU ve 500 MB sınırı).
select cron.schedule('ortak-anonim-temizle', '20 2 * * *', $$
  delete from auth.users u where u.is_anonymous and u.created_at < now() - interval '90 days'
    and not exists (select 1 from ortak.oyuncular o where o.kullanici_id = u.id and o.son_gorulme > now() - interval '90 days')
$$);
-- 90 günden eski skor ayrıntısı ve denemeler (puan kalır).
select cron.schedule('ortak-saklama', '40 2 * * *', $$
  update ortak.skorlar set ayrinti = null where ayrinti is not null and olusturma < now() - interval '90 days';
  delete from ortak.denemeler where guncelleme < now() - interval '90 days';
  delete from ortak.devirler where bitis < now();
$$);

-- Bkz. ortak_temel sonu: PUBLIC çalıştırma yetkisi her göçte açıkça kaldırılır.
revoke execute on all functions in schema ortak from public;
