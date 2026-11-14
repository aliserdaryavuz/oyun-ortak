-- HK-20 (Halka, 2026-11-14; kaynak halka-kelime supabase/hk20_tema_kilit.sql, dal inceleme-2, commit 176bffd).
-- Gizli tema adı yalnız sunucudan; uzak kilit ipucu istemcinin kilit kümesiyle (422 düzeltmesi). Yalnız halka.* ve public.halka_*.

-- HK-20 (ikinci inceleme: güvenlik DÜŞÜK, motor ORTA). oyun-ortak göç isteği; hk19 (20261120000500_halka_inceleme.sql)
-- ve 20261120000600'dan sonra. Yalnız halka.* ve public.halka_*. Testi: halka-kelime tests/sql.test.ts "hk20".
--
-- 1) Gizli Tema adı sunucuda (A1): public/puzzles/*.json ve public/etkinlik/usta-*.json'da `rules.themeHidden` iken
--    `theme.title` boş. Başlık halka.gunluk_bulmacalar.tema / halka.turnuva_bulmacalar.tema'da (yükleme işlevleri yazar,
--    scripts/upload_daily.ts gönderir). Veren yerler: 'tema' ipucu ({ tema }), kontrol çözülünce ('tema'), geçmiş günün ve
--    bitmiş turnuvanın cevap paketi ('tema'). Tema ipucu cezası denemede bir kez sayılır (istemci başlığı yeniden isteyebilir).
-- 2) Kilit ipucu istemcinin kilit kümesiyle (A2): yanıtı kaybolan kilit ipucunda sunucu halkayı durum.kilitli'ye yazmış,
--    istemci hamle listesine yazmamış oluyordu; sonraki ipucu başka çerçeve seçip gönderimde 422 "hamleler" çıkıyordu (ve
--    hesap devrinde durum.kilitli taşınmadığı için de). İpucu RPC'leri isteğe bağlı p_kilitli (istemcinin kilitli halkaları,
--    kurallar.locked dahil olabilir) alır; verilince çerçeve kurallar.locked ∪ p_kilitli ile seçilir (model.ts oynat ile
--    aynı küme), verilmezse eski kural (kurallar.locked ∪ durum.kilitli). Ceza sayımı sunucuda (durum.ipuclari) kalır;
--    p_kilitli yalnız hangi eşdeğer çerçevenin seçileceğini belirler, her kilit ipucu yine bir ceza.
--
-- İpucu sarmalayıcılarının imzası değişir (p_kilitli eklenir, varsayılan null): eski beş parametreli sürümler düşürülür
-- (PostgREST adlı çağrıda iki aday görmesin), yetkiler (anon, authenticated) yeniden verilir. Eski istemci p_kilitli
-- göndermeden aynen çalışır.

alter table halka.gunluk_bulmacalar add column if not exists tema text;
alter table halka.turnuva_bulmacalar add column if not exists tema text;

-- ---------------------------------------------------------------- yükleme: + tema (hk14 / hk16 gövdeleri)

create or replace function public.halka_gunluk_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.gunluk_bulmacalar (tarih, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek, hedef, baslangic, kurallar, tema)
  select x.tarih, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek, x.hedef, x.baslangic, x.kurallar, x.tema
  from jsonb_to_recordset(p_satirlar) as x(tarih date, halkalar jsonb, cevaplar text[], cozum jsonb, anlamlar jsonb,
                                           kilit_sirasi integer[], ek jsonb, hedef integer, baslangic jsonb, kurallar jsonb, tema text)
  on conflict (tarih) do update set halkalar = excluded.halkalar, cevaplar = excluded.cevaplar, cozum = excluded.cozum,
    anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi, ek = excluded.ek, hedef = excluded.hedef,
    baslangic = excluded.baslangic, kurallar = excluded.kurallar, tema = excluded.tema;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.halka_turnuva_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.turnuva_bulmacalar (kimlik, basla, bitir, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek, hedef, baslangic, kurallar, tema)
  select x.kimlik, x.basla, x.bitir, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek, x.hedef, x.baslangic, x.kurallar, x.tema
  from jsonb_to_recordset(p_satirlar) as x(kimlik text, basla date, bitir date, halkalar jsonb, cevaplar text[], cozum jsonb,
                                           anlamlar jsonb, kilit_sirasi integer[], ek jsonb, hedef integer, baslangic jsonb, kurallar jsonb, tema text)
  on conflict (kimlik) do update set basla = excluded.basla, bitir = excluded.bitir, halkalar = excluded.halkalar,
    cevaplar = excluded.cevaplar, cozum = excluded.cozum, anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi,
    ek = excluded.ek, hedef = excluded.hedef, baslangic = excluded.baslangic, kurallar = excluded.kurallar, tema = excluded.tema;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.halka_gunluk_yukle(jsonb), public.halka_turnuva_yukle(jsonb) from public, anon, authenticated;
grant execute on function public.halka_gunluk_yukle(jsonb), public.halka_turnuva_yukle(jsonb) to service_role;

-- ---------------------------------------------------------------- ipucu gövdesi: + p_kilitli, p_tema

drop function if exists halka.ipucu_ver(text, jsonb, text[], jsonb, jsonb, integer[], jsonb, text, integer, integer[], boolean[]);

create function halka.ipucu_ver(p_anahtar text, p_halkalar jsonb, p_cevaplar text[], p_cozum jsonb, p_anlamlar jsonb,
                                p_kilit_sirasi integer[], p_kurallar jsonb, p_tur text, p_sira integer,
                                p_rot integer[], p_flip boolean[], p_kilitli integer[], p_tema text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
  d ortak.denemeler;
  sira int[];
  r int;
  sonuc jsonb;
begin
  if p_tur = 'anlam' then
    sonuc := case when p_anlamlar ->> p_cevaplar[p_sira + 1] is not null
                  then jsonb_build_object('anlam', p_anlamlar ->> p_cevaplar[p_sira + 1]) end;
  elsif p_tur = 'kilit' then
    if p_cozum is null then return null; end if;
    if p_rot is not null or p_flip is not null then
      if not halka.durum_gecerli(jsonb_array_length(p_halkalar), p_rot, p_flip) then
        raise exception 'gecersiz_durum' using errcode = '22023';
      end if;
      d := ortak.deneme_al('halka', u, p_anahtar);
      sonuc := halka.kilit_sec(p_halkalar, p_cozum, p_kurallar,
        array(select jsonb_array_elements_text(coalesce(p_kurallar -> 'locked', '[]'))::int)
          || case when p_kilitli is not null then array(select x from unnest(p_kilitli) x where x is not null)
                  else array(select jsonb_array_elements_text(coalesce(d.durum -> 'kilitli', '[]'))::int) end,
        p_kilit_sirasi, p_rot, p_flip);
    else
      sira := coalesce(p_kilit_sirasi, '{}')
        || array(select g from generate_series(0, jsonb_array_length(p_halkalar) - 1) g
                 where g <> all (coalesce(p_kilit_sirasi, '{}')) order by g);
      r := sira[p_sira + 1];
      if r is not null then
        sonuc := jsonb_build_object('halka', r, 'rot', p_cozum -> 'rot' -> r, 'flip', p_cozum -> 'flip' -> r);
      end if;
    end if;
  elsif p_tur = 'tema' then
    sonuc := jsonb_strip_nulls(jsonb_build_object('tema', p_tema));
  else
    raise exception 'gecersiz_tur' using errcode = '22023';
  end if;
  if sonuc is not null and u is not null then
    d := ortak.deneme_al('halka', u, p_anahtar);
    -- Tema ipucu bir kez sayılır: başlığı kaybeden istemci yeniden isteyebilir.
    if not (p_tur = 'tema' and coalesce(d.durum -> 'ipuclari', '[]'::jsonb) ? 'tema') then
      update ortak.denemeler
         set durum = durum || jsonb_build_object('ipuclari', coalesce(durum -> 'ipuclari', '[]'::jsonb) || to_jsonb(p_tur))
                   || case when p_tur = 'kilit' and not coalesce(durum -> 'kilitli', '[]'::jsonb) @> jsonb_build_array(sonuc -> 'halka')
                           then jsonb_build_object('kilitli', coalesce(durum -> 'kilitli', '[]'::jsonb) || (sonuc -> 'halka'))
                           else '{}'::jsonb end,
             guncelleme = now()
       where oyun_id = 'halka' and kullanici_id = u and anahtar = p_anahtar and not bitti;
    end if;
  end if;
  return sonuc;
end $$;

revoke execute on function halka.ipucu_ver(text, jsonb, text[], jsonb, jsonb, integer[], jsonb, text, integer, integer[], boolean[], integer[], text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- ipucu RPC'leri: + p_kilitli

drop function if exists public.halka_gunluk_ipucu(date, text, integer, integer[], boolean[]);
drop function if exists halka.gunluk_ipucu(date, text, integer, integer[], boolean[]);
drop function if exists public.halka_turnuva_ipucu(text, text, integer, integer[], boolean[]);
drop function if exists halka.turnuva_ipucu(text, text, integer, integer[], boolean[]);

-- Yalnız bugün. Cevabı açan ipuçları (anlam, kilit) oturum ister (gunluk_sinir zaten ister).
create function halka.gunluk_ipucu(p_tarih date, p_tur text, p_sira integer, p_rot integer[] default null,
                                   p_flip boolean[] default null, p_kilitli integer[] default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p halka.gunluk_bulmacalar;
begin
  perform halka.gunluk_sinir();
  if p_tur in ('anlam', 'kilit') and auth.uid() is null then
    raise exception 'oturum_gerekli' using errcode = '28000';
  end if;
  if p_tarih is distinct from ortak.bugun() then return null; end if;
  select * into p from halka.gunluk_bulmacalar where tarih = p_tarih;
  if not found then return null; end if;
  return halka.ipucu_ver('gunluk:' || p_tarih, p.halkalar, p.cevaplar, p.cozum, p.anlamlar, p.kilit_sirasi, p.kurallar,
                         p_tur, p_sira, p_rot, p_flip, p_kilitli, p.tema);
end $$;

-- Yalnız turnuva penceresinde.
create function halka.turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer, p_rot integer[] default null,
                                    p_flip boolean[] default null, p_kilitli integer[] default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p halka.turnuva_bulmacalar;
begin
  perform halka.gunluk_sinir();
  select * into p from halka.turnuva_bulmacalar where kimlik = p_kimlik and ortak.bugun() between basla and bitir;
  if not found then return null; end if;
  return halka.ipucu_ver('turnuva:' || p_kimlik, p.halkalar, p.cevaplar, p.cozum, p.anlamlar, p.kilit_sirasi, p.kurallar,
                         p_tur, p_sira, p_rot, p_flip, p_kilitli, p.tema);
end $$;

create function public.halka_gunluk_ipucu(p_tarih date, p_tur text, p_sira integer, p_rot integer[] default null,
                                          p_flip boolean[] default null, p_kilitli integer[] default null) returns jsonb
language sql security definer set search_path = '' as $$ select halka.gunluk_ipucu(p_tarih, p_tur, p_sira, p_rot, p_flip, p_kilitli) $$;

create function public.halka_turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer, p_rot integer[] default null,
                                           p_flip boolean[] default null, p_kilitli integer[] default null) returns jsonb
language sql security definer set search_path = '' as $$ select halka.turnuva_ipucu(p_kimlik, p_tur, p_sira, p_rot, p_flip, p_kilitli) $$;

revoke execute on function halka.gunluk_ipucu(date, text, integer, integer[], boolean[], integer[]),
  halka.turnuva_ipucu(text, text, integer, integer[], boolean[], integer[]) from public, anon, authenticated;
revoke execute on function public.halka_gunluk_ipucu(date, text, integer, integer[], boolean[], integer[]),
  public.halka_turnuva_ipucu(text, text, integer, integer[], boolean[], integer[]) from public, anon, authenticated;
grant execute on function public.halka_gunluk_ipucu(date, text, integer, integer[], boolean[], integer[]),
  public.halka_turnuva_ipucu(text, text, integer, integer[], boolean[], integer[]) to anon, authenticated;

-- ---------------------------------------------------------------- kontrol: çözülünce + tema (hk19 gövdeleri)

create or replace function halka.gunluk_kontrol(p_tarih date, p_rot integer[], p_flip boolean[]) returns jsonb
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
  if not halka.durum_gecerli(h, p_rot, p_flip) then
    raise exception 'gecersiz_durum' using errcode = '22023';
  end if;
  perform halka.ilk_temas('gunluk:' || p_tarih);
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
         'cevaplar', to_jsonb(p.cevaplar), 'anlamlar', coalesce(p.anlamlar, '{}'::jsonb), 'ek', p.ek, 'tema', p.tema))
       else '{}'::jsonb end;
end $$;

create or replace function halka.turnuva_kontrol(p_kimlik text, p_rot integer[], p_flip boolean[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p halka.turnuva_bulmacalar;
  h int; n int; k int; r int; i int; idx int;
  w text;
  kalan text[];
  dogru boolean[] := '{}';
  cozuldu boolean;
begin
  perform halka.gunluk_sinir();
  select * into p from halka.turnuva_bulmacalar where kimlik = p_kimlik and ortak.bugun() between basla and bitir;
  if not found then return null; end if;
  h := jsonb_array_length(p.halkalar);
  n := jsonb_array_length(p.halkalar -> 0);
  if not halka.durum_gecerli(h, p_rot, p_flip) then
    raise exception 'gecersiz_durum' using errcode = '22023';
  end if;
  perform halka.ilk_temas('turnuva:' || p_kimlik);
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
         'cevaplar', to_jsonb(p.cevaplar), 'anlamlar', coalesce(p.anlamlar, '{}'::jsonb), 'ek', p.ek, 'tema', p.tema))
       else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------- cevap paketleri: + tema (hk18 / hk16 gövdeleri)

create or replace function halka.gunluk_cevap(p_tarih date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  if p_tarih is null or not halka.cevap_acik(p_tarih, now()) then return null; end if;
  if p_tarih < ortak.bugun() - 1
     and coalesce((select o.ayarlar #>> '{odeme,eski_gunler_ucretli}' from ortak.oyunlar o where o.id = 'halka'), '') = 'true'
     and not ortak.hakki_var('halka', 'paket_tam') then
    raise exception 'paket_gerekli' using errcode = '42501';
  end if;
  select jsonb_strip_nulls(jsonb_build_object('cevaplar', to_jsonb(g.cevaplar), 'cozum', g.cozum, 'anlamlar', g.anlamlar,
                                              'kilit_sirasi', to_jsonb(g.kilit_sirasi), 'ek', g.ek, 'tema', g.tema))
    into sonuc from halka.gunluk_bulmacalar g where g.tarih = p_tarih;
  return sonuc;
end $$;

create or replace function halka.turnuva_cevap(p_kimlik text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  select jsonb_strip_nulls(jsonb_build_object('cevaplar', to_jsonb(t.cevaplar), 'cozum', t.cozum, 'anlamlar', t.anlamlar,
                                              'kilit_sirasi', to_jsonb(t.kilit_sirasi), 'ek', t.ek, 'tema', t.tema))
    into sonuc from halka.turnuva_bulmacalar t where t.kimlik = p_kimlik and halka.cevap_acik(t.bitir, now());
  return sonuc;
end $$;
