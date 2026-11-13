-- HK-14 (güvenlik incelemesi, orta: sıralama bütünlüğü). oyun-ortak göç isteği; 20261118000000_halka_dogrula.sql'den sonra.
-- Testi: halka-kelime tests/sql.test.ts "gunluk_" (geç pencere) ve "dogrula-halka" (bulmaca okuma).
--
-- 1) Geç gönderim penceresi: dogrula-halka dünün çözümünü gece yarısından sonra 10 dakika daha kabul eder (kural.ts
--    GEC_DAKIKA). Dünün cevabı bu pencere kapanmadan verilmez: 23:59'da başlayıp 00:01'de cevabı alıp geç pencerede
--    gönderen sıralamaya giremesin. Sınır saf işlevde (halka.cevap_acik), an parametreyle: test saati taklit etmeden dener.
-- 2) Hamle sayısı sunucuda: dogrula-halka istemcinin hamle listesini başlangıçtan yeniden oynatır. Bunun için başlangıç
--    durumu ve kurallar (dişliler, ayna, kilitli halkalar) tabloya girer; yükleme betiği (scripts/upload_daily.ts) yazar,
--    halka_dogrula_bulmaca çözümle birlikte döndürür.

alter table halka.gunluk_bulmacalar add column if not exists baslangic jsonb, add column if not exists kurallar jsonb;

-- Gün p_tarih'in cevabı p_an anında açık mı: İstanbul gece yarısından 10 dakika sonra (bugün ve gelecek hiç).
create function halka.cevap_acik(p_tarih date, p_an timestamptz) returns boolean
language sql stable set search_path = '' as $$
  select p_tarih < ((p_an - interval '10 minutes') at time zone 'Europe/Istanbul')::date
$$;
revoke execute on function halka.cevap_acik(date, timestamptz) from public, anon, authenticated;

-- 20261117000000 gövdesi; sınır artık halka.cevap_acik.
create or replace function halka.gunluk_cevap(p_tarih date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  if p_tarih is null or not halka.cevap_acik(p_tarih, now()) then return null; end if;
  select jsonb_strip_nulls(jsonb_build_object('cevaplar', to_jsonb(g.cevaplar), 'cozum', g.cozum, 'anlamlar', g.anlamlar,
                                              'kilit_sirasi', to_jsonb(g.kilit_sirasi), 'ek', g.ek))
    into sonuc from halka.gunluk_bulmacalar g where g.tarih = p_tarih;
  return sonuc;
end $$;

create or replace function public.halka_gunluk_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.gunluk_bulmacalar (tarih, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek, hedef, baslangic, kurallar)
  select x.tarih, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek, x.hedef, x.baslangic, x.kurallar
  from jsonb_to_recordset(p_satirlar) as x(tarih date, halkalar jsonb, cevaplar text[], cozum jsonb, anlamlar jsonb,
                                           kilit_sirasi integer[], ek jsonb, hedef integer, baslangic jsonb, kurallar jsonb)
  on conflict (tarih) do update set halkalar = excluded.halkalar, cevaplar = excluded.cevaplar, cozum = excluded.cozum,
    anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi, ek = excluded.ek, hedef = excluded.hedef,
    baslangic = excluded.baslangic, kurallar = excluded.kurallar;
  get diagnostics n = row_count;
  return n;
end $$;

-- dogrula-halka (servis rolü) için: { halkalar, cevaplar, hedef, baslangic, kurallar, cozum } ya da null.
create or replace function public.halka_dogrula_bulmaca(p_tarih date) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('halkalar', g.halkalar, 'cevaplar', to_jsonb(g.cevaplar), 'hedef', g.hedef,
                            'baslangic', g.baslangic, 'kurallar', g.kurallar, 'cozum', g.cozum)
  from halka.gunluk_bulmacalar g where g.tarih = p_tarih
$$;

-- create or replace hakları korur; yine de açıkça (bu dosya tek başına okunduğunda da doğru).
revoke execute on function public.halka_gunluk_yukle(jsonb), public.halka_dogrula_bulmaca(date) from public, anon, authenticated;
grant execute on function public.halka_gunluk_yukle(jsonb), public.halka_dogrula_bulmaca(date) to service_role;
