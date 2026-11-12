-- Beat Greedy (sezgi) şeması: sezgi/supabase/migrations'daki 10 göç (12 Kasım 2026, 20261104…20261112)
-- `public` yerine `sezgi` şemasında. Dönüşüm mekaniktir (public. → sezgi., search_path); orijinal ile
-- nesne, politika ve yetki karşılaştırması oyun-ortak oturumunda yapıldı. Oyuna özgü şemanın sahibi bu depo.
-- Sezgi istemcisi ve Edge Function'ları `sezgi` şemasını kullanacak biçimde sezgi oturumunda güncellenir
-- (docs/GECIS_SEZGI.md).

create schema if not exists sezgi;
grant usage on schema sezgi to anon, authenticated, service_role;
alter default privileges in schema sezgi revoke all on tables from anon, authenticated, public;
alter default privileges in schema sezgi revoke all on sequences from anon, authenticated, public;
alter default privileges in schema sezgi revoke execute on functions from anon, authenticated, public;
alter default privileges in schema sezgi grant all on tables to service_role;
alter default privileges in schema sezgi grant all on sequences to service_role;
alter default privileges in schema sezgi grant execute on functions to service_role;
-- Göç gövdesindeki nitelenmemiş adlar da sezgi şemasına düşsün.
set search_path = sezgi, extensions, public;

-- ======== 20261104000000_faz5.sql ========
-- Faz 5: veri modeli, RLS, sıralamalar, günlük akışın SQL tarafı (docs/02-mimari.md).
-- Süre ve puanın son kaydı burada, doğrulama Edge Function'lardadır. İç fonksiyonlar yalnız servis rolünündür.

create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

-- Gün sınırı (02 §7)
create function sezgi.istanbul_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Istanbul')::date $$;

-- Uygunsuz ad filtresi (01 §5): en küçük liste. Kısa kelimeler yalnız bütün parça olarak aranır
-- (`asik`, `sikke` geçsin); uzunlar her yerde. Rakamlar harfe çevrilir (s1kt1r).
create function sezgi.username_allowed(name text) returns boolean
language sql immutable as $$
  with n as (select translate(lower(name), '013457', 'oieast') as v)
  select not exists (
      select from n, unnest(string_to_array(n.v, '_')) as part
      where part = any (array[
        'sik', 'sikik', 'pic', 'ibne', 'gavat', 'kahpe', 'got',
        'admin', 'moderator', 'mod', 'sistem', 'system', 'destek', 'support', 'root'])
    ) and not exists (
      select from n, unnest(array[
        'orospu', 'yarrak', 'amcik', 'aminakoy', 'siktir', 'sikis', 'pezevenk',
        'fuck', 'bitch', 'nigger', 'faggot']) as bad
      where n.v like '%' || bad || '%'
    )
$$;

create table sezgi.profiles (
  id uuid primary key references auth.users on delete cascade,
  username extensions.citext unique not null
    constraint username_format check (username::text ~ '^[A-Za-z0-9_]{3,20}$')
    constraint username_clean check (sezgi.username_allowed(username::text)),
  avatar text not null default 'a01' constraint avatar_length check (char_length(avatar) <= 16),
  created_at timestamptz not null default now()
);

create table sezgi.daily_puzzles (
  id bigserial primary key,
  game text not null,
  day date not null,                     -- Europe/Istanbul takvim günü
  engine_version int not null,
  params jsonb not null,
  instance jsonb not null,               -- Başla'dan önce istemciye gitmez (sütun yetkisi aşağıda)
  target_value double precision not null,
  target_proven boolean not null,
  greedy_value double precision not null,
  baseline double precision,             -- yalnız Boru Hattı: MST uzunluğu (K3)
  target_beaten boolean not null default false,  -- 02 §4.8
  target_updated_at timestamptz,         -- gün bitince hedef güncellendiyse
  unique (game, day)
);

-- Çözümler ayrı tabloda: istemci rolü hiç okuyamaz
create table sezgi.daily_solutions (
  puzzle_id bigint primary key references sezgi.daily_puzzles on delete cascade,
  solution jsonb not null
);

create table sezgi.attempts (
  id bigserial primary key,
  user_id uuid not null references sezgi.profiles on delete cascade,
  puzzle_id bigint not null references sezgi.daily_puzzles on delete cascade,
  status text not null check (status in ('started','submitted','timeout','abandoned')),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  duration_ms int,                        -- sunucu hesaplar
  client_ms int,                          -- yalnız karşılaştırma için
  value double precision,
  score int check (score between 0 and 1000),
  solution jsonb,
  flags text[] not null default '{}',     -- too_fast, clock_mismatch, connection_lost, after_day_end
  unique (user_id, puzzle_id)
);
create index on sezgi.attempts (puzzle_id, score desc, duration_ms asc, submitted_at asc) where status = 'submitted';
create index on sezgi.attempts (started_at) where status = 'started';

create table sezgi.level_progress (
  user_id uuid references sezgi.profiles on delete cascade,
  game text, level int,
  stars int not null check (stars between 0 and 3), best_value double precision, best_time_ms int,
  updated_at timestamptz not null default now(),
  primary key (user_id, game, level)
);
create table sezgi.tutorial_progress (
  user_id uuid references sezgi.profiles on delete cascade,
  game text, completed_at timestamptz not null default now(),
  primary key (user_id, game)
);

-- Davet kodu: karışmayan harf/rakam (0/O, 1/I/L yok)
create function sezgi.new_invite_code() returns text
language sql volatile set search_path = sezgi, extensions as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', get_byte(b, i) % 31 + 1, 1), '')
  from gen_random_bytes(6) as b, generate_series(0, 5) as i
$$;

create table sezgi.leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 3 and 30),
  description text,
  invite_code text unique not null default sezgi.new_invite_code(),
  owner_id uuid not null references sezgi.profiles,
  created_at timestamptz not null default now()
);
create table sezgi.league_members (
  league_id uuid references sezgi.leagues on delete cascade,
  user_id uuid references sezgi.profiles on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
create index on sezgi.league_members (user_id);

-- Edge Function hız sınırı (02 §5): kullanıcı × fonksiyon × dakika
create table sezgi.rate_limits (
  user_id uuid not null,
  fn text not null,
  window_start timestamptz not null,
  count int not null,
  primary key (user_id, fn, window_start)
);

---------------------------------------------------------------------------------------------------
-- Sıralamalar (01 §4). Görünümler sahibinin yetkisiyle çalışır: RLS'yi atlar, yalnız skor/süre sütunlarını açar.

create view sezgi.board_game_day as
select p.game, p.day, a.user_id, pr.username, pr.avatar, a.score, a.duration_ms, a.submitted_at,
       rank() over (partition by a.puzzle_id order by a.score desc, a.duration_ms asc, a.submitted_at asc) as rank
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where a.status in ('submitted','timeout');

create view sezgi.board_day as
select p.day, a.user_id, pr.username, pr.avatar,
       sum(a.score)::int as total, sum(a.duration_ms)::bigint as total_ms, count(*)::int as games,
       rank() over (partition by p.day order by sum(a.score) desc, sum(a.duration_ms) asc) as rank
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where a.status in ('submitted','timeout')
group by p.day, a.user_id, pr.username, pr.avatar;

-- Hafta Pazartesi başlar: Postgres `date_trunc('week')` da öyle (02 §7). 10 dakikada bir yenilenir.
create materialized view sezgi.board_week as
select date_trunc('week', day)::date as week_start, user_id, username, avatar,
       sum(total)::int as total, sum(total_ms)::bigint as total_ms, count(*)::int as days,
       rank() over (partition by date_trunc('week', day) order by sum(total) desc, sum(total_ms) asc) as rank
from sezgi.board_day
group by date_trunc('week', day), user_id, username, avatar;
create unique index on sezgi.board_week (week_start, user_id);

-- Tüm zamanlar: son 30 günün (bugün dahil) en iyi 20 günü.
create materialized view sezgi.board_all_time as
with best as (
  select *, row_number() over (partition by user_id order by total desc, total_ms asc) as n
  from sezgi.board_day
  where day > sezgi.istanbul_today() - 30 and day <= sezgi.istanbul_today()
)
select user_id, username, avatar,
       sum(total)::int as total, sum(total_ms)::bigint as total_ms, count(*)::int as days,
       rank() over (order by sum(total) desc, sum(total_ms) asc) as rank
from best where n <= 20
group by user_id, username, avatar;
create unique index on sezgi.board_all_time (user_id);

-- 02 §5: bayraklı denemeler tabloda kalır, inceleme buradan yapılır. Yalnız servis rolü.
create view sezgi.attempts_for_review as
select a.id, a.user_id, a.puzzle_id, a.status, a.duration_ms, a.client_ms, a.value, a.score, a.flags
from sezgi.attempts a where a.flags <> '{}';

---------------------------------------------------------------------------------------------------
-- Günlük akış (02 §4). Yalnız servis rolü çağırır.

-- 60 dakikayı geçen denemeler 0 puan (01 §1.3). `submitted_at` boş kalır: tabloda en altta sıralanır.
create function sezgi.expire_attempts() returns int
language sql set search_path = sezgi as $$
  with u as (
    update attempts set status = 'timeout', score = 0, duration_ms = 3600000
    where status = 'started' and started_at < now() - interval '60 minutes'
    returning 1
  ) select count(*)::int from u
$$;

create function sezgi.hit_rate_limit(p_user uuid, p_fn text, p_max int) returns boolean
language sql set search_path = sezgi as $$
  insert into rate_limits as r (user_id, fn, window_start, count)
  values (p_user, p_fn, date_trunc('minute', now()), 1)
  on conflict (user_id, fn, window_start) do update set count = r.count + 1
  returning count <= p_max
$$;

-- Supabase'te extra_float_digits varsayılanı 0: float8 15 haneye kırpılır, hedef dosyadakiyle eşleşmez (K17).
-- Hedef taşıyan fonksiyonlar bu yüzden 1 ile çalışır.
-- Bugünü sunucu belirler. Sürüm uyuşmazlığında deneme açılmaz: oyuncunun hakkı ve süresi yanmaz.
create function sezgi.start_attempt_tx(p_user uuid, p_game text, p_engine_version int, p_client_version int)
returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  p daily_puzzles;
  a attempts;
begin
  select * into p from daily_puzzles where game = p_game and day = istanbul_today();
  if not found then return jsonb_build_object('error', 'no_puzzle'); end if;
  if p.engine_version <> p_engine_version then return jsonb_build_object('error', 'engine_mismatch'); end if;
  if p.engine_version <> coalesce(p_client_version, p.engine_version) then
    return jsonb_build_object('error', 'client_outdated');
  end if;
  if not exists (select from profiles where id = p_user) then
    return jsonb_build_object('error', 'no_profile');
  end if;
  perform expire_attempts();
  insert into attempts (user_id, puzzle_id, status) values (p_user, p.id, 'started')
  on conflict (user_id, puzzle_id) do nothing;
  select * into a from attempts where user_id = p_user and puzzle_id = p.id;
  return jsonb_build_object(
    'attempt_id', a.id, 'puzzle_id', p.id, 'game', p.game, 'day', p.day,
    'status', a.status, 'started_at', a.started_at, 'server_now', now(),
    'engine_version', p.engine_version, 'params', p.params, 'instance', p.instance,
    'target_value', p.target_value, 'target_proven', p.target_proven, 'baseline', p.baseline,
    'value', a.value, 'score', a.score, 'duration_ms', a.duration_ms, 'flags', a.flags);
end $$;

create function sezgi.attempt_for_submit(p_attempt bigint, p_user uuid) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select jsonb_build_object(
    'status', a.status, 'expired', a.started_at < now() - interval '60 minutes',
    'game', p.game, 'engine_version', p.engine_version, 'instance', p.instance,
    'target_value', p.target_value, 'baseline', p.baseline)
  from attempts a join daily_puzzles p on p.id = a.puzzle_id
  where a.id = p_attempt and a.user_id = p_user
$$;

-- Tek yazım noktası: süre burada, `now()` ile hesaplanır. İkinci teslim kaydı değiştirmez.
create function sezgi.finish_attempt_tx(
  p_attempt bigint, p_user uuid, p_value double precision, p_score int, p_solution jsonb,
  p_client_ms int, p_min_ms int, p_beaten boolean, p_retried boolean
) returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  a attempts;
  p daily_puzzles;
  already boolean;
  ms int;
  fl text[] := '{}';
begin
  select * into a from attempts where id = p_attempt and user_id = p_user for update;
  if not found then return jsonb_build_object('error', 'attempt_not_found'); end if;
  select * into p from daily_puzzles where id = a.puzzle_id;
  already := a.status <> 'started';
  if not already then
    if a.started_at < now() - interval '60 minutes' then
      update attempts set status = 'timeout', score = 0, duration_ms = 3600000
      where id = a.id returning * into a;
    else
      ms := round(extract(epoch from now() - a.started_at) * 1000)::int;
      if ms < p_min_ms then fl := array_append(fl, 'too_fast'); end if;
      if p_client_ms is not null and abs(ms - p_client_ms) > 10000 then fl := array_append(fl, 'clock_mismatch'); end if;
      if p_retried then fl := array_append(fl, 'connection_lost'); end if;
      -- Çözüm gece yarısı açılır, açık deneme 60 dakika daha sürebilir: sıralamada kalır, incelemeye düşer.
      if p.day < istanbul_today() then fl := array_append(fl, 'after_day_end'); end if;
      update attempts set status = 'submitted', submitted_at = now(), duration_ms = ms, client_ms = p_client_ms,
        value = p_value, score = p_score, solution = p_solution, flags = fl
      where id = a.id returning * into a;
      if p_beaten then
        update daily_puzzles set target_beaten = true where id = p.id returning * into p;
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'attempt_id', a.id, 'status', a.status, 'value', a.value, 'score', a.score,
    'duration_ms', a.duration_ms, 'submitted_at', a.submitted_at, 'flags', a.flags,
    'target_value', p.target_value, 'greedy_value', p.greedy_value, 'target_beaten', p.target_beaten,
    'already_final', already);
end $$;

-- Gün bittikten sonra çözüm ve bulmaca açılır (02 §4.7).
create function sezgi.solution_for_day(p_game text, p_day date) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select case
    -- Açık deneme gün bitiminden 60 dakika sonra kapanır: çözüm o ana kadar kimseye açılmaz.
    when now() < ((p_day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour'
      then jsonb_build_object('error', 'day_not_over')
    when p.id is null then jsonb_build_object('error', 'no_puzzle')
    else jsonb_build_object(
      'game', p.game, 'day', p.day, 'engine_version', p.engine_version, 'params', p.params,
      'instance', p.instance, 'solution', s.solution, 'target_value', p.target_value,
      'target_proven', p.target_proven, 'greedy_value', p.greedy_value, 'baseline', p.baseline,
      'target_beaten', p.target_beaten)
    end
  from (select 1) as one
  left join daily_puzzles p on p.game = p_game and p.day = p_day
  left join daily_solutions s on s.puzzle_id = p.id
$$;

-- 02 §4.8: gün bitip açık deneme kalmayınca hedef, geçen en iyi değere çekilir. Puanlar değişmez.
-- Yalnız Boru Hattı (`target_proven = false`, yön min) buraya düşer.
create function sezgi.update_beaten_targets() returns int
language sql set search_path = sezgi as $$
  with best as (
    select distinct on (a.puzzle_id) a.puzzle_id, a.value, a.solution
    from attempts a join daily_puzzles p on p.id = a.puzzle_id
    where p.target_beaten and p.target_updated_at is null and p.day < istanbul_today()
      and a.status = 'submitted' and a.value < p.target_value
      and not exists (select from attempts o where o.puzzle_id = p.id and o.status = 'started')
    order by a.puzzle_id, a.value asc
  ), sol as (
    update daily_solutions s set solution = b.solution from best b where s.puzzle_id = b.puzzle_id
  ), u as (
    update daily_puzzles p set target_value = b.value, target_updated_at = now()
    from best b where p.id = b.puzzle_id returning 1
  ) select count(*)::int from u
$$;

-- levelgen upload: tek gün tek işlem. Bugün ve geçmiş kilitlidir: aynıysa dokunulmaz (güncellenen hedef
-- korunur), farklıysa hata. Gelecek gün yeniden üretilmiş stokla değişebilir.
create function sezgi.upload_daily_puzzle(p_row jsonb) returns text
language plpgsql set search_path = sezgi as $$
declare
  cur daily_puzzles;
  cur_sol jsonb;
  new_id bigint;
begin
  select * into cur from daily_puzzles where game = p_row->>'game' and day = (p_row->>'day')::date for update;
  if not found then
    insert into daily_puzzles (game, day, engine_version, params, instance, target_value, target_proven, greedy_value, baseline)
    values (p_row->>'game', (p_row->>'day')::date, (p_row->>'engine_version')::int, p_row->'params', p_row->'instance',
      (p_row->>'target_value')::double precision, (p_row->>'target_proven')::boolean,
      (p_row->>'greedy_value')::double precision, (p_row->>'baseline')::double precision)
    returning id into new_id;
    insert into daily_solutions (puzzle_id, solution) values (new_id, p_row->'solution');
    return 'inserted';
  end if;
  if cur.day <= istanbul_today() then
    if (cur.engine_version, cur.params, cur.instance) is distinct from
       ((p_row->>'engine_version')::int, p_row->'params', p_row->'instance') then
      raise exception 'puzzle_locked: % % zaten yayında ve stoktan farklı', cur.game, cur.day;
    end if;
    return 'unchanged';
  end if;
  select solution into cur_sol from daily_solutions where puzzle_id = cur.id;
  if (cur.engine_version, cur.params, cur.instance, cur.target_value, cur.target_proven, cur.greedy_value, cur.baseline, cur_sol)
     is not distinct from
     ((p_row->>'engine_version')::int, p_row->'params', p_row->'instance', (p_row->>'target_value')::double precision,
      (p_row->>'target_proven')::boolean, (p_row->>'greedy_value')::double precision,
      (p_row->>'baseline')::double precision, p_row->'solution') then
    return 'unchanged';
  end if;
  update daily_puzzles set engine_version = (p_row->>'engine_version')::int, params = p_row->'params',
    instance = p_row->'instance', target_value = (p_row->>'target_value')::double precision,
    target_proven = (p_row->>'target_proven')::boolean, greedy_value = (p_row->>'greedy_value')::double precision,
    baseline = (p_row->>'baseline')::double precision
  where id = cur.id;
  update daily_solutions set solution = p_row->'solution' where puzzle_id = cur.id;
  return 'replaced';
end $$;

-- Materialized view'ı yalnız sahibi yeniler; testler servis rolüyle çağırır.
create function sezgi.refresh_boards() returns void
language plpgsql security definer set search_path = sezgi as $$
begin
  refresh materialized view concurrently board_week;
  refresh materialized view concurrently board_all_time;
end $$;

---------------------------------------------------------------------------------------------------
-- Ligler (RLS tablosu; ekranlar ve kalan yönetici işlemleri Faz 6)

create function sezgi.is_league_member(p_league uuid) returns boolean
language sql stable security definer set search_path = sezgi as $$
  select exists (select from league_members where league_id = p_league and user_id = auth.uid())
$$;

-- Kurucu üye olarak eklenir; bir oyuncu en çok 10 lige üye olabilir (01 §6).
create function sezgi.league_add_owner() returns trigger
language plpgsql security definer set search_path = sezgi as $$
begin
  if (select count(*) from league_members where user_id = new.owner_id) >= 10 then
    raise exception 'league_limit';
  end if;
  insert into league_members (league_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return new;
end $$;
create trigger league_add_owner after insert on sezgi.leagues
for each row execute function sezgi.league_add_owner();

create function sezgi.league_by_code(p_code text)
returns table (id uuid, name text, description text, members int)
language sql stable security definer set search_path = sezgi as $$
  select l.id, l.name, l.description, (select count(*)::int from league_members m where m.league_id = l.id)
  from leagues l where l.invite_code = upper(p_code)
$$;

create function sezgi.join_league(p_code text) returns uuid
language plpgsql security definer set search_path = sezgi as $$
declare
  l uuid;
begin
  select id into l from leagues where invite_code = upper(p_code) for update;
  if l is null then raise exception 'league_not_found'; end if;
  if (select count(*) from league_members where user_id = auth.uid()) >= 10 then raise exception 'league_limit'; end if;
  if (select count(*) from league_members where league_id = l) >= 100 then raise exception 'league_full'; end if;
  insert into league_members (league_id, user_id) values (l, auth.uid()) on conflict do nothing;
  return l;
end $$;

-- Kurucu ayrılamaz: önce devreder ya da ligi siler (Faz 6).
create function sezgi.leave_league(p_league uuid) returns void
language sql security definer set search_path = sezgi as $$
  delete from league_members where league_id = p_league and user_id = auth.uid() and role <> 'owner'
$$;

create function sezgi.remove_league_member(p_league uuid, p_user uuid) returns void
language sql security definer set search_path = sezgi as $$
  delete from league_members m using leagues l
  where m.league_id = p_league and m.user_id = p_user and m.role <> 'owner'
    and l.id = p_league and l.owner_id = auth.uid()
$$;

---------------------------------------------------------------------------------------------------
-- RLS ve yetkiler (02 §3). Supabase varsayılan yetkileri geniştir: hepsi kapatılıp tek tek açılır.

alter table sezgi.profiles enable row level security;
alter table sezgi.daily_puzzles enable row level security;
alter table sezgi.daily_solutions enable row level security;
alter table sezgi.attempts enable row level security;
alter table sezgi.level_progress enable row level security;
alter table sezgi.tutorial_progress enable row level security;
alter table sezgi.leagues enable row level security;
alter table sezgi.league_members enable row level security;
alter table sezgi.rate_limits enable row level security;

revoke all on all tables in schema sezgi from anon, authenticated;
revoke all on all sequences in schema sezgi from anon, authenticated;
revoke all on all functions in schema sezgi from public, anon, authenticated;
grant all on all tables in schema sezgi to service_role;
grant all on all sequences in schema sezgi to service_role;
grant all on all functions in schema sezgi to service_role;

grant execute on function sezgi.istanbul_today() to anon, authenticated;
grant execute on function sezgi.username_allowed(text) to anon, authenticated;
grant execute on function sezgi.is_league_member(uuid) to authenticated;
grant execute on function sezgi.new_invite_code() to authenticated;
grant execute on function sezgi.league_by_code(text) to authenticated;
grant execute on function sezgi.join_league(text) to authenticated;
grant execute on function sezgi.leave_league(uuid) to authenticated;
grant execute on function sezgi.remove_league_member(uuid, uuid) to authenticated;

grant select on sezgi.board_game_day, sezgi.board_day, sezgi.board_week, sezgi.board_all_time to authenticated;

grant select on sezgi.profiles to anon, authenticated;
grant insert (id, username, avatar), update (username, avatar) on sezgi.profiles to authenticated;
create policy profiles_read on sezgi.profiles for select to anon, authenticated using (true);
create policy profiles_insert on sezgi.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on sezgi.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
-- Silme yetkisi yok: profil silinince denemeler de silinir, aynı hesap günün bulmacasına yeniden başlardı.
-- Hesap silme (Faz 8) auth.users satırını da silen ayrıcalıklı bir yoldan yapılacak.

-- Örnek, hedef ve açgözlü Başla'dan önce gitmez (01 §1.3, 02 §5): satır RLS'yle, sütun yetkiyle kısıtlı.
grant select (id, game, day, engine_version, params, target_proven) on sezgi.daily_puzzles to authenticated;
create policy daily_puzzles_read on sezgi.daily_puzzles for select to authenticated using (day <= sezgi.istanbul_today());

-- daily_solutions, rate_limits: ilke yok, yetki yok.

grant select on sezgi.attempts to authenticated;
create policy attempts_read on sezgi.attempts for select to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on sezgi.level_progress, sezgi.tutorial_progress to authenticated;
create policy level_progress_own on sezgi.level_progress for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tutorial_progress_own on sezgi.tutorial_progress for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, delete on sezgi.leagues to authenticated;
grant insert (name, description, owner_id), update (name, description) on sezgi.leagues to authenticated;
create policy leagues_read on sezgi.leagues for select to authenticated using (owner_id = auth.uid() or sezgi.is_league_member(id));
create policy leagues_insert on sezgi.leagues for insert to authenticated with check (owner_id = auth.uid());
create policy leagues_update on sezgi.leagues for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy leagues_delete on sezgi.leagues for delete to authenticated using (owner_id = auth.uid());

grant select on sezgi.league_members to authenticated;
create policy league_members_read on sezgi.league_members for select to authenticated using (sezgi.is_league_member(league_id));

---------------------------------------------------------------------------------------------------
-- Zamanlanmış işler (02 §3–4)

select cron.schedule('sezgi-expire-attempts', '* * * * *', 'select sezgi.expire_attempts()');
select cron.schedule('sezgi-refresh-boards', '*/10 * * * *', 'select sezgi.refresh_boards()');
select cron.schedule('sezgi-update-targets', '5 * * * *', 'select sezgi.update_beaten_targets()');
select cron.schedule('sezgi-clean-rate-limits', '17 * * * *',
  $$delete from sezgi.rate_limits where window_start < now() - interval '5 minutes'$$);

-- ======== 20261104100000_faz6.sql ========
-- Faz 6: lig yönetimi (kod yenileme, devir), lig içi tablolar, davet koduna hız sınırı (01 §6, 02 §3, K50).
-- Supabase'in varsayılan yetkileri yeni nesnelere geniş açar: burada oluşan her şey kapatılıp tek tek açılır.

-- Ad kırpılmış gelir (yalnız boşluk 3 karakter sayılmasın); açıklama için üst sınır.
alter table sezgi.leagues
  add constraint league_name_trimmed check (name = btrim(name)),
  add constraint league_description_length check (char_length(description) <= 200);

-- Kişi başına 10 lig sınırı aynı anda iki katılımla aşılmasın: profil satırı sırayı belirler.
create or replace function sezgi.league_add_owner() returns trigger
language plpgsql security definer set search_path = sezgi as $$
begin
  perform 1 from profiles where id = new.owner_id for no key update;
  if (select count(*) from league_members where user_id = new.owner_id) >= 10 then
    raise exception 'league_limit';
  end if;
  insert into league_members (league_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return new;
end $$;

-- Kod denemesi kullanıcı başına dakikada 20 (31^6 kod arasında kaba kuvveti zorlaştırır). Önizleme ve
-- katılım aynı sayacı paylaşır. Sayaç işlemle birlikte geri alındığından, bulunamayan kod hata atmaz,
-- boş döner: hata atsaydı başarısız denemeler hiç sayılmazdı.
create or replace function sezgi.league_by_code(p_code text)
returns table (id uuid, name text, description text, members int)
language plpgsql volatile security definer set search_path = sezgi as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not hit_rate_limit(auth.uid(), 'league_code', 20) then raise exception 'rate_limited'; end if;
  return query
    select l.id, l.name, l.description, (select count(*)::int from league_members m where m.league_id = l.id)
    from leagues l where l.invite_code = upper(btrim(p_code));
end $$;

-- null: kod yok. Zaten üye olan sınırlara takılmaz, aynı lige döner.
create or replace function sezgi.join_league(p_code text) returns uuid
language plpgsql security definer set search_path = sezgi as $$
declare
  l uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not hit_rate_limit(auth.uid(), 'league_code', 20) then raise exception 'rate_limited'; end if;
  select id into l from leagues where invite_code = upper(btrim(p_code)) for update;
  if l is null then return null; end if;
  if exists (select from league_members where league_id = l and user_id = auth.uid()) then return l; end if;
  perform 1 from profiles where id = auth.uid() for no key update;
  if (select count(*) from league_members where user_id = auth.uid()) >= 10 then raise exception 'league_limit'; end if;
  if (select count(*) from league_members where league_id = l) >= 100 then raise exception 'league_full'; end if;
  insert into league_members (league_id, user_id) values (l, auth.uid());
  return l;
end $$;

-- Üyelik işlemleri lig satırını kilitler: devirle yarışıp kurucusuz lig bırakamaz.
create or replace function sezgi.leave_league(p_league uuid) returns void
language plpgsql security definer set search_path = sezgi as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform 1 from leagues where id = p_league for update;
  if exists (select from leagues where id = p_league and owner_id = auth.uid()) then
    raise exception 'owner_cannot_leave';
  end if;
  delete from league_members where league_id = p_league and user_id = auth.uid();
end $$;

create or replace function sezgi.remove_league_member(p_league uuid, p_user uuid) returns void
language plpgsql security definer set search_path = sezgi as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform 1 from leagues where id = p_league and owner_id = auth.uid() for update;
  if not found then raise exception 'not_owner'; end if;
  if p_user = auth.uid() then raise exception 'owner_cannot_leave'; end if;
  delete from league_members where league_id = p_league and user_id = p_user;
  if not found then raise exception 'not_member'; end if;
end $$;

create function sezgi.rotate_league_code(p_league uuid) returns text
language plpgsql security definer set search_path = sezgi as $$
declare
  code text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update leagues set invite_code = new_invite_code()
  where id = p_league and owner_id = auth.uid() returning invite_code into code;
  if not found then raise exception 'not_owner'; end if;
  return code;
end $$;

-- Sahiplik ve iki rol aynı işlemde; eski kurucu üye kalır.
create function sezgi.transfer_league(p_league uuid, p_user uuid) returns void
language plpgsql security definer set search_path = sezgi as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform 1 from leagues where id = p_league and owner_id = auth.uid() for update;
  if not found then raise exception 'not_owner'; end if;
  if p_user = auth.uid() then return; end if;
  update league_members set role = 'owner' where league_id = p_league and user_id = p_user;
  if not found then raise exception 'not_member'; end if;
  update league_members set role = 'member' where league_id = p_league and user_id = auth.uid();
  update leagues set owner_id = p_user where id = p_league;
end $$;

revoke all on function sezgi.rotate_league_code(uuid), sezgi.transfer_league(uuid, uuid)
  from public, anon, authenticated;
grant execute on function sezgi.rotate_league_code(uuid), sezgi.transfer_league(uuid, uuid)
  to authenticated, service_role;

---------------------------------------------------------------------------------------------------
-- Lig içi tablolar (01 §4.3). Sahibinin yetkisiyle çalışır, RLS'yi atlar: `me` katılımı tek bekçidir,
-- yalnız çağıranın üye olduğu liglerin satırları çıkar. Sıra her lig için yeniden hesaplanır.

create view sezgi.league_board_game_day as
select m.league_id, p.game, p.day, a.user_id, pr.username, pr.avatar, a.score, a.duration_ms, a.submitted_at,
       rank() over (partition by m.league_id, a.puzzle_id order by a.score desc, a.duration_ms asc, a.submitted_at asc) as rank
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.attempts a on a.user_id = m.user_id
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where me.user_id = auth.uid() and a.status in ('submitted','timeout');

create view sezgi.league_board_day as
select m.league_id, p.day, a.user_id, pr.username, pr.avatar,
       sum(a.score)::int as total, sum(a.duration_ms)::bigint as total_ms, count(*)::int as games,
       rank() over (partition by m.league_id, p.day order by sum(a.score) desc, sum(a.duration_ms) asc) as rank
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.attempts a on a.user_id = m.user_id
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where me.user_id = auth.uid() and a.status in ('submitted','timeout')
group by m.league_id, p.day, a.user_id, pr.username, pr.avatar;

-- Haftalık ve tüm zamanlar genel tablonun toplamlarını kullanır (10 dakikada bir yenilenir).
create view sezgi.league_board_week as
select m.league_id, b.week_start, b.user_id, b.username, b.avatar, b.total, b.total_ms, b.days,
       rank() over (partition by m.league_id, b.week_start order by b.total desc, b.total_ms asc) as rank
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.board_week b on b.user_id = m.user_id
where me.user_id = auth.uid();

create view sezgi.league_board_all_time as
select m.league_id, b.user_id, b.username, b.avatar, b.total, b.total_ms, b.days,
       rank() over (partition by m.league_id order by b.total desc, b.total_ms asc) as rank
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.board_all_time b on b.user_id = m.user_id
where me.user_id = auth.uid();

revoke all on sezgi.league_board_game_day, sezgi.league_board_day, sezgi.league_board_week, sezgi.league_board_all_time
  from public, anon, authenticated;
grant select on sezgi.league_board_game_day, sezgi.league_board_day, sezgi.league_board_week, sezgi.league_board_all_time
  to authenticated;
grant all on sezgi.league_board_game_day, sezgi.league_board_day, sezgi.league_board_week, sezgi.league_board_all_time
  to service_role;

-- ======== 20261104200000_faz8.sql ========
-- Faz 8: hesap silinince hız sayacında da kullanıcı kimliği kalmasın (K61).
-- Profil olmadan da sayaç yazılır (ad seçilmeden çağrı): bağ auth.users'a.
delete from sezgi.rate_limits r where not exists (select from auth.users u where u.id = r.user_id);
alter table sezgi.rate_limits
  add constraint rate_limits_user_fk foreign key (user_id) references auth.users on delete cascade;

-- ======== 20261106000000_profil_seri.sql ========
-- F2: profilin Günlük kartı (01 §5, K83). Yalnız çağıranın verisi; seri sıralamaya girmez.
-- Tek satır jsonb: istemcide 1000 satır sınırına takılmaz. Gün, bulmacanın Europe/Istanbul günüdür.
-- ponytail: sıra görünümlerden gelir, görünüm tüm satırların sırasını hesaplar; oyuncu sayısı büyüyünce
-- sıra tablosu (materialized) ya da yalnız oynanan günlere süzülmüş sorgu.

create function sezgi.my_daily_stats() returns jsonb
language sql stable security definer set search_path = sezgi as $$
  with g as (
    select game, day, score, rank from board_game_day where user_id = auth.uid()
  ), d as (
    select day, total, rank from board_day where user_id = auth.uid()
  ), runs as (
    -- Ardışık günlerde gün − sıra sabittir: her grup bir seri.
    select count(*)::int as len, max(day) as last_day
    from (select day, day - (row_number() over (order by day))::int as grp from d) s
    group by grp
  )
  select jsonb_build_object(
    -- Şimdiki seri bugün ya da dünle biter: bugün henüz oynamayanın serisi gece yarısı kopmaz.
    'streak', coalesce((select max(len) from runs where last_day >= istanbul_today() - 1), 0),
    'best_streak', coalesce((select max(len) from runs), 0),
    'days', (select count(*)::int from d),
    'avg_total', (select round(avg(total))::int from d),
    'best_day_rank', (select min(rank)::int from d),
    'games', coalesce((
      select jsonb_object_agg(game, jsonb_build_object(
        'days', n, 'avg', avg_score, 'best_rank', best_rank))
      from (select game, count(*)::int as n, round(avg(score))::int as avg_score, min(rank)::int as best_rank
            from g group by game) x), '{}'::jsonb),
    -- Son 14 gün, eskiden bugüne; oynanmayan gün null.
    'recent', (
      select jsonb_agg(d.total order by s.day)
      from generate_series(istanbul_today() - 13, istanbul_today(), interval '1 day') as s(day)
      left join d on d.day = s.day::date)
  )
$$;

revoke all on function sezgi.my_daily_stats() from public, anon, authenticated;
grant execute on function sezgi.my_daily_stats() to authenticated, service_role;

-- ======== 20261107000000_ilerleme.sql ========
-- F3: Seviyeler için sunucu doğrulamalı İlerleme tablosu (K83, 01 §4.4, 02 §3).
-- level_progress oyuncunun beyanıdır; sıralama yalnız `submit_level`in doğruladığı ham yıldızla kurulur.
-- Doğrulama "çözüm geçerli ve hedefe bu kadar yakın" der, "oyuncu kendisi buldu" demez: bulmaca, hedef ve
-- hedef çözüm uygulama paketinde herkese açıktır, ipucu ve çözüme bakma sunucuya hiç gelmez.

-- Seviye bulmacaları: paketler ve başlangıç seviyeleri (`levelgen upload-levels`). Yalnız servis rolü.
create table sezgi.level_puzzles (
  game text not null,
  level int not null,                    -- bölüm × 1000 + sıra (apps/mobile/src/puzzle/sections.ts)
  engine_version int not null,
  instance jsonb not null,
  target_value double precision not null,
  baseline double precision,             -- yalnız Boru Hattı (K3)
  primary key (game, level)
);

-- Doğrulanmış en iyi sonuç; çözüm saklanmaz. Yalnız `record_level` yazar, yıldız yalnız artar.
create table sezgi.level_verified (
  user_id uuid not null references sezgi.profiles on delete cascade,
  game text not null,
  level int not null,
  raw_stars int not null check (raw_stars between 0 and 3),
  value double precision not null,
  verified_at timestamptz not null default now(),  -- bu yıldıza ilk ulaşılan an
  primary key (user_id, game, level)
);

-- K17: hedef 15 haneye kırpılmasın.
create function sezgi.level_for_submit(p_game text, p_level int) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select jsonb_build_object('engine_version', engine_version, 'instance', instance,
    'target_value', target_value, 'baseline', baseline)
  from level_puzzles where game = p_game and level = p_level
$$;

-- Daha az yıldızlı teslim satırı değiştirmez; eşit yıldızda ilk ulaşma zamanı korunur.
create function sezgi.record_level(
  p_user uuid, p_game text, p_level int, p_raw_stars int, p_value double precision
) returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  r level_verified;
begin
  if not exists (select from profiles where id = p_user) then
    return jsonb_build_object('error', 'no_profile');
  end if;
  insert into level_verified as v (user_id, game, level, raw_stars, value)
  values (p_user, p_game, p_level, p_raw_stars, p_value)
  on conflict (user_id, game, level) do update
    set raw_stars = excluded.raw_stars, value = excluded.value, verified_at = now()
    where excluded.raw_stars > v.raw_stars;
  select * into r from level_verified where user_id = p_user and game = p_game and level = p_level;
  return jsonb_build_object('game', r.game, 'level', r.level, 'raw_stars', r.raw_stars,
    'value', r.value, 'verified_at', r.verified_at);
end $$;

-- Oyun başına ve 10 oyunun toplamı (`game = 'all'`). Sıra: ham yıldız, Usta'da (bölüm 8, kod 7000+)
-- 3 yıldız, toplama ilk ulaşma. Sahibinin yetkisiyle çalışır: yalnız sıralama sütunları açılır.
-- ponytail: her sorguda tüm satırlar toplanır; oyuncu sayısı büyüyünce materialized view.
create view sezgi.board_levels as
with t as (
  select user_id, coalesce(game, 'all') as game, sum(raw_stars)::int as stars,
         (count(*) filter (where level >= 7000 and raw_stars = 3))::int as master3,
         max(verified_at) as reached_at
  from sezgi.level_verified
  group by grouping sets ((user_id, game), (user_id))
)
select t.game, t.user_id, pr.username, pr.avatar, t.stars, t.master3, t.reached_at,
       rank() over (partition by t.game order by t.stars desc, t.master3 desc, t.reached_at asc) as rank
from t join sezgi.profiles pr on pr.id = t.user_id
where t.stars > 0;

alter table sezgi.level_puzzles enable row level security;
alter table sezgi.level_verified enable row level security;

revoke all on sezgi.level_puzzles, sezgi.level_verified, sezgi.board_levels from public, anon, authenticated;
revoke all on function sezgi.level_for_submit(text, int), sezgi.record_level(uuid, text, int, int, double precision)
  from public, anon, authenticated;
grant all on sezgi.level_puzzles, sezgi.level_verified, sezgi.board_levels to service_role;
grant execute on function sezgi.level_for_submit(text, int), sezgi.record_level(uuid, text, int, int, double precision)
  to service_role;

grant select on sezgi.level_verified, sezgi.board_levels to authenticated;
create policy level_verified_read on sezgi.level_verified for select to authenticated using (user_id = auth.uid());

-- ======== 20261108000000_saklama.sql ========
-- F4 · KVKK saklama (K87, 02 §3 saklama tablosu): 90 günden eski denemelerin ayrıntısı temizlenir.
-- Puan, süre, değer ve durum kalır (sıralama ve profil serisi bunlarla kurulur); çözüm, cihaz süresi ve
-- inceleme bayrakları gider. `flags` boş dizi olur (sütun NOT NULL; `attempts_for_review` `<> '{}'` arar).
-- Güvenli: `daily_solution` yalnız `daily_solutions`'ı okur; `attempts.solution`'ı okuyan tek iş
-- `update_beaten_targets`tir (gün bitince, saatlik). Hedefi henüz güncellenmemiş bulmacanın denemelerine
-- dokunulmaz.

create function sezgi.purge_attempt_details() returns int
language sql set search_path = sezgi as $$
  with u as (
    update attempts a set solution = null, client_ms = null, flags = '{}'
    where a.started_at < now() - interval '90 days'
      and a.status <> 'started'
      and (a.solution is not null or a.client_ms is not null or a.flags <> '{}')
      and not exists (
        select from daily_puzzles p
        where p.id = a.puzzle_id and p.target_beaten and p.target_updated_at is null)
    returning 1
  ) select count(*)::int from u
$$;

revoke all on function sezgi.purge_attempt_details() from public, anon, authenticated;
grant execute on function sezgi.purge_attempt_details() to service_role;

select cron.schedule('sezgi-purge-attempt-details', '41 3 * * *', 'select sezgi.purge_attempt_details()');

-- ======== 20261109000000_gunluk_iki_mod.sql ========
-- F2b · Günlük iki mod (K89, 01 §1.3–1.4, 02 §3–4).
-- Veri modeli: Günün yarışı `daily_puzzles`ta `kind = 'race'` satırıdır, denemesi aynı `attempts` tablosunda.
-- Böylece başlatma, teslim, süre aşımı, saklama (K87), hesap silme zinciri ve dışa aktarma aynen çalışır;
-- yalnız sıralama görünümleri türe göre süzülür. Yarışın ek alanları denemede: `hints`, `reached`.

alter table sezgi.daily_puzzles
  add column kind text not null default 'daily' constraint daily_puzzles_kind check (kind in ('daily', 'race'));
alter table sezgi.daily_puzzles drop constraint daily_puzzles_game_day_key;
alter table sezgi.daily_puzzles add constraint daily_puzzles_kind_game_day_key unique (kind, game, day);
-- Günde tek yarış; oyunu levelgen tarihten seçer (10 günlük döngü).
create unique index daily_puzzles_race_day on sezgi.daily_puzzles (day) where kind = 'race';

alter table sezgi.attempts
  add column hints int not null default 0 constraint attempts_hints check (hints >= 0),  -- yalnız yarış artırır
  add column reached boolean;                                                            -- yarış: hedefe ulaştı

grant select (kind) on sezgi.daily_puzzles to authenticated;

-- Oyunun yönü: 1 büyük değer iyi, −1 küçük değer iyi (motorda `direction`; servertest eşleşmeyi denetler).
create function sezgi.game_sign(p_game text) returns int
language sql immutable as $$
  select case when p_game in ('canta', 'yilan') then 1 else -1 end
$$;

---------------------------------------------------------------------------------------------------
-- Sıralamalar. Günlük oyun tablosu ham değerle (K89): hedefi geçen öne geçer, 1000'de sabitlenen puan
-- değil. Değer 6 haneye yuvarlanır: aynı uzunluktaki iki tur kayan nokta gürültüsüyle ayrışmasın.
-- Gün toplamı (ve ondan türeyen hafta, tüm zamanlar, profil) puanla kalır; yarış ona girmez.

-- Hedef teslime kadar gizli (K89): bugünün bulmacasında değer ve puan, çağıran kendi denemesini bitirene
-- dek boş döner; ikisi birlikte hedefi verir. Açılış daily_solution ile aynı an: gün sonu + 1 saat teslim payı.
-- Sıra ve süre hedefi vermez.
create or replace view sezgi.board_game_day as
select p.game, p.day, a.user_id, pr.username, pr.avatar, case when now() >= ((p.day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour' or exists (select 1 from sezgi.attempts mine where mine.puzzle_id = a.puzzle_id and mine.user_id = auth.uid() and mine.status in ('submitted','timeout')) then a.score end as score, a.duration_ms, a.submitted_at,
       rank() over (partition by a.puzzle_id
         order by round((a.value * sezgi.game_sign(p.game))::numeric, 6) desc nulls last,
                  a.duration_ms asc, a.submitted_at asc) as rank,
       case when now() >= ((p.day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour' or exists (select 1 from sezgi.attempts mine where mine.puzzle_id = a.puzzle_id and mine.user_id = auth.uid() and mine.status in ('submitted','timeout')) then a.value end as value
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where p.kind = 'daily' and a.status in ('submitted','timeout');

create or replace view sezgi.board_day as
select p.day, a.user_id, pr.username, pr.avatar,
       sum(a.score)::int as total, sum(a.duration_ms)::bigint as total_ms, count(*)::int as games,
       rank() over (partition by p.day order by sum(a.score) desc, sum(a.duration_ms) asc) as rank
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where p.kind = 'daily' and a.status in ('submitted','timeout')
group by p.day, a.user_id, pr.username, pr.avatar;

create or replace view sezgi.league_board_game_day as
select m.league_id, p.game, p.day, a.user_id, pr.username, pr.avatar, case when now() >= ((p.day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour' or exists (select 1 from sezgi.attempts mine where mine.puzzle_id = a.puzzle_id and mine.user_id = auth.uid() and mine.status in ('submitted','timeout')) then a.score end as score, a.duration_ms, a.submitted_at,
       rank() over (partition by m.league_id, a.puzzle_id
         order by round((a.value * sezgi.game_sign(p.game))::numeric, 6) desc nulls last,
                  a.duration_ms asc, a.submitted_at asc) as rank,
       case when now() >= ((p.day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour' or exists (select 1 from sezgi.attempts mine where mine.puzzle_id = a.puzzle_id and mine.user_id = auth.uid() and mine.status in ('submitted','timeout')) then a.value end as value
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.attempts a on a.user_id = m.user_id
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where me.user_id = auth.uid() and p.kind = 'daily' and a.status in ('submitted','timeout');

create or replace view sezgi.league_board_day as
select m.league_id, p.day, a.user_id, pr.username, pr.avatar,
       sum(a.score)::int as total, sum(a.duration_ms)::bigint as total_ms, count(*)::int as games,
       rank() over (partition by m.league_id, p.day order by sum(a.score) desc, sum(a.duration_ms) asc) as rank
from sezgi.league_members me
join sezgi.league_members m on m.league_id = me.league_id
join sezgi.attempts a on a.user_id = m.user_id
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where me.user_id = auth.uid() and p.kind = 'daily' and a.status in ('submitted','timeout')
group by m.league_id, p.day, a.user_id, pr.username, pr.avatar;

-- Günün yarışı: hedefe ulaşanlar (süre + ipucu × 30 sn) artan; ulaşamayanlar altta, önce değer sonra süre.
-- Süre aşımı değersizdir, en altta. Lig içi yarış tablosu yok.
create view sezgi.board_race as
select p.day, p.game, a.user_id, pr.username, pr.avatar, a.value, a.duration_ms, a.hints,
       coalesce(a.reached, false) as reached,
       case when a.reached then a.duration_ms::bigint + a.hints * 30000 end as race_ms,
       a.submitted_at,
       rank() over (partition by a.puzzle_id
         order by case when a.reached then a.duration_ms::bigint + a.hints * 30000 end asc nulls last,
                  round((a.value * sezgi.game_sign(p.game))::numeric, 6) desc nulls last,
                  a.duration_ms asc, a.submitted_at asc) as rank
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where p.kind = 'race' and a.status in ('submitted','timeout');

---------------------------------------------------------------------------------------------------
-- Akış: aynı fonksiyonlar, tür alanıyla.

drop function sezgi.start_attempt_tx(uuid, text, int, int);
-- Günlük'te hedef teslime kadar gönderilmez (K89); kapanmış denemede (tekrar oyun) gider.
create function sezgi.start_attempt_tx(
  p_user uuid, p_game text, p_engine_version int, p_client_version int, p_kind text
) returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  p daily_puzzles;
  a attempts;
begin
  select * into p from daily_puzzles where kind = p_kind and game = p_game and day = istanbul_today();
  if not found then return jsonb_build_object('error', 'no_puzzle'); end if;
  if p.engine_version <> p_engine_version then return jsonb_build_object('error', 'engine_mismatch'); end if;
  if p.engine_version <> coalesce(p_client_version, p.engine_version) then
    return jsonb_build_object('error', 'client_outdated');
  end if;
  if not exists (select from profiles where id = p_user) then
    return jsonb_build_object('error', 'no_profile');
  end if;
  perform expire_attempts();
  insert into attempts (user_id, puzzle_id, status) values (p_user, p.id, 'started')
  on conflict (user_id, puzzle_id) do nothing;
  select * into a from attempts where user_id = p_user and puzzle_id = p.id;
  return jsonb_build_object(
    'attempt_id', a.id, 'puzzle_id', p.id, 'kind', p.kind, 'game', p.game, 'day', p.day,
    'status', a.status, 'started_at', a.started_at, 'server_now', now(),
    'engine_version', p.engine_version, 'params', p.params, 'instance', p.instance,
    'target_value', case when p.kind = 'daily' and a.status = 'started' then null else p.target_value end,
    'target_proven', p.target_proven, 'baseline', p.baseline,
    'value', a.value, 'score', a.score, 'duration_ms', a.duration_ms, 'flags', a.flags,
    'hints', a.hints, 'reached', a.reached);
end $$;

-- Teslim ve ipucu aynı satırı okur; hedef çözüm yalnız ipucu üretimi içindir, istemciye gitmez.
create or replace function sezgi.attempt_for_submit(p_attempt bigint, p_user uuid) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select jsonb_build_object(
    'status', a.status, 'expired', a.started_at < now() - interval '60 minutes',
    'kind', p.kind, 'hints', a.hints,
    'game', p.game, 'engine_version', p.engine_version, 'instance', p.instance,
    'target_value', p.target_value, 'target_proven', p.target_proven, 'baseline', p.baseline,
    'solution', s.solution)
  from attempts a join daily_puzzles p on p.id = a.puzzle_id
  left join daily_solutions s on s.puzzle_id = p.id
  where a.id = p_attempt and a.user_id = p_user
$$;

-- Yarışta her ipucu sayılır; açık olmayan ya da yarış olmayan denemede null.
create function sezgi.count_hint(p_attempt bigint, p_user uuid) returns int
language sql set search_path = sezgi as $$
  update attempts a set hints = a.hints + 1
  from daily_puzzles p
  where a.id = p_attempt and a.user_id = p_user and p.id = a.puzzle_id and p.kind = 'race'
    and a.status = 'started' and a.started_at >= now() - interval '60 minutes'
  returning a.hints
$$;

drop function sezgi.finish_attempt_tx(bigint, uuid, double precision, int, jsonb, int, int, boolean, boolean);
-- Tek yazım noktası: süre burada, `now()` ile hesaplanır. İkinci teslim kaydı değiştirmez.
-- p_reached yalnız yarışta dolu (Edge Function `gap = 0` ile karar verir).
create function sezgi.finish_attempt_tx(
  p_attempt bigint, p_user uuid, p_value double precision, p_score int, p_solution jsonb,
  p_client_ms int, p_min_ms int, p_beaten boolean, p_retried boolean, p_reached boolean
) returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  a attempts;
  p daily_puzzles;
  already boolean;
  ms int;
  fl text[] := '{}';
begin
  select * into a from attempts where id = p_attempt and user_id = p_user for update;
  if not found then return jsonb_build_object('error', 'attempt_not_found'); end if;
  select * into p from daily_puzzles where id = a.puzzle_id;
  already := a.status <> 'started';
  if not already then
    if a.started_at < now() - interval '60 minutes' then
      update attempts set status = 'timeout', score = 0, duration_ms = 3600000
      where id = a.id returning * into a;
    else
      ms := round(extract(epoch from now() - a.started_at) * 1000)::int;
      if ms < p_min_ms then fl := array_append(fl, 'too_fast'); end if;
      if p_client_ms is not null and abs(ms - p_client_ms) > 10000 then fl := array_append(fl, 'clock_mismatch'); end if;
      if p_retried then fl := array_append(fl, 'connection_lost'); end if;
      if p.day < istanbul_today() then fl := array_append(fl, 'after_day_end'); end if;
      update attempts set status = 'submitted', submitted_at = now(), duration_ms = ms, client_ms = p_client_ms,
        value = p_value, score = p_score, solution = p_solution, flags = fl,
        reached = case when p.kind = 'race' then coalesce(p_reached, false) end
      where id = a.id returning * into a;
      if p_beaten then
        update daily_puzzles set target_beaten = true where id = p.id returning * into p;
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'attempt_id', a.id, 'kind', p.kind, 'status', a.status, 'value', a.value, 'score', a.score,
    'duration_ms', a.duration_ms, 'submitted_at', a.submitted_at, 'flags', a.flags,
    'hints', a.hints, 'reached', a.reached,
    'target_value', p.target_value, 'greedy_value', p.greedy_value, 'target_beaten', p.target_beaten,
    'already_final', already);
end $$;

-- Dünün çözümü yalnız Günlük için (yarışın çözüm ekranı yok).
create or replace function sezgi.solution_for_day(p_game text, p_day date) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select case
    when now() < ((p_day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour'
      then jsonb_build_object('error', 'day_not_over')
    when p.id is null then jsonb_build_object('error', 'no_puzzle')
    else jsonb_build_object(
      'game', p.game, 'day', p.day, 'engine_version', p.engine_version, 'params', p.params,
      'instance', p.instance, 'solution', s.solution, 'target_value', p.target_value,
      'target_proven', p.target_proven, 'greedy_value', p.greedy_value, 'baseline', p.baseline,
      'target_beaten', p.target_beaten)
    end
  from (select 1) as one
  left join daily_puzzles p on p.kind = 'daily' and p.game = p_game and p.day = p_day
  left join daily_solutions s on s.puzzle_id = p.id
$$;

-- levelgen upload: satırın türü `kind` (yoksa daily). Yarış günde tektir: o günün yarışı oyunuyla birlikte
-- değişebilir (gelecek gün), yayındaki gün kilitli.
create or replace function sezgi.upload_daily_puzzle(p_row jsonb) returns text
language plpgsql set search_path = sezgi as $$
declare
  k text := coalesce(p_row->>'kind', 'daily');
  cur daily_puzzles;
  cur_sol jsonb;
  new_id bigint;
begin
  select * into cur from daily_puzzles
  where kind = k and day = (p_row->>'day')::date and (k = 'race' or game = p_row->>'game')
  for update;
  if not found then
    insert into daily_puzzles (kind, game, day, engine_version, params, instance, target_value, target_proven, greedy_value, baseline)
    values (k, p_row->>'game', (p_row->>'day')::date, (p_row->>'engine_version')::int, p_row->'params', p_row->'instance',
      (p_row->>'target_value')::double precision, (p_row->>'target_proven')::boolean,
      (p_row->>'greedy_value')::double precision, (p_row->>'baseline')::double precision)
    returning id into new_id;
    insert into daily_solutions (puzzle_id, solution) values (new_id, p_row->'solution');
    return 'inserted';
  end if;
  if cur.day <= istanbul_today() then
    if (cur.game, cur.engine_version, cur.params, cur.instance) is distinct from
       (p_row->>'game', (p_row->>'engine_version')::int, p_row->'params', p_row->'instance') then
      raise exception 'puzzle_locked: % % % zaten yayında ve üretimden farklı', k, cur.game, cur.day;
    end if;
    return 'unchanged';
  end if;
  select solution into cur_sol from daily_solutions where puzzle_id = cur.id;
  if (cur.game, cur.engine_version, cur.params, cur.instance, cur.target_value, cur.target_proven, cur.greedy_value, cur.baseline, cur_sol)
     is not distinct from
     (p_row->>'game', (p_row->>'engine_version')::int, p_row->'params', p_row->'instance', (p_row->>'target_value')::double precision,
      (p_row->>'target_proven')::boolean, (p_row->>'greedy_value')::double precision,
      (p_row->>'baseline')::double precision, p_row->'solution') then
    return 'unchanged';
  end if;
  update daily_puzzles set game = p_row->>'game', engine_version = (p_row->>'engine_version')::int,
    params = p_row->'params', instance = p_row->'instance',
    target_value = (p_row->>'target_value')::double precision,
    target_proven = (p_row->>'target_proven')::boolean, greedy_value = (p_row->>'greedy_value')::double precision,
    baseline = (p_row->>'baseline')::double precision, target_beaten = false, target_updated_at = null
  where id = cur.id;
  update daily_solutions set solution = p_row->'solution' where puzzle_id = cur.id;
  return 'replaced';
end $$;

---------------------------------------------------------------------------------------------------
-- Yetkiler: iç fonksiyonlar yalnız servis rolünün; yeni görünüm oturumla okunur.

revoke all on function
  sezgi.game_sign(text),
  sezgi.start_attempt_tx(uuid, text, int, int, text),
  sezgi.attempt_for_submit(bigint, uuid),
  sezgi.count_hint(bigint, uuid),
  sezgi.finish_attempt_tx(bigint, uuid, double precision, int, jsonb, int, int, boolean, boolean, boolean),
  sezgi.solution_for_day(text, date),
  sezgi.upload_daily_puzzle(jsonb)
  from public, anon, authenticated;
grant execute on function
  sezgi.game_sign(text),
  sezgi.start_attempt_tx(uuid, text, int, int, text),
  sezgi.attempt_for_submit(bigint, uuid),
  sezgi.count_hint(bigint, uuid),
  sezgi.finish_attempt_tx(bigint, uuid, double precision, int, jsonb, int, int, boolean, boolean, boolean),
  sezgi.solution_for_day(text, date),
  sezgi.upload_daily_puzzle(jsonb)
  to service_role;

-- Görünüm içindeki fonksiyon çağıranın yetkisiyle çalışır: sıralama görünümleri için oturuma açık.
grant execute on function sezgi.game_sign(text) to authenticated;

revoke all on sezgi.board_race from public, anon, authenticated;
grant select on sezgi.board_race to authenticated;
grant all on sezgi.board_race to service_role;

-- ======== 20261110000000_yaris_on_oyun.sql ========
-- K91 · Yarış 10 oyunu kapsar: her gün her oyundan bir Yarış bulmacası (01 §1.4, 02 §3–4).
-- Kısıt artık (kind, game, day) tekliği: yarış için (game, day) başına tek satır. Canlıda yüklü günlük tek
-- yarış satırı aynı oyunun satırı olarak kalır; levelgen aynı tohumla aynı bulmacayı üretir ("unchanged").
-- start_attempt_tx zaten (kind, game, day) ile arar; teslim ve ipucu deneme kimliğiyle çalışır.

drop index sezgi.daily_puzzles_race_day;

-- Yarış gün toplamı: önce ulaşılan hedef sayısı (çok olan önde), sonra ulaşılanların cezalı süre toplamı
-- (az olan önde). Ulaşılamayan bulmacanın süresi toplama girmez; hiç ulaşamayan altta, aralarında eşit.
create view sezgi.board_race_day as
select p.day, a.user_id, pr.username, pr.avatar,
       count(*) filter (where a.reached)::int as goals,
       sum(a.duration_ms::bigint + a.hints * 30000) filter (where a.reached) as race_ms,
       count(*)::int as games,
       rank() over (partition by p.day
         order by count(*) filter (where a.reached) desc,
                  sum(a.duration_ms::bigint + a.hints * 30000) filter (where a.reached) asc nulls last) as rank
from sezgi.attempts a
join sezgi.daily_puzzles p on p.id = a.puzzle_id
join sezgi.profiles pr on pr.id = a.user_id
where p.kind = 'race' and a.status in ('submitted','timeout')
group by p.day, a.user_id, pr.username, pr.avatar;

revoke all on sezgi.board_race_day from public, anon, authenticated;
grant select on sezgi.board_race_day to authenticated;
grant all on sezgi.board_race_day to service_role;

-- levelgen upload: satır (kind, game, day) ile bulunur; yarış da artık oyun bazında.
-- Yayındaki gün kilitli: aynıysa dokunulmaz, farklıysa hata. Gelecek gün yeniden üretimle değişebilir.
create or replace function sezgi.upload_daily_puzzle(p_row jsonb) returns text
language plpgsql set search_path = sezgi as $$
declare
  k text := coalesce(p_row->>'kind', 'daily');
  cur daily_puzzles;
  cur_sol jsonb;
  new_id bigint;
begin
  select * into cur from daily_puzzles
  where kind = k and day = (p_row->>'day')::date and game = p_row->>'game'
  for update;
  if not found then
    insert into daily_puzzles (kind, game, day, engine_version, params, instance, target_value, target_proven, greedy_value, baseline)
    values (k, p_row->>'game', (p_row->>'day')::date, (p_row->>'engine_version')::int, p_row->'params', p_row->'instance',
      (p_row->>'target_value')::double precision, (p_row->>'target_proven')::boolean,
      (p_row->>'greedy_value')::double precision, (p_row->>'baseline')::double precision)
    returning id into new_id;
    insert into daily_solutions (puzzle_id, solution) values (new_id, p_row->'solution');
    return 'inserted';
  end if;
  if cur.day <= istanbul_today() then
    if (cur.engine_version, cur.params, cur.instance) is distinct from
       ((p_row->>'engine_version')::int, p_row->'params', p_row->'instance') then
      raise exception 'puzzle_locked: % % % zaten yayında ve üretimden farklı', k, cur.game, cur.day;
    end if;
    return 'unchanged';
  end if;
  select solution into cur_sol from daily_solutions where puzzle_id = cur.id;
  if (cur.engine_version, cur.params, cur.instance, cur.target_value, cur.target_proven, cur.greedy_value, cur.baseline, cur_sol)
     is not distinct from
     ((p_row->>'engine_version')::int, p_row->'params', p_row->'instance', (p_row->>'target_value')::double precision,
      (p_row->>'target_proven')::boolean, (p_row->>'greedy_value')::double precision,
      (p_row->>'baseline')::double precision, p_row->'solution') then
    return 'unchanged';
  end if;
  update daily_puzzles set engine_version = (p_row->>'engine_version')::int,
    params = p_row->'params', instance = p_row->'instance',
    target_value = (p_row->>'target_value')::double precision,
    target_proven = (p_row->>'target_proven')::boolean, greedy_value = (p_row->>'greedy_value')::double precision,
    baseline = (p_row->>'baseline')::double precision, target_beaten = false, target_updated_at = null
  where id = cur.id;
  update daily_solutions set solution = p_row->'solution' where puzzle_id = cur.id;
  return 'replaced';
end $$;

revoke all on function sezgi.upload_daily_puzzle(jsonb) from public, anon, authenticated;
grant execute on function sezgi.upload_daily_puzzle(jsonb) to service_role;

-- ======== 20261111000000_gun_sonu.sql ========
-- K101: günlük denemenin süre sınırı 60 dakika değil, günün sonu: bulmacanın gününden sonraki 01:00
-- (Europe/Istanbul), çözümün açıldığı an (K40). Sayaç yine sürer; Keşif'te eşit değerde, Yarış'ta
-- her zaman süre sıralar. Süre aşımında `duration_ms` = son an − başlangıç.

create function sezgi.attempt_deadline(p_day date) returns timestamptz
language sql stable set search_path = sezgi as $$
  select ((p_day + 1)::timestamp at time zone 'Europe/Istanbul') + interval '1 hour'
$$;

create or replace function sezgi.expire_attempts() returns int
language sql set search_path = sezgi as $$
  with u as (
    update attempts a set status = 'timeout', score = 0,
      duration_ms = round(extract(epoch from attempt_deadline(p.day) - a.started_at) * 1000)::int
    from daily_puzzles p
    where p.id = a.puzzle_id and a.status = 'started' and now() >= attempt_deadline(p.day)
    returning 1
  ) select count(*)::int from u
$$;

create or replace function sezgi.attempt_for_submit(p_attempt bigint, p_user uuid) returns jsonb
language sql stable set search_path = sezgi set extra_float_digits = 1 as $$
  select jsonb_build_object(
    'status', a.status, 'expired', now() >= attempt_deadline(p.day),
    'kind', p.kind, 'hints', a.hints,
    'game', p.game, 'engine_version', p.engine_version, 'instance', p.instance,
    'target_value', p.target_value, 'target_proven', p.target_proven, 'baseline', p.baseline,
    'solution', s.solution)
  from attempts a join daily_puzzles p on p.id = a.puzzle_id
  left join daily_solutions s on s.puzzle_id = p.id
  where a.id = p_attempt and a.user_id = p_user
$$;

create or replace function sezgi.count_hint(p_attempt bigint, p_user uuid) returns int
language sql set search_path = sezgi as $$
  update attempts a set hints = a.hints + 1
  from daily_puzzles p
  where a.id = p_attempt and a.user_id = p_user and p.id = a.puzzle_id and p.kind = 'race'
    and a.status = 'started' and now() < attempt_deadline(p.day)
  returning a.hints
$$;

create or replace function sezgi.finish_attempt_tx(
  p_attempt bigint, p_user uuid, p_value double precision, p_score int, p_solution jsonb,
  p_client_ms int, p_min_ms int, p_beaten boolean, p_retried boolean, p_reached boolean
) returns jsonb language plpgsql set search_path = sezgi set extra_float_digits = 1 as $$
declare
  a attempts;
  p daily_puzzles;
  already boolean;
  ms int;
  fl text[] := '{}';
begin
  select * into a from attempts where id = p_attempt and user_id = p_user for update;
  if not found then return jsonb_build_object('error', 'attempt_not_found'); end if;
  select * into p from daily_puzzles where id = a.puzzle_id;
  already := a.status <> 'started';
  if not already then
    if now() >= attempt_deadline(p.day) then
      update attempts set status = 'timeout', score = 0,
        duration_ms = round(extract(epoch from attempt_deadline(p.day) - a.started_at) * 1000)::int
      where id = a.id returning * into a;
    else
      ms := round(extract(epoch from now() - a.started_at) * 1000)::int;
      if ms < p_min_ms then fl := array_append(fl, 'too_fast'); end if;
      if p_client_ms is not null and abs(ms - p_client_ms) > 10000 then fl := array_append(fl, 'clock_mismatch'); end if;
      if p_retried then fl := array_append(fl, 'connection_lost'); end if;
      if p.day < istanbul_today() then fl := array_append(fl, 'after_day_end'); end if;
      update attempts set status = 'submitted', submitted_at = now(), duration_ms = ms, client_ms = p_client_ms,
        value = p_value, score = p_score, solution = p_solution, flags = fl,
        reached = case when p.kind = 'race' then coalesce(p_reached, false) end
      where id = a.id returning * into a;
      if p_beaten then
        update daily_puzzles set target_beaten = true where id = p.id returning * into p;
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'attempt_id', a.id, 'kind', p.kind, 'status', a.status, 'value', a.value, 'score', a.score,
    'duration_ms', a.duration_ms, 'submitted_at', a.submitted_at, 'flags', a.flags,
    'hints', a.hints, 'reached', a.reached,
    'target_value', p.target_value, 'greedy_value', p.greedy_value, 'target_beaten', p.target_beaten,
    'already_final', already);
end $$;

revoke all on function sezgi.attempt_deadline(date) from public, anon, authenticated;
grant execute on function sezgi.attempt_deadline(date) to service_role;

-- ======== 20261112000000_guvenlik.sql ========
-- K104 · Güvenlik sertleştirmesi (02 §5). Davranış değişmez; yalnız savunma katmanı.

-- 1. Sabit search_path: güvenlik denetleyicisinin "function_search_path_mutable" uyarısı. Üçü de yalnız
-- yerleşik fonksiyon çağırır; pg_catalog yeterli. (Diğer bütün fonksiyonlarda zaten `set search_path` var.)
alter function sezgi.istanbul_today() set search_path = pg_catalog;
alter function sezgi.username_allowed(text) set search_path = pg_catalog;
alter function sezgi.game_sign(text) set search_path = pg_catalog;

-- 2. Varsayılan yetkiler: Supabase, `postgres`in public şemasında oluşturduğu her yeni tabloyu anon ve
-- authenticated'a, her yeni fonksiyonu PUBLIC'e açar. Şimdiye kadar her migrasyon bunu elle kapattı;
-- unutulan tek bir `revoke` iç fonksiyonu ya da tabloyu istemciye açardı. Bundan sonra yeni nesne kapalı
-- doğar, gereken yetki migrasyonda açıkça verilir (mevcut nesnelerin yetkileri değişmez). service_role'ün
-- şema düzeyindeki varsayılanı kalır. PUBLIC'in EXECUTE'u Postgres'in genel varsayılanıdır: şema düzeyinde
-- geri alınamaz, bu yüzden genel (şemasız) satır.
alter default privileges for role postgres in schema sezgi
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema sezgi
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema sezgi
  revoke execute on functions from anon, authenticated;
-- (oyun-ortak) Şemasız genel varsayılan yetki satırı kaldırıldı; bkz. dosya sonu.


-- ======== oyun-ortak sonu ========
reset search_path;
-- Postgres her fonksiyona PUBLIC çalıştırma yetkisi verir; şemaya bağlı varsayılan bunu geri alamaz.
revoke execute on all functions in schema sezgi from public;

-- ---------------------------------------------------------------- ortak yapıya bağlantı

-- "Bu oyundaki verimi sil" (ortak.oyun_verisini_sil('sezgi')) bunu çağırır. Profil silinince denemeler, ilerleme,
-- üyelikler zincirle gider. Lig kurucusu önce ligini devretmeli ya da silmeli (sezgi K50); yoksa hata.
create function sezgi.oyuncu_verisini_sil(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from sezgi.leagues where owner_id = u) then
    raise exception 'owns_leagues' using errcode = 'P0001';
  end if;
  delete from sezgi.profiles where id = u;
  delete from sezgi.rate_limits where user_id = u;
end $$;
revoke execute on function sezgi.oyuncu_verisini_sil(uuid) from public, anon, authenticated;

insert into ortak.oyunlar (id, ad, ayarlar) values (
  'sezgi', 'Beat Greedy',
  '{ "hesap": { "silme_fonksiyonu": "sezgi.oyuncu_verisini_sil" } }'
) on conflict (id) do nothing;
