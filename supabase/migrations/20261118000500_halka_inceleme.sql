-- HK-19: Halka bağımsız inceleme düzeltmeleri (kilit ipucu oyuncunun eşdeğer çerçevesinde, kontrol ilk temasta deneme açar, okuması doğru halka kilitlenmez). Kaynak: halka-kelime supabase/hk19_inceleme.sql. Yalnız halka.* ve public.halka_*.
-- HK-19 (bağımsız inceleme düzeltmeleri, motor ve güvenlik). oyun-ortak göç isteği; 20261118000400_halka_turnuva.sql'den
-- (ve hk18'den) sonra. Yalnız halka.* ve public.halka_*. Testi: halka-kelime tests/sql.test.ts "hk19".
--
-- 1) Kilit ipucu oyuncunun çerçevesinde (motor YÜKSEK/ORTA): ipucu işlevleri isteğe bağlı p_rot/p_flip alır (eski çağrı
--    p_rot olmadan aynen çalışır). Verilince halka.kilit_sec çözümün eşdeğerleri arasından kilitli halkalarla uyuşan,
--    onlar arasında oyuncunun durumuyla en çok halkası aynı okunanı seçer (eşitlikte asıl çözüm); kilit sırasında
--    kilitli ya da o çerçevede zaten doğru okunan (sütun okuması) halkayı atlar. Kural src/engine/model.ts kilitCercevesi
--    ve kilitHalkasi ile, eşdeğer dönüşüm solver/model equivalentStates ile birebir: ikisi birlikte değişir.
--    Kilitli halkalar = kurallar.locked ∪ bu denemede kilit ipucuyla verilenler (ortak.denemeler durum.kilitli).
-- 2) Süre sunucuyla ilk temastan (güvenlik): gunluk_kontrol / turnuva_kontrol ilk çağrıda deneme kaydını açar
--    (ortak.deneme_al). dogrula-halka gönderimi kayıt açmaz, yoksa 409 deneme_yok.
--
-- İpucu işlevlerinin imzası değişir (iki parametre eklenir, varsayılan null): eski üç parametreli sürümler düşürülür,
-- yoksa PostgREST adlı çağrıda iki aday görüp hata verirdi. Yetkiler yeniden verilir.

-- ---------------------------------------------------------------- yardımcılar

-- Halkanın bir konumdaki okuması: her ışına verdiği dilim (model.ts column ile aynı; ayraç \u0001).
create or replace function halka.sutun(p_halka jsonb, p_rot integer, p_flip boolean, p_n integer) returns text
language sql immutable set search_path = '' as $$
  select string_agg((p_halka ->> (case when p_flip then ((p_rot - k) % p_n + p_n) % p_n
                                       else ((k + p_rot) % p_n + p_n) % p_n end)) || chr(1), '' order by k)
  from generate_series(0, p_n - 1) k
$$;

-- Sıradaki kilit ipucu { halka, rot, flip } ya da null (hepsi kilitli ya da doğru). model.ts kilitHalkasi'nın kopyası.
create or replace function halka.kilit_sec(p_halkalar jsonb, p_cozum jsonb, p_kurallar jsonb, p_kilitli integer[],
                                           p_sira integer[], p_rot integer[], p_flip boolean[]) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  h int := jsonb_array_length(p_halkalar);
  n int := jsonb_array_length(p_halkalar -> 0);
  ayna boolean := coalesce((p_kurallar ->> 'flip')::boolean, false);
  kilitli int[] := coalesce(p_kilitli, '{}');
  oyuncu text[];
  m int; g int; r int; rr int; bf boolean;
  ayni int; uyar boolean; puan int; en int := -1;
  a_rot int[]; a_flip boolean[];
  t_rot int[]; t_flip boolean[];
begin
  oyuncu := array(select halka.sutun(p_halkalar -> x, p_rot[x + 1], p_flip[x + 1], n) from generate_series(0, h - 1) x order by x);
  -- equivalentStates: önce aynasız (m = 0), sonra ayna serbestse bütün halkalar ters (m = 1); her birinde g = 0..n-1.
  for m in 0 .. case when ayna then 1 else 0 end loop
    for g in 0 .. n - 1 loop
      a_rot := '{}'; a_flip := '{}'; ayni := 0; uyar := true;
      for r in 0 .. h - 1 loop
        bf := (p_cozum -> 'flip' ->> r)::boolean <> (m = 1);
        rr := (p_cozum -> 'rot' ->> r)::int;
        rr := ((case when bf then rr - g else rr + g end) % n + n) % n;
        a_rot := a_rot || rr;
        a_flip := a_flip || bf;
        if halka.sutun(p_halkalar -> r, rr, bf, n) = oyuncu[r + 1] then ayni := ayni + 1;
        elsif r = any (kilitli) then uyar := false;
        end if;
      end loop;
      puan := case when uyar then h + 1 else 0 end + ayni;
      if puan > en then en := puan; t_rot := a_rot; t_flip := a_flip; end if;
    end loop;
  end loop;
  foreach r in array coalesce(p_sira, '{}') || array(select x from generate_series(0, h - 1) x order by x) loop
    if not (r = any (kilitli)) and halka.sutun(p_halkalar -> r, t_rot[r + 1], t_flip[r + 1], n) <> oyuncu[r + 1] then
      return jsonb_build_object('halka', r, 'rot', t_rot[r + 1], 'flip', t_flip[r + 1]);
    end if;
  end loop;
  return null;
end $$;

-- Gelen durum halka sayısına uyuyor mu (gunluk_kontrol ile aynı denetim).
create or replace function halka.durum_gecerli(p_h integer, p_rot integer[], p_flip boolean[]) returns boolean
language sql immutable set search_path = '' as $$
  select array_ndims(p_rot) is not distinct from 1 and array_ndims(p_flip) is not distinct from 1
     and cardinality(p_rot) = p_h and cardinality(p_flip) = p_h
     and array_position(p_rot, null) is null and array_position(p_flip, null) is null
$$;

-- İpucu ortak gövdesi (günlük ve turnuva): sonuç ve deneme kaydı. p_rot null ise eski kural (kilit sırasında p_sira.
-- halka, asıl çözüm çerçevesi). Verilen her ipucu deneme kaydına; kilit ipucunun halkası durum.kilitli'ye.
create or replace function halka.ipucu_ver(p_anahtar text, p_halkalar jsonb, p_cevaplar text[], p_cozum jsonb, p_anlamlar jsonb,
                                           p_kilit_sirasi integer[], p_kurallar jsonb, p_tur text, p_sira integer,
                                           p_rot integer[], p_flip boolean[]) returns jsonb
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
          || array(select jsonb_array_elements_text(coalesce(d.durum -> 'kilitli', '[]'))::int),
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
    sonuc := '{}'::jsonb;
  else
    raise exception 'gecersiz_tur' using errcode = '22023';
  end if;
  if sonuc is not null and u is not null then
    perform ortak.deneme_al('halka', u, p_anahtar);
    update ortak.denemeler
       set durum = durum || jsonb_build_object('ipuclari', coalesce(durum -> 'ipuclari', '[]'::jsonb) || to_jsonb(p_tur))
                 || case when p_tur = 'kilit'
                         then jsonb_build_object('kilitli', coalesce(durum -> 'kilitli', '[]'::jsonb) || (sonuc -> 'halka'))
                         else '{}'::jsonb end,
           guncelleme = now()
     where oyun_id = 'halka' and kullanici_id = u and anahtar = p_anahtar and not bitti;
  end if;
  return sonuc;
end $$;

-- Deneme kaydı yoksa açar (ilk temas); varsa dokunmaz (her hamlede satır yazılmasın).
create or replace function halka.ilk_temas(p_anahtar text) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is not null and not exists (select 1 from ortak.denemeler where oyun_id = 'halka' and kullanici_id = u and anahtar = p_anahtar) then
    perform ortak.deneme_al('halka', u, p_anahtar);
  end if;
end $$;

revoke execute on function halka.sutun(jsonb, integer, boolean, integer),
  halka.kilit_sec(jsonb, jsonb, jsonb, integer[], integer[], integer[], boolean[]),
  halka.durum_gecerli(integer, integer[], boolean[]),
  halka.ipucu_ver(text, jsonb, text[], jsonb, jsonb, integer[], jsonb, text, integer, integer[], boolean[]),
  halka.ilk_temas(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- kontrol: ilk çağrı deneme kaydını açar

-- 20261117000000 gövdesi + ilk temas. create or replace yetkileri korur.
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
         'cevaplar', to_jsonb(p.cevaplar), 'anlamlar', coalesce(p.anlamlar, '{}'::jsonb), 'ek', p.ek))
       else '{}'::jsonb end;
end $$;

-- 20261118000400 gövdesi + ilk temas.
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
         'cevaplar', to_jsonb(p.cevaplar), 'anlamlar', coalesce(p.anlamlar, '{}'::jsonb), 'ek', p.ek))
       else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------- ipucu: isteğe bağlı oyuncu durumu

drop function if exists public.halka_gunluk_ipucu(date, text, integer);
drop function if exists halka.gunluk_ipucu(date, text, integer);
drop function if exists public.halka_turnuva_ipucu(text, text, integer);
drop function if exists halka.turnuva_ipucu(text, text, integer);

-- Yalnız bugün. Cevabı açan ipuçları (anlam, kilit) oturum ister (gunluk_sinir zaten ister).
create or replace function halka.gunluk_ipucu(p_tarih date, p_tur text, p_sira integer,
                                              p_rot integer[] default null, p_flip boolean[] default null) returns jsonb
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
                         p_tur, p_sira, p_rot, p_flip);
end $$;

-- Yalnız turnuva penceresinde.
create or replace function halka.turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer,
                                               p_rot integer[] default null, p_flip boolean[] default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p halka.turnuva_bulmacalar;
begin
  perform halka.gunluk_sinir();
  select * into p from halka.turnuva_bulmacalar where kimlik = p_kimlik and ortak.bugun() between basla and bitir;
  if not found then return null; end if;
  return halka.ipucu_ver('turnuva:' || p_kimlik, p.halkalar, p.cevaplar, p.cozum, p.anlamlar, p.kilit_sirasi, p.kurallar,
                         p_tur, p_sira, p_rot, p_flip);
end $$;

create or replace function public.halka_gunluk_ipucu(p_tarih date, p_tur text, p_sira integer,
                                                     p_rot integer[] default null, p_flip boolean[] default null) returns jsonb
language sql security definer set search_path = '' as $$ select halka.gunluk_ipucu(p_tarih, p_tur, p_sira, p_rot, p_flip) $$;

create or replace function public.halka_turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer,
                                                      p_rot integer[] default null, p_flip boolean[] default null) returns jsonb
language sql security definer set search_path = '' as $$ select halka.turnuva_ipucu(p_kimlik, p_tur, p_sira, p_rot, p_flip) $$;

revoke execute on function halka.gunluk_ipucu(date, text, integer, integer[], boolean[]),
  halka.turnuva_ipucu(text, text, integer, integer[], boolean[]) from public, anon, authenticated;
revoke execute on function public.halka_gunluk_ipucu(date, text, integer, integer[], boolean[]),
  public.halka_turnuva_ipucu(text, text, integer, integer[], boolean[]) from public, anon, authenticated;
grant execute on function public.halka_gunluk_ipucu(date, text, integer, integer[], boolean[]),
  public.halka_turnuva_ipucu(text, text, integer, integer[], boolean[]) to anon, authenticated;
