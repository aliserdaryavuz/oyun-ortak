-- HK-13: dogrula-halka için hedef sütunu ve bulmaca okuma (yalnız servis rolü). Kaynak: halka-kelime supabase/dogrula_halka.sql (1–33).
-- oyun-ortak göç isteği (Halka SUNUCU_GECISI Adım 4; oyun-ortak'a göç olarak eklenir, ör. 20261118000000_halka_dogrula.sql).
-- Testi: tests/sql.test.ts "dogrula-halka" (PGlite, ortak göçleriyle birlikte).
-- 1) dogrula-halka günün halkalarını ve cevaplarını okur (halka şeması API'ye kapalı: yalnız servis rolüne açık sarmalayıcı).
-- 2) Hedef hamle (par) sunucuda: lig puanının "hedefte" kısmı. Yükleme betiği (scripts/upload_daily.ts) `hedef` yazar.
-- 3) Hesap devri ipuçlarını kaybetmesin: misafirken alınan ipucu ve başlangıç, VAR OLAN hesaba girişte de taşınır.
--    (v0.1 devri denemeleri yalnız yeni açılan hesaba taşıyordu: misafir ipucu alıp eski hesabına girerse "ipucusuz" skor yazardı.)

alter table halka.gunluk_bulmacalar add column if not exists hedef integer;

create or replace function public.halka_gunluk_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.gunluk_bulmacalar (tarih, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek, hedef)
  select x.tarih, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek, x.hedef
  from jsonb_to_recordset(p_satirlar) as x(tarih date, halkalar jsonb, cevaplar text[], cozum jsonb, anlamlar jsonb,
                                           kilit_sirasi integer[], ek jsonb, hedef integer)
  on conflict (tarih) do update set halkalar = excluded.halkalar, cevaplar = excluded.cevaplar, cozum = excluded.cozum,
    anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi, ek = excluded.ek, hedef = excluded.hedef;
  get diagnostics n = row_count;
  return n;
end $$;

-- dogrula-halka (servis rolü) için: { halkalar, cevaplar, hedef } ya da null.
create function public.halka_dogrula_bulmaca(p_tarih date) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('halkalar', g.halkalar, 'cevaplar', to_jsonb(g.cevaplar), 'hedef', g.hedef)
  from halka.gunluk_bulmacalar g where g.tarih = p_tarih
$$;

revoke execute on function public.halka_gunluk_yukle(jsonb), public.halka_dogrula_bulmaca(date) from public, anon, authenticated;
grant execute on function public.halka_gunluk_yukle(jsonb), public.halka_dogrula_bulmaca(date) to service_role;

