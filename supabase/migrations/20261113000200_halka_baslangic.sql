-- Halka Kelime başlangıç şeması: halka-kelime/supabase/schema.sql + push.sql (12 Kasım 2026) olduğu gibi.
-- Halka istemcisi değişmeden oyun-canli'ya bağlansın diye `public` şemasında, `hk_` adlarıyla durur.
-- Kalıcı yeri `ortak` + `halka` şemaları; geçiş adımları docs/GECIS.md. Tek değişiklik dosyanın sonunda:
-- hk_delete_account, ortak projede başka oyunlardaki hesabı silmesin.

-- Halka Kelime: günlük oyun girişi ve süre sıralaması.
-- Supabase → SQL Editor'de bir kez çalıştır (tekrar çalıştırmak güvenli).
--
-- Hile önlemi: süre sunucuda ölçülür (bulmacayı ilk açış → çözüm gönderimi), gönderilen halka
-- konumları sunucuda okunup cevaplarla karşılaştırılır, ipuçları sunucuda sayılır (hk_hint_daily).
-- Işın başına 2 sn'den hızlı çözüm reddedilir.
-- ponytail: halkalar istemcide olduğu için çözücü betikle hile tümüyle engellenemez; alt sınır yalnızca
-- anında gönderimi keser. Gerekirse şüpheli süreler için bildirme/elle inceleme eklenir.
-- Sıralama süresi = süre + 30 sn × ipucu. Sıralamaya yalnızca kendi gününde (İstanbul saati) ilk çözüm girer.

create table if not exists public.hk_profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 2 and 20),
  created_at timestamptz not null default now()
);

create table if not exists public.hk_daily_puzzles (
  date date primary key,
  rings jsonb not null,          -- string[][]: rings[r][i]
  answers text[] not null
);

create table if not exists public.hk_daily_starts (
  user_id uuid not null references auth.users on delete cascade,
  date date not null references public.hk_daily_puzzles on delete cascade,
  started_at timestamptz not null default now(),
  hints int not null default 0,
  primary key (user_id, date)
);
alter table public.hk_daily_starts add column if not exists hints int not null default 0;

create table if not exists public.hk_daily_scores (
  user_id uuid not null references auth.users on delete cascade,
  date date not null references public.hk_daily_puzzles on delete cascade,
  seconds int not null check (seconds >= 0),
  hints int not null check (hints between 0 and 50),
  moves int not null check (moves between 0 and 10000),
  rank_seconds int generated always as (seconds + 30 * hints) stored,
  created_at timestamptz not null default now(),
  primary key (user_id, date)
);
create index if not exists hk_daily_scores_rank on public.hk_daily_scores (date, rank_seconds, created_at);

alter table public.hk_profiles enable row level security;
alter table public.hk_daily_puzzles enable row level security;
alter table public.hk_daily_starts enable row level security;
alter table public.hk_daily_scores enable row level security;

-- Adlar ve skorlar herkese açık (sıralama); yazma yalnızca kendi profilin, skor yalnızca fonksiyonla.
drop policy if exists "profil oku" on public.hk_profiles;
create policy "profil oku" on public.hk_profiles for select using (true);
drop policy if exists "profil yaz" on public.hk_profiles;
create policy "profil yaz" on public.hk_profiles for insert with check (auth.uid() = id);
drop policy if exists "profil güncelle" on public.hk_profiles;
create policy "profil güncelle" on public.hk_profiles for update using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "skor oku" on public.hk_daily_scores;
create policy "skor oku" on public.hk_daily_scores for select using (true);
-- hk_daily_puzzles ve hk_daily_starts için politika yok: yalnızca aşağıdaki fonksiyonlar erişir.

create or replace function public.hk_istanbul_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Istanbul')::date $$;

-- Günün bulmacasını açınca çağrılır; ilk çağrının zamanı saklanır.
create or replace function public.hk_start_daily(d date) returns timestamptz
language plpgsql security definer set search_path = public, pg_temp as $$
declare t timestamptz;
begin
  if auth.uid() is null then raise exception 'giriş gerekli'; end if;
  if d <> hk_istanbul_today() or not exists (select 1 from hk_daily_puzzles where date = d) then return null; end if;
  insert into hk_daily_starts (user_id, date) values (auth.uid(), d) on conflict do nothing;
  select started_at into t from hk_daily_starts where user_id = auth.uid() and date = d;
  return t;
end $$;

-- İpucu kullanılınca çağrılır; sayaç sunucuda tutulur (istemcinin bildirdiğinden az sayılmaz).
create or replace function public.hk_hint_daily(d date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare c int;
begin
  if auth.uid() is null then raise exception 'giriş gerekli'; end if;
  update hk_daily_starts set hints = hints + 1
   where user_id = auth.uid() and date = d
     and not exists (select 1 from hk_daily_scores where user_id = auth.uid() and date = d)
  returning hints into c;
  return c;
end $$;

-- Çözümü gönderir; doğruysa skoru yazar ve sıralamadaki yeri döner (yanlışsa null).
create or replace function public.hk_submit_daily(d date, rot int[], flip boolean[], moves int, hints int) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p hk_daily_puzzles;
  st timestamptz;
  used int;
  secs int;
  n int; r int; k int; idx int; w text;
  words text[] := '{}';
  place int;
begin
  if auth.uid() is null then raise exception 'giriş gerekli'; end if;
  if d <> hk_istanbul_today() then return null; end if;
  select * into p from hk_daily_puzzles where date = d;
  select started_at, hk_daily_starts.hints into st, used from hk_daily_starts where user_id = auth.uid() and date = d;
  if p is null or st is null then return null; end if;
  n := jsonb_array_length(p.rings -> 0);
  if array_length(rot, 1) <> jsonb_array_length(p.rings) or array_length(flip, 1) <> jsonb_array_length(p.rings) then return null; end if;
  -- Işın k, halka r'den: çevrilmemiş tokens[(k + rot) mod N], ters çevrilmiş tokens[(rot − k) mod N] (src/engine/model.ts ile aynı)
  for k in 0 .. n - 1 loop
    w := '';
    for r in 0 .. jsonb_array_length(p.rings) - 1 loop
      idx := case when flip[r + 1] then ((rot[r + 1] - k) % n + n) % n else ((k + rot[r + 1]) % n + n) % n end;
      w := w || (p.rings -> r ->> idx);
    end loop;
    words := words || w;
  end loop;
  if (select array_agg(x order by x) from unnest(words) x) is distinct from (select array_agg(x order by x) from unnest(p.answers) x) then
    return null;
  end if;
  secs := greatest(0, extract(epoch from now() - st))::int;
  if secs < 2 * n then return null; end if;   -- insan için imkânsız hız
  insert into hk_daily_scores (user_id, date, seconds, hints, moves)
  values (auth.uid(), d, secs, least(50, greatest(hints, used)), moves)
  on conflict do nothing;
  select count(*) + 1 into place from hk_daily_scores s, hk_daily_scores me
   where me.user_id = auth.uid() and me.date = d and s.date = d
     and (s.rank_seconds, s.created_at) < (me.rank_seconds, me.created_at);
  return place;
end $$;

grant execute on function public.hk_start_daily(date) to authenticated;
grant execute on function public.hk_hint_daily(date) to authenticated;
grant execute on function public.hk_submit_daily(date, int[], boolean[], int, int) to authenticated;

create or replace view public.hk_leaderboard with (security_invoker = true) as
-- Adsız oyuncu da sırada sayılır (hk_submit_daily'nin döndürdüğü yerle aynı olsun); adı "Oyuncu" görünür.
select s.date, s.user_id, coalesce(p.name, 'Oyuncu') as name, s.seconds, s.hints, s.moves, s.rank_seconds,
       rank() over (partition by s.date order by s.rank_seconds, s.created_at) as place
from public.hk_daily_scores s left join public.hk_profiles p on p.id = s.user_id;

-- ---------- Oyun testi verisi (Faz 3: zorluk kalibrasyonu) ----------
-- Her bulmaca için bir kez "çözdü" ve en çok bir kez "bıraktı" kaydı. Kimlik yok: rastgele cihaz kimliği.
-- İstemci yalnızca yazar; okuma panelden (SQL Editor) yapılır.
create table if not exists public.hk_plays (
  id bigint generated always as identity primary key,
  device text not null check (char_length(device) between 8 and 64),
  mode text not null check (mode in ('daily', 'level')),
  puzzle text not null check (char_length(puzzle) <= 32),
  tier text check (char_length(tier) <= 16),
  kind text check (char_length(kind) <= 16),
  rings int, rays int, score int, par int,
  seconds int not null check (seconds between 0 and 86400),
  moves int not null check (moves between 0 and 10000),
  hints int not null check (hints between 0 and 50),
  solved boolean not null,
  created_at timestamptz not null default now()
);
alter table public.hk_plays enable row level security;
drop policy if exists "oyun kaydı yaz" on public.hk_plays;
create policy "oyun kaydı yaz" on public.hk_plays for insert to anon, authenticated with check (true);

-- ---------- Seviye ilerlemesi (giriş yapanlarda cihazlar arası) ----------
create table if not exists public.hk_level_progress (
  user_id uuid not null references auth.users on delete cascade,
  key text not null check (char_length(key) <= 16),
  moves int not null default 0,
  hints int not null default 0,
  seconds int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.hk_level_progress enable row level security;
drop policy if exists "ilerleme kendi" on public.hk_level_progress;
create policy "ilerleme kendi" on public.hk_level_progress for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- Hesap silme (KVKK, Google Play) ----------
-- Halka Kelime verisinin tamamı silinir. Proje başka bir uygulamayla paylaşıldığı için giriş kimliği
-- yalnızca kullanıcının diğer uygulamanın tablolarında (public, hk_ öneksiz, user_id sütunlu) verisi yoksa silinir.
create or replace function public.hk_delete_account() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  t record;
  other boolean := false;
begin
  if uid is null then raise exception 'giriş gerekli'; end if;
  delete from hk_daily_scores where user_id = uid;
  delete from hk_daily_starts where user_id = uid;
  delete from hk_level_progress where user_id = uid;
  delete from hk_profiles where id = uid;
  delete from hk_entitlements where user_id = uid; -- Play satın alması Google hesabında kalır, geri yüklemeyle döner
  for t in select distinct c.table_name from information_schema.columns c
           where c.table_schema = 'public' and c.column_name = 'user_id' and c.table_name not like 'hk\_%' loop
    execute format('select exists (select 1 from public.%I where user_id = $1)', t.table_name) into other using uid;
    exit when other;
  end loop;
  if not other then delete from auth.users where id = uid; end if;
end $$;
grant execute on function public.hk_delete_account() to authenticated;

-- ---------- Takvim yükleme (scripts/upload_daily.ts) ----------
-- Panelden yapıştırmadan günlük bulmacaları yüklemek için. Belirteç yalnızca yerelde (.env.local);
-- veritabanında özeti (sha256) durur. Biçim: satır başına "tarih;halka|halka;cevap,cevap", halka "dilim/dilim".
create table if not exists public.hk_admin (name text primary key, token_hash text not null);
alter table public.hk_admin enable row level security;
create or replace function public.hk_load_puzzles(token text, data text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not exists (select 1 from hk_admin where name = 'yukleme' and token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')) then
    raise exception 'yetkisiz';
  end if;
  insert into hk_daily_puzzles (date, rings, answers)
  select split_part(l, ';', 1)::date,
    (select jsonb_agg(to_jsonb(string_to_array(rg, '/')) order by o) from unnest(string_to_array(split_part(l, ';', 2), '|')) with ordinality as x(rg, o)),
    string_to_array(split_part(l, ';', 3), ',')
  from unnest(string_to_array(data, E'\n')) as l
  where l <> ''
  on conflict (date) do update set rings = excluded.rings, answers = excluded.answers;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.hk_load_puzzles(text, text) to anon, authenticated;

-- ---------- İstemci hata kaydı ----------
-- Oyuncunun cihazında kod hata verirse haberimiz olsun. Kimliksiz, yalnızca yazma; okuma panelden.
create table if not exists public.hk_errors (
  id bigint generated always as identity primary key,
  device text not null check (char_length(device) between 8 and 64),
  message text not null check (char_length(message) <= 500),
  stack text check (char_length(stack) <= 4000),
  url text check (char_length(url) <= 300),
  agent text check (char_length(agent) <= 300),
  created_at timestamptz not null default now()
);
alter table public.hk_errors enable row level security;
drop policy if exists "hata yaz" on public.hk_errors;
create policy "hata yaz" on public.hk_errors for insert to anon, authenticated with check (true);

-- ---------- Güvenlik sıkılaştırması (supabase/guvenlik.sql ile aynı) ----------
-- 1) Fonksiyonlar varsayılan olarak herkese (PUBLIC, anon) açık oluşur. Yalnızca gerekene ver.
revoke execute on function public.hk_istanbul_today() from public, anon, authenticated;
revoke execute on function public.hk_start_daily(date) from public, anon;
revoke execute on function public.hk_hint_daily(date) from public, anon;
revoke execute on function public.hk_submit_daily(date, int[], boolean[], int, int) from public, anon;
revoke execute on function public.hk_delete_account() from public, anon;
grant execute on function public.hk_start_daily(date) to authenticated;
grant execute on function public.hk_hint_daily(date) to authenticated;
grant execute on function public.hk_submit_daily(date, int[], boolean[], int, int) to authenticated;
grant execute on function public.hk_delete_account() to authenticated;
-- hk_load_puzzles belirteçle korunur, yükleme betiği anon anahtarla çağırır: anon kalır.
revoke execute on function public.hk_load_puzzles(text, text) from public;
grant execute on function public.hk_load_puzzles(text, text) to anon, authenticated;

-- 2) Kimliksiz yazılan tablolar (oyun kaydı, hata kaydı) sel ile doldurulamasın.
--    Cihaz başına saatte 120, toplamda dakikada 600 satır; toplam boyut tavanı ve saklama süresi. Fazlası sessizce atılır.
create index if not exists hk_plays_device_time on public.hk_plays (device, created_at);
create index if not exists hk_plays_time on public.hk_plays (created_at);
create index if not exists hk_errors_device_time on public.hk_errors (device, created_at);
create index if not exists hk_errors_time on public.hk_errors (created_at);

create or replace function public.hk_throttle() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare per_device int; total int; keep interval; cap int;
begin
  new.created_at := now(); -- zaman sunucudan: istemci eski tarih yazıp hız sınırını atlatamaz
  -- Önce hız sınırı: reddedilen ekleme hiçbir temizliği tetikleyemez.
  execute format('select count(*) from public.%I where device = $1 and created_at > now() - interval ''1 hour''', tg_table_name)
    into per_device using new.device;
  if per_device >= 120 then return null; end if;
  execute format('select count(*) from public.%I where created_at > now() - interval ''1 minute''', tg_table_name) into total;
  if total >= 600 then return null; end if;
  -- Saklama ve boyut tavanı (veritabanı arac-karnesi ile paylaşılıyor, ücretsiz katman 500 MB). Kabul edilen eklemelerin
  -- %1'inde: süresi geçenler silinir (hata 30 gün, oyun 1 yıl); en yeni `cap` satırın gerisi atılır (hata 20 bin,
  -- oyun 200 bin). Gerçek sıraya bakar: tablo tavanın altındaysa hiçbir şey silinmez. Yeni kayıt reddedilmez.
  if random() < 0.01 then
    keep := case tg_table_name when 'hk_errors' then interval '30 days' else interval '365 days' end;
    cap := case tg_table_name when 'hk_errors' then 20000 else 200000 end;
    execute format('delete from public.%I where created_at < now() - $1', tg_table_name) using keep;
    execute format('delete from public.%I where id <= (select id from public.%I order by id desc offset $1 limit 1)', tg_table_name, tg_table_name) using cap;
  end if;
  return new;
end $$;
revoke execute on function public.hk_throttle() from public, anon, authenticated;

drop trigger if exists hk_plays_throttle on public.hk_plays;
create trigger hk_plays_throttle before insert on public.hk_plays for each row execute function public.hk_throttle();
drop trigger if exists hk_errors_throttle on public.hk_errors;
create trigger hk_errors_throttle before insert on public.hk_errors for each row execute function public.hk_throttle();

-- 3) Sıralamada görünen ad: harf, rakam, boşluk ve . _ - dışında karakter yok (görünmez/kontrol karakteri,
--    sahte yön işaretleri, HTML). Eski satırlar bozulmasın diye NOT VALID: yalnızca yeni yazımlar denetlenir.
alter table public.hk_profiles drop constraint if exists hk_profiles_name_chars;
alter table public.hk_profiles add constraint hk_profiles_name_chars
  check (name ~ '^[[:alnum:]._-]([[:alnum:] ._-]*[[:alnum:]._-])?$') not valid;

-- 4) Seviye ilerlemesi: anahtar "<zorluk>-<seviye>" biçiminde; kullanıcı sınırsız satır yazamasın.
alter table public.hk_level_progress drop constraint if exists hk_level_progress_key_format;
alter table public.hk_level_progress add constraint hk_level_progress_key_format
  check (key ~ '^[1-8]-[0-9]{1,3}$' and moves between 0 and 100000 and hints between 0 and 1000 and seconds between 0 and 10000000) not valid;

-- 6) Sıralama adı: yalnız Latin + Türkçe harf, rakam, tek boşluk ve . _ - (Kiril/Yunan benzer harflerle
--    "Ali" taklidi olmasın); benzersizlik Türkçe katlanmış biçimde (İ→i, I→ı, sonra küçük harf).
alter table public.hk_profiles drop constraint if exists hk_profiles_name_chars;
alter table public.hk_profiles add constraint hk_profiles_name_chars
  check (name ~ '^[A-Za-zÇĞİÖŞÜçğıöşü0-9._-]([A-Za-zÇĞİÖŞÜçğıöşü0-9 ._-]*[A-Za-zÇĞİÖŞÜçğıöşü0-9._-])?$' and name !~ '  ') not valid;
-- Benzersizlik anahtarı: ekranda benzer görünen adlar çakışsın. I/İ/ı/i tek harf, Türkçe harfler Latin
-- karşılığına (Ş→s, Ç→c, Ğ→g, Ö→o, Ü→u), boşluk ve . _ - yok sayılır: "Işık" = "Isik" = "is_ik".
create or replace function public.hk_name_key(n text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select regexp_replace(lower(translate(n, 'İIıŞşÇçĞğÖöÜü', 'iiissccggoouu')), '[ ._-]', '', 'g')
$$;
drop index if exists public.hk_profiles_name_unique;
create unique index hk_profiles_name_unique on public.hk_profiles (public.hk_name_key(name));

-- ---------- Ölçüm (ORTAK MODÜL; başka oyunda önek `hk_` değişir; supabase/olcum.sql ile aynı) ----------
-- Açılış: cihaz başına günde bir satır (istemci günde bir kez yollar; ikincisi benzersizlikte düşer).
-- Kaynak: web | pwa (ana ekran) | twa (Play uygulaması) | ios. Kimliksiz; cihaz kimliği hk_plays'teki ile aynı.
create table if not exists public.hk_opens (
  id bigint generated always as identity primary key,
  device text not null check (char_length(device) between 8 and 64),
  source text not null check (source in ('web', 'pwa', 'twa', 'ios')),
  -- ponytail: gün istemciye kapalı (sütun yetkisi aşağıda); sahte cihazla şişirilebilir, kimliksiz veride kabul, hız sınırı hk_throttle'da.
  day date not null default (now() at time zone 'Europe/Istanbul')::date,
  created_at timestamptz not null default now(),
  unique (device, day)
);
alter table public.hk_opens enable row level security;
drop policy if exists "açılış yaz" on public.hk_opens;
create policy "açılış yaz" on public.hk_opens for insert to anon, authenticated with check (true);
-- İstemci yalnız cihaz ve kaynağı yazar; gün ve zaman sunucudan (geçmiş güne açılış yazıp D1/D7 bozulamaz).
revoke insert on public.hk_opens from anon, authenticated;
grant insert (device, source) on public.hk_opens to anon, authenticated;
create index if not exists hk_opens_device_time on public.hk_opens (device, created_at);
create index if not exists hk_opens_time on public.hk_opens (created_at);
drop trigger if exists hk_opens_throttle on public.hk_opens;
create trigger hk_opens_throttle before insert on public.hk_opens for each row execute function public.hk_throttle();

-- Tutunma: ilk açılış gününe göre kohort; D1/D7/D30 = o gün yeniden açan yüzdesi (gün henüz gelmediyse boş).
-- Testçi cihazları (t-…) dışarıda. Yalnız panelden (SQL Editor) okunur; istemciye kapalı.
create or replace view public.hk_retention with (security_invoker = true) as
with ilk as (
  select device, min(day) as d0, (array_agg(source order by day))[1] as kaynak
  from public.hk_opens where device not like 't-%' group by device
)
select i.d0 as kohort, i.kaynak, count(*) as yeni,
  case when i.d0 + 1 <= (now() at time zone 'Europe/Istanbul')::date then
    round(100.0 * count(*) filter (where exists (select 1 from public.hk_opens o where o.device = i.device and o.day = i.d0 + 1)) / count(*), 1) end as d1,
  case when i.d0 + 7 <= (now() at time zone 'Europe/Istanbul')::date then
    round(100.0 * count(*) filter (where exists (select 1 from public.hk_opens o where o.device = i.device and o.day = i.d0 + 7)) / count(*), 1) end as d7,
  case when i.d0 + 30 <= (now() at time zone 'Europe/Istanbul')::date then
    round(100.0 * count(*) filter (where exists (select 1 from public.hk_opens o where o.device = i.device and o.day = i.d0 + 30)) / count(*), 1) end as d30
from ilk i group by i.d0, i.kaynak;

-- Zorluk hunisi: her zorlukta oynayan ve çözen cihaz, bırakma, medyan süre. Zorluk 5'e (Zor) varan = ücretsiz sınıra ulaşan.
create or replace view public.hk_funnel with (security_invoker = true) as
select split_part(puzzle, '-', 1) as zorluk, min(tier) as ad,
  count(distinct device) as oynayan,
  count(distinct device) filter (where solved) as cozen,
  round(100.0 * count(*) filter (where not solved) / count(*), 1) as birakma_yuzde,
  percentile_cont(0.5) within group (order by seconds) filter (where solved) as medyan_sn
from public.hk_plays
where mode = 'level' and device not like 't-%'
group by 1;

revoke all on public.hk_retention, public.hk_funnel from public, anon, authenticated;

-- ---------- Satın alınan haklar (ORTAK MODÜL; supabase/haklar.sql ile aynı) ----------
-- Hak hesaba yazılır; web ve uygulama aynı hesapla açar. Yalnız sunucu yazar (Play/App Store doğrulayan Edge Function,
-- service_role); istemci yalnız kendi satırını okur. Ürün: 'paket_tam' (Zor–Efsane + günlük arşivi).
create table if not exists public.hk_entitlements (
  user_id uuid not null references auth.users (id) on delete cascade,
  product text not null check (product in ('paket_tam')),
  source text not null check (source in ('play', 'appstore', 'manual')),
  status text not null default 'active' check (status in ('active', 'refunded', 'revoked')),
  purchase_token text unique check (char_length(purchase_token) <= 4096),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, product)
);
alter table public.hk_entitlements enable row level security;
drop policy if exists "kendi hakkını oku" on public.hk_entitlements;
create policy "kendi hakkını oku" on public.hk_entitlements for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.hk_entitlements from public, anon, authenticated;

-- ---------- push.sql ----------
-- Günlük hatırlatma (Web Push): Android uygulaması (TWA), web ve ana ekrana eklenen iPhone uygulaması.
-- SQL Editor'de bir kez çalıştır; tekrar çalıştırmak güvenli. Gönderici: supabase/functions/hk-push (saat başı).
-- Kimlik yok: abonelik tarayıcının verdiği uç adres + şifreleme anahtarlarıdır; kişisel veri değildir.

create table if not exists public.hk_push (
  endpoint text primary key check (char_length(endpoint) between 20 and 600 and endpoint like 'https://%'),
  p256dh text not null check (char_length(p256dh) between 40 and 200),
  auth text not null check (char_length(auth) between 10 and 100),
  hour int not null check (hour between 0 and 23),   -- İstanbul saati
  last_sent date,
  created_at timestamptz not null default now()
);
create index if not exists hk_push_hour on public.hk_push (hour);

-- Yalnızca bilinen bildirim servisleri: gönderici rastgele adreslere istek atmaya alet edilemesin (SSRF),
-- tablo sahte satırlarla doldurulamasın. Google (Chrome/Android), Mozilla, Apple, Microsoft.
create or replace function public.hk_push_host_ok(e text) returns boolean language sql immutable as $$
  select e ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/'
$$;
alter table public.hk_push drop constraint if exists hk_push_host;
alter table public.hk_push add constraint hk_push_host check (public.hk_push_host_ok(endpoint));
alter table public.hk_push enable row level security;
-- Politika yok: yalnızca aşağıdaki işlevler ve gönderici (service role) erişir.

create or replace function public.hk_push_save(p_endpoint text, p_p256dh text, p_auth text, p_hour int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Tavan: tablo sahte aboneliklerle sınırsız büyüyemesin (veritabanı arac-karnesi ile paylaşılıyor).
  if not hk_push_host_ok(p_endpoint) then raise exception 'bilinmeyen bildirim servisi'; end if;
  if (select count(*) from hk_push) >= 100000 and not exists (select 1 from hk_push where endpoint = p_endpoint) then
    raise exception 'abonelik sınırı dolu'; -- istemci kaydın olmadığını bilsin
  end if;
  insert into hk_push (endpoint, p256dh, auth, hour) values (p_endpoint, p_p256dh, p_auth, p_hour)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, hour = excluded.hour;
end $$;

create or replace function public.hk_push_remove(p_endpoint text) returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from hk_push where endpoint = p_endpoint;
$$;

-- Gönderici bu saatin abonelerini tek seferde "alır" (bugün işaretlenir): aynı anda iki çağrı aynı kişiye
-- iki bildirim atamaz; dışarıdan tetiklemek en çok o saatin bildirimini birkaç dakika erken gönderir.
create or replace function public.hk_push_claim(p_hour int, p_today date) returns table (endpoint text, p256dh text, auth text)
language sql security definer set search_path = public, pg_temp as $$
  update hk_push set last_sent = p_today
   where hour = p_hour and (last_sent is null or last_sent < p_today) and hk_push_host_ok(hk_push.endpoint)
  returning hk_push.endpoint, hk_push.p256dh, hk_push.auth;
$$;
revoke execute on function public.hk_push_claim(int, date) from public, anon, authenticated;

revoke execute on function public.hk_push_save(text, text, text, int) from public;
revoke execute on function public.hk_push_remove(text) from public;
grant execute on function public.hk_push_save(text, text, text, int) to anon, authenticated;
grant execute on function public.hk_push_remove(text) to anon, authenticated;

-- Saat başı gönderici (pg_cron + pg_net). İşlev JWT istemez; abonelikleri atomik alır (hk_push_claim), günde bir kez
-- gönderir: dışarıdan tetiklenmesi zararsızdır. <PROJE> yerine proje adresini yaz.
-- create extension if not exists pg_cron;
-- create extension if not exists pg_net;
-- select cron.schedule('hk-push-saatlik', '0 * * * *',
--   $$ select net.http_post(url := 'https://<PROJE>.supabase.co/functions/v1/hk-push', body := '{}'::jsonb) $$);

-- ---------- oyun-ortak düzeltmesi ----------
-- Hesap bütün oyunlarda ortak: auth kaydı yalnız oyuncunun başka oyunda izi yoksa silinir.
-- Tam silme için oyunlar ortak.hesabi_sil() kullanır (docs/ENTEGRASYON.md).
create or replace function public.hk_delete_account() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'giriş gerekli'; end if;
  delete from hk_daily_scores where user_id = uid;
  delete from hk_daily_starts where user_id = uid;
  delete from hk_level_progress where user_id = uid;
  delete from hk_profiles where id = uid;
  delete from hk_entitlements where user_id = uid;
  if not exists (select 1 from ortak.oyuncular where kullanici_id = uid)
     and not exists (select 1 from ortak.kayitlar where kullanici_id = uid) then
    delete from auth.users where id = uid;
  end if;
end $$;
revoke execute on function public.hk_delete_account() from public, anon;
grant execute on function public.hk_delete_account() to authenticated;
