-- Halka Kelime: günlük bulmacanın cevapları yalnız sunucuda (karar C1; Halka docs/SUNUCU_GECISI.md Adım 1).
-- İstemci dosyası (public/puzzles) yalnız halkaları ve başlangıcı taşır; doğru ışınlar, ipuçları, cevap ve anlamlar buradan.
-- Testi: halka-kelime tests/sql.test.ts "gunluk_" (PGlite).
--
-- PostgREST: `halka` şeması API'ye açılmaz. İstemci public'teki ince sarmalayıcıları çağırır
-- (rpc('halka_gunluk_kontrol') vb.); halka.* işlevleri yalnız sarmalayıcı üzerinden. Tablo yalnız servis rolüne;
-- yükleme betiği public.halka_gunluk_yukle'yi servis anahtarıyla çağırır.

create table halka.gunluk_bulmacalar (
  tarih date primary key,
  halkalar jsonb not null,           -- string[][]: halkalar[r][i]
  cevaplar text[] not null,          -- cevaplar[k] = çözümde k. ışının kelimesi
  cozum jsonb,                       -- { rot: int[], flip: boolean[] }
  anlamlar jsonb,                    -- { kelime: anlam }
  kilit_sirasi integer[],            -- kilit ipucunun halka sırası
  ek jsonb                           -- çözülünce gösterilen: { pairs } (Zıt), { bonus } (Taç, Spiral, Joker)
);
alter table halka.gunluk_bulmacalar enable row level security;
revoke all on halka.gunluk_bulmacalar from public, anon, authenticated;
grant all on halka.gunluk_bulmacalar to service_role;

-- Var olan takvim (public.hk_daily_puzzles) kopyalanır; çözüm, anlam ve kilit sırasını yükleme betiği doldurur
-- (halka-kelime scripts/upload_daily.ts). Boş veritabanında (hk_ tablosu yok) atlanır.
do $$ begin
  if to_regclass('public.hk_daily_puzzles') is not null then
    insert into halka.gunluk_bulmacalar (tarih, halkalar, cevaplar)
    select date, rings, answers from public.hk_daily_puzzles
    on conflict (tarih) do nothing;
  end if;
end $$;

-- İstek sınırı (ortak.hiz_siniri): girişliyse kullanıcı, değilse istemci IP'si başına dakikada 300 çağrı.
-- ponytail: aynı IP arkasındaki girişsiz oyuncular (okul, kampüs NAT) tek sayaçta; sorun olursa sınır yükselir.
create function halka.gunluk_sinir() returns void
language plpgsql set search_path = '' as $$
declare
  basliklar json := nullif(current_setting('request.headers', true), '')::json;
  kim text := coalesce(auth.uid()::text, basliklar ->> 'cf-connecting-ip',
                       trim(split_part(basliklar ->> 'x-forwarded-for', ',', 1)), 'bilinmeyen');
begin
  if not ortak.hiz_siniri('halka-gunluk:' || kim, 300, 60) then
    raise exception 'cok_istek' using errcode = '54000';
  end if;
end $$;

-- Halka konumlarını okur, her ışın doğru mu söyler. Yalnız İstanbul bugünü; başka gün null.
-- Okuma kuralı src/engine/model.ts (readRay, correctRays) ile aynı: ışın k, halka r'den
-- çevrilmemiş halkalar[r][(k + rot) mod N], ters çevrilmiş halkalar[r][(rot − k) mod N]; aynı kelime iki ışında sayılmaz.
create function halka.gunluk_kontrol(p_tarih date, p_rot integer[], p_flip boolean[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p halka.gunluk_bulmacalar;
  h int; n int; k int; r int; i int; idx int;
  w text;
  kalan text[];
  dogru boolean[] := '{}';
  cozuldu boolean;
begin
  perform halka.gunluk_sinir();
  if p_tarih is distinct from ortak.bugun() then return null; end if;
  select * into p from halka.gunluk_bulmacalar where tarih = p_tarih;
  if not found then return null; end if;
  h := jsonb_array_length(p.halkalar);
  n := jsonb_array_length(p.halkalar -> 0);
  if array_ndims(p_rot) is distinct from 1 or array_ndims(p_flip) is distinct from 1
     or cardinality(p_rot) <> h or cardinality(p_flip) <> h
     or array_position(p_rot, null) is not null or array_position(p_flip, null) is not null then
    raise exception 'gecersiz_durum' using errcode = '22023';
  end if;
  kalan := p.cevaplar;
  for k in 0 .. n - 1 loop
    w := '';
    for r in 0 .. h - 1 loop
      idx := case when p_flip[r + 1] then ((p_rot[r + 1] % n - k) % n + n) % n
                  else ((k + p_rot[r + 1] % n) % n + n) % n end;
      w := w || (p.halkalar -> r ->> idx);
    end loop;
    i := array_position(kalan, w);
    dogru := dogru || (i is not null);
    if i is not null then kalan := kalan[:i - 1] || kalan[i + 1:]; end if;
  end loop;
  cozuldu := not (false = any (dogru));
  return jsonb_build_object('dogru', to_jsonb(dogru), 'cozuldu', cozuldu)
    || case when cozuldu then jsonb_strip_nulls(jsonb_build_object(
         'cevaplar', to_jsonb(p.cevaplar), 'anlamlar', coalesce(p.anlamlar, '{}'::jsonb), 'ek', p.ek))
       else '{}'::jsonb end;
end $$;

-- İpucu (yalnız bugün). tur 'anlam': p_sira. ışının (0'dan) cevabının anlamı, kelime dönmez.
-- tur 'kilit': kilit sırasında p_sira. (0'dan) halkanın çözüm konumu { halka, rot, flip }; sıra bitince kalan halkalar.
-- tur 'tema': yalnız sayılır (tema dosyada zaten açık).
-- Cevabı açan ipuçları (anlam, kilit) oturum ister (anonim oturum yeter): ipucu oturumsuz çekilip sonra girişle
-- "ipucusuz" gönderilemesin. Verilen her ipucu ortak.denemeler'e (anahtar gunluk:<tarih>, durum.ipuclari = verilen
-- türler; sayı = uzunluk) yazılır. Tema oturumsuz da verilir, o zaman sayılmaz (dosyada zaten var).
create function halka.gunluk_ipucu(p_tarih date, p_tur text, p_sira integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p halka.gunluk_bulmacalar;
  u uuid := auth.uid();
  sira int[];
  r int;
  sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  if p_tur in ('anlam', 'kilit') and u is null then
    raise exception 'oturum_gerekli' using errcode = '28000';
  end if;
  if p_tarih is distinct from ortak.bugun() then return null; end if;
  select * into p from halka.gunluk_bulmacalar where tarih = p_tarih;
  if not found then return null; end if;
  if p_tur = 'anlam' then
    sonuc := case when p.anlamlar ->> p.cevaplar[p_sira + 1] is not null
                  then jsonb_build_object('anlam', p.anlamlar ->> p.cevaplar[p_sira + 1]) end;
  elsif p_tur = 'kilit' then
    sira := coalesce(p.kilit_sirasi, '{}')
      || array(select g from generate_series(0, jsonb_array_length(p.halkalar) - 1) g
               where g <> all (coalesce(p.kilit_sirasi, '{}')) order by g);
    r := sira[p_sira + 1];
    if r is not null and p.cozum is not null then
      sonuc := jsonb_build_object('halka', r, 'rot', p.cozum -> 'rot' -> r, 'flip', p.cozum -> 'flip' -> r);
    end if;
  elsif p_tur = 'tema' then
    sonuc := '{}'::jsonb;
  else
    raise exception 'gecersiz_tur' using errcode = '22023';
  end if;
  if sonuc is not null and u is not null then
    perform ortak.deneme_al('halka', u, 'gunluk:' || p_tarih);
    update ortak.denemeler
       set durum = durum || jsonb_build_object('ipuclari', coalesce(durum -> 'ipuclari', '[]'::jsonb) || to_jsonb(p_tur)),
           guncelleme = now()
     where oyun_id = 'halka' and kullanici_id = u and anahtar = 'gunluk:' || p_tarih and not bitti;
  end if;
  return sonuc;
end $$;

-- Geçmiş günün (İstanbul bugününden önce) cevap paketi; arşiv bir kez çeker, cihazda saklar. Bugün ve gelecek null.
create function halka.gunluk_cevap(p_tarih date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  if p_tarih is null or p_tarih >= ortak.bugun() then return null; end if;
  select jsonb_strip_nulls(jsonb_build_object('cevaplar', to_jsonb(g.cevaplar), 'cozum', g.cozum, 'anlamlar', g.anlamlar,
                                              'kilit_sirasi', to_jsonb(g.kilit_sirasi), 'ek', g.ek))
    into sonuc from halka.gunluk_bulmacalar g where g.tarih = p_tarih;
  return sonuc;
end $$;

revoke execute on function halka.gunluk_sinir(), halka.gunluk_kontrol(date, integer[], boolean[]),
  halka.gunluk_ipucu(date, text, integer), halka.gunluk_cevap(date) from public, anon, authenticated;

-- ---------------------------------------------------------------- public sarmalayıcılar (PostgREST)

create function public.halka_gunluk_kontrol(p_tarih date, p_rot integer[], p_flip boolean[]) returns jsonb
language sql security definer set search_path = '' as $$ select halka.gunluk_kontrol(p_tarih, p_rot, p_flip) $$;

create function public.halka_gunluk_ipucu(p_tarih date, p_tur text, p_sira integer) returns jsonb
language sql security definer set search_path = '' as $$ select halka.gunluk_ipucu(p_tarih, p_tur, p_sira) $$;

create function public.halka_gunluk_cevap(p_tarih date) returns jsonb
language sql security definer set search_path = '' as $$ select halka.gunluk_cevap(p_tarih) $$;

-- Takvim yükleme (halka-kelime scripts/upload_daily.ts), yalnız servis rolü. Satır: gunluk_bulmacalar sütunları.
create function public.halka_gunluk_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.gunluk_bulmacalar (tarih, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek)
  select x.tarih, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek
  from jsonb_to_recordset(p_satirlar) as x(tarih date, halkalar jsonb, cevaplar text[], cozum jsonb, anlamlar jsonb,
                                           kilit_sirasi integer[], ek jsonb)
  on conflict (tarih) do update set halkalar = excluded.halkalar, cevaplar = excluded.cevaplar, cozum = excluded.cozum,
    anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi, ek = excluded.ek;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.halka_gunluk_kontrol(date, integer[], boolean[]), public.halka_gunluk_ipucu(date, text, integer),
  public.halka_gunluk_cevap(date), public.halka_gunluk_yukle(jsonb) from public, anon, authenticated;
grant execute on function public.halka_gunluk_kontrol(date, integer[], boolean[]), public.halka_gunluk_ipucu(date, text, integer),
  public.halka_gunluk_cevap(date) to anon, authenticated;
grant execute on function public.halka_gunluk_yukle(jsonb) to service_role;
