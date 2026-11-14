-- HK-16: Usta Turnuvası cevapları sunucuda (Halka C1'in turnuvaya uygulanması). Kaynak: halka-kelime supabase/hk16_turnuva.sql; testleri tests/sql.test.ts. Yalnız halka.* ve public.halka_* + halka-turnuva-odul cron işi.
-- HK-16: Usta Turnuvası cevapları sunucuda (C1'in turnuvaya uygulanması; Halka docs/SUNUCU_GECISI.md Adım 6).
-- oyun-ortak göç isteği (20261118000400_halka_turnuva.sql olarak); 20261117000000, 20261117000100 ve 20261118000200'den sonra.
-- Testi: halka-kelime tests/sql.test.ts "turnuva_" (PGlite, ortak göçleriyle).
--
-- Günlükle aynı yapı: istemci dosyası (public/etkinlik/usta-*.json) yalnız halkaları ve başlangıcı taşır; doğru ışınlar,
-- ipuçları, cevap ve anlamlar buradan. Tablo yalnız servis rolüne; istemci public'teki sarmalayıcıları çağırır.
-- Okuma kuralı halka.gunluk_kontrol ve src/engine/model.ts (readRay, correctRays) ile aynı: üçü birlikte değişir.
-- gunluk_* işlevlerine dokunulmaz (canlıda); turnuva işlevleri aynı mantığın kopyası, sınır halka.gunluk_sinir (oturum zorunlu).
-- Pencere: takvimdeki basla–bitir (Cumartesi 00:00 – Pazar 23:59 İstanbul). Cevap turnuva bittikten 10 dk sonra açılır
-- (dogrula-halka geç penceresi kapanınca; halka.cevap_acik).

create table halka.turnuva_bulmacalar (
  kimlik text primary key check (kimlik ~ '^usta-\d{4}-\d{2}-\d{2}$'),
  basla date not null,
  bitir date not null check (basla <= bitir),
  halkalar jsonb not null,           -- string[][]: halkalar[r][i]
  cevaplar text[] not null,          -- cevaplar[k] = çözümde k. ışının kelimesi
  cozum jsonb,                       -- { rot: int[], flip: boolean[] }
  anlamlar jsonb,                    -- { kelime: anlam }
  kilit_sirasi integer[],
  ek jsonb,                          -- çözülünce gösterilen: { pairs } ya da { bonus }
  hedef integer,
  baslangic jsonb,                   -- dogrula-halka hamle listesini buradan yeniden oynatır
  kurallar jsonb
);
alter table halka.turnuva_bulmacalar enable row level security;
revoke all on halka.turnuva_bulmacalar from public, anon, authenticated;
grant all on halka.turnuva_bulmacalar to service_role;

-- Halka konumlarını okur, her ışın doğru mu söyler. Yalnız turnuva penceresinde; dışında null.
create function halka.turnuva_kontrol(p_kimlik text, p_rot integer[], p_flip boolean[]) returns jsonb
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

-- İpucu (yalnız pencerede). halka.gunluk_ipucu ile aynı türler; verilen her ipucu ortak.denemeler'e (anahtar turnuva:<kimlik>).
create function halka.turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p halka.turnuva_bulmacalar;
  u uuid := auth.uid();
  sira int[];
  r int;
  sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  select * into p from halka.turnuva_bulmacalar where kimlik = p_kimlik and ortak.bugun() between basla and bitir;
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
  if sonuc is not null then
    perform ortak.deneme_al('halka', u, 'turnuva:' || p_kimlik);
    update ortak.denemeler
       set durum = durum || jsonb_build_object('ipuclari', coalesce(durum -> 'ipuclari', '[]'::jsonb) || to_jsonb(p_tur)),
           guncelleme = now()
     where oyun_id = 'halka' and kullanici_id = u and anahtar = 'turnuva:' || p_kimlik and not bitti;
  end if;
  return sonuc;
end $$;

-- Bitmiş turnuvanın cevap paketi: bitişten (Pazar gece yarısı) 10 dk sonra; öncesi null.
create function halka.turnuva_cevap(p_kimlik text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sonuc jsonb;
begin
  perform halka.gunluk_sinir();
  select jsonb_strip_nulls(jsonb_build_object('cevaplar', to_jsonb(t.cevaplar), 'cozum', t.cozum, 'anlamlar', t.anlamlar,
                                              'kilit_sirasi', to_jsonb(t.kilit_sirasi), 'ek', t.ek))
    into sonuc from halka.turnuva_bulmacalar t where t.kimlik = p_kimlik and halka.cevap_acik(t.bitir, now());
  return sonuc;
end $$;

-- İlk %10'a altın rozet (LIVEOPS §2.4, HK-3): bitip geç penceresi kapanan son iki haftanın turnuvaları; tekrar çalışması
-- zararsız (ödül bir kez yazılır). Kimlik `sira:` önekli (istemci kendine yazamaz), istemci ortak.odullerim'den okur.
create function halka.turnuva_odul_ver() returns integer
language plpgsql security definer set search_path = '' as $$
declare t record; n int := 0;
begin
  for t in select kimlik from halka.turnuva_bulmacalar
           where halka.cevap_acik(bitir, now()) and bitir >= ortak.bugun() - 14 loop
    n := n + ortak.siralama_odulu_ver('halka', 'etkinlik', t.kimlik, 'sira:rozet-altin-' || t.kimlik, 0.1);
  end loop;
  return n;
end $$;

revoke execute on function halka.turnuva_kontrol(text, integer[], boolean[]), halka.turnuva_ipucu(text, text, integer),
  halka.turnuva_cevap(text), halka.turnuva_odul_ver() from public, anon, authenticated;

-- Pazartesi 00:15 İstanbul (Pazar 21:15 UTC): Pazar biten turnuvanın geç penceresi (10 dk) kapanmış olur.
select cron.schedule('halka-turnuva-odul', '15 21 * * 0', $$select halka.turnuva_odul_ver()$$);

-- ---------------------------------------------------------------- public sarmalayıcılar (PostgREST)

create function public.halka_turnuva_kontrol(p_kimlik text, p_rot integer[], p_flip boolean[]) returns jsonb
language sql security definer set search_path = '' as $$ select halka.turnuva_kontrol(p_kimlik, p_rot, p_flip) $$;

create function public.halka_turnuva_ipucu(p_kimlik text, p_tur text, p_sira integer) returns jsonb
language sql security definer set search_path = '' as $$ select halka.turnuva_ipucu(p_kimlik, p_tur, p_sira) $$;

create function public.halka_turnuva_cevap(p_kimlik text) returns jsonb
language sql security definer set search_path = '' as $$ select halka.turnuva_cevap(p_kimlik) $$;

-- Yükleme (halka-kelime scripts/upload_daily.ts), yalnız servis rolü. Satır: turnuva_bulmacalar sütunları.
create function public.halka_turnuva_yukle(p_satirlar jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into halka.turnuva_bulmacalar (kimlik, basla, bitir, halkalar, cevaplar, cozum, anlamlar, kilit_sirasi, ek, hedef, baslangic, kurallar)
  select x.kimlik, x.basla, x.bitir, x.halkalar, x.cevaplar, x.cozum, x.anlamlar, x.kilit_sirasi, x.ek, x.hedef, x.baslangic, x.kurallar
  from jsonb_to_recordset(p_satirlar) as x(kimlik text, basla date, bitir date, halkalar jsonb, cevaplar text[], cozum jsonb,
                                           anlamlar jsonb, kilit_sirasi integer[], ek jsonb, hedef integer, baslangic jsonb, kurallar jsonb)
  on conflict (kimlik) do update set basla = excluded.basla, bitir = excluded.bitir, halkalar = excluded.halkalar,
    cevaplar = excluded.cevaplar, cozum = excluded.cozum, anlamlar = excluded.anlamlar, kilit_sirasi = excluded.kilit_sirasi,
    ek = excluded.ek, hedef = excluded.hedef, baslangic = excluded.baslangic, kurallar = excluded.kurallar;
  get diagnostics n = row_count;
  return n;
end $$;

-- dogrula-halka (servis rolü) için: halka_dogrula_bulmaca ile aynı alanlar + basla, bitir; yoksa null.
create function public.halka_dogrula_turnuva(p_kimlik text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('halkalar', t.halkalar, 'cevaplar', to_jsonb(t.cevaplar), 'hedef', t.hedef,
                            'baslangic', t.baslangic, 'kurallar', t.kurallar, 'cozum', t.cozum, 'basla', t.basla, 'bitir', t.bitir)
  from halka.turnuva_bulmacalar t where t.kimlik = p_kimlik
$$;

revoke execute on function public.halka_turnuva_kontrol(text, integer[], boolean[]), public.halka_turnuva_ipucu(text, text, integer),
  public.halka_turnuva_cevap(text), public.halka_turnuva_yukle(jsonb), public.halka_dogrula_turnuva(text) from public, anon, authenticated;
grant execute on function public.halka_turnuva_kontrol(text, integer[], boolean[]), public.halka_turnuva_ipucu(text, text, integer),
  public.halka_turnuva_cevap(text) to anon, authenticated;
grant execute on function public.halka_turnuva_yukle(jsonb), public.halka_dogrula_turnuva(text) to service_role;
