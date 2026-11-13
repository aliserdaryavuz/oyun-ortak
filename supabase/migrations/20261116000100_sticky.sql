-- Sticky Ten (sticky şeması): ST-1 (istatistik, rating, günlükler; yalnız servis rolü yazar),
-- ST-2 (dönemlik rating sıralaması, haftalık ödül), ST-3 (takip, oyuna özgü). Kaynak: sticky-ten/server/accounts.ts.
-- Sütun adları bugünkü Postgres şemasıyla aynı tutuldu; Render'daki kod mekanik olarak taşınsın.
-- Kullanıcı adı → ortak.oyuncular('sticky'); Deluxe → ortak.haklar('deluxe'); hesap → Supabase Auth.

create schema if not exists sticky;
grant usage on schema sticky to anon, authenticated, service_role;
alter default privileges in schema sticky revoke all on tables from anon, authenticated, public;
alter default privileges in schema sticky revoke all on sequences from anon, authenticated, public;
alter default privileges in schema sticky revoke execute on functions from anon, authenticated, public;
alter default privileges in schema sticky grant all on tables to service_role;
alter default privileges in schema sticky grant all on sequences to service_role;
alter default privileges in schema sticky grant execute on functions to service_role;

insert into ortak.oyunlar (id, ad, ayarlar) values (
  'sticky', 'Sticky Ten', '{
    "ad": { "en_az": 3, "en_cok": 16, "degistirme_gun": 30 },
    "hesap": { "silme_fonksiyonu": "sticky.oyuncu_verisini_sil" },
    "odeme": { "revenuecat_uygulamalari": [] }
  }'
) on conflict (id) do nothing;
-- Mağaza ürün kimliği Play Console'da kesinleşince ayrı göçle değişebilir.
insert into ortak.urunler (urun, oyun_id, hak) values ('sticky_deluxe', 'sticky', 'deluxe') on conflict do nothing;

-- ---------------------------------------------------------------- ST-1

create table sticky.stats (
  user_id uuid primary key references auth.users on delete cascade,
  games int not null default 0,
  wins int not null default 0,
  total_score int not null default 0,
  best_score int,
  rating real not null default 1200,      -- START_RATING
  rated_games int not null default 0,
  rated_day text,                          -- İstanbul günü (YYYY-MM-DD)
  rated_today int not null default 0,
  progress jsonb,                          -- engine/goals.ts
  look jsonb                               -- kozmetik seçimleri (eski users.look)
);

create table sticky.rated_pairs (pair text not null, at timestamptz not null default now());
create index rated_pairs_pair_at on sticky.rated_pairs (pair, at);

create table sticky.rating_log (
  user_id uuid not null references auth.users on delete cascade,
  at timestamptz not null default now(),
  delta real not null
);
create index rating_log_at on sticky.rating_log (at);
create index rating_log_user on sticky.rating_log (user_id);

-- Render masa devri (oyun sunucusuna özgü; tek satır, servis kimliği anahtar).
create table sticky.handoff (
  id text primary key,
  data text,
  final boolean not null default false,
  saved_at timestamptz not null default now(),
  alive_at timestamptz not null default now(),
  wanted_at timestamptz,
  wanted_by text
);

alter table sticky.stats enable row level security;
alter table sticky.rated_pairs enable row level security;
alter table sticky.rating_log enable row level security;
alter table sticky.handoff enable row level security;

-- Bir oyunun sonucu tek işlemde. p_oyuncular: [{ user_id, score, won, delta? }] (delta yoksa puansız oyun).
-- p_gun: puanlı oyun günü (İstanbul, YYYY-MM-DD). p_ciftler: rated_pairs anahtarları.
-- Dönüş: [{ user_id, rating, rated_games, rated_today }] (yalnız puanlı oyuncular).
create function sticky.oyun_sonu(p_oyuncular jsonb, p_gun text, p_ciftler text[] default '{}') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare x jsonb; u uuid; d real; r record; sonuc jsonb := '[]';
begin
  for x in select * from jsonb_array_elements(p_oyuncular) loop
    u := (x ->> 'user_id')::uuid;
    insert into sticky.stats (user_id, games, wins, total_score, best_score)
      values (u, 1, (x ->> 'won')::boolean::int, (x ->> 'score')::int, (x ->> 'score')::int)
      on conflict (user_id) do update set
        games = sticky.stats.games + 1, wins = sticky.stats.wins + excluded.wins,
        total_score = sticky.stats.total_score + excluded.total_score,
        best_score = greatest(sticky.stats.best_score, excluded.best_score);
    if x ? 'delta' and x ->> 'delta' is not null then
      d := (x ->> 'delta')::real;
      update sticky.stats set
        rating = rating + d, rated_games = rated_games + 1,
        rated_today = case when rated_day = p_gun then rated_today + 1 else 1 end, rated_day = p_gun
      where user_id = u
      returning rating, rated_games, rated_today into r;
      insert into sticky.rating_log (user_id, delta) values (u, d);
      sonuc := sonuc || jsonb_build_object('user_id', u, 'rating', r.rating, 'rated_games', r.rated_games, 'rated_today', r.rated_today);
    end if;
  end loop;
  if cardinality(p_ciftler) > 0 then
    insert into sticky.rated_pairs (pair) select unnest(p_ciftler);
  end if;
  return sonuc;
end $$;

-- ---------------------------------------------------------------- ST-2

-- Dönem başlangıcı (İstanbul): gün, hafta (pazartesi), ay; 'tum' için null. accounts.ts periodStart ile aynı.
create function sticky.donem_baslangici(p_donem text) returns timestamptz
language sql stable set search_path = '' as $$
  select case p_donem
    when 'gun' then date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'
    when 'hafta' then date_trunc('week', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'
    when 'ay' then date_trunc('month', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'
    else null end
$$;

-- accounts.ts ranking ile aynı: tüm zamanlar = rating (en az 10 puanlı oyun); gün/hafta/ay = dönemde kazanılan
-- rating toplamı (en az 3/5/10 oyun). Sıra: değer azalan, sonra oyun sayısı azalan. Yalnız adı olan oyuncular.
-- Dönüş: { toplam, ben: { sira, deger, oyun } | null, satirlar: [{ sira, ad, deger, oyun, ben }] }; kimlik dönmez.
create function sticky.siralama(p_donem text, p_ilk int default 100, p_baslangic timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  bas timestamptz := coalesce(p_baslangic, sticky.donem_baslangici(p_donem));
  en_az int := case p_donem when 'gun' then 3 when 'hafta' then 5 when 'ay' then 10 else 10 end;
  ben uuid := auth.uid();
  r jsonb;
begin
  if p_donem not in ('gun', 'hafta', 'ay', 'tum') then raise exception 'donem_gecersiz'; end if;
  p_ilk := least(greatest(p_ilk, 1), 500);
  with s as (
    select x.user_id, x.deger, x.oyun, o.ad
    from (
      select st.user_id, st.rating::numeric as deger, st.rated_games as oyun
      from sticky.stats st where p_donem = 'tum' and st.rated_games >= en_az
      union all
      select l.user_id, sum(l.delta)::numeric, count(*)::int
      from sticky.rating_log l where p_donem <> 'tum' and l.at >= bas
      group by l.user_id having count(*) >= en_az
    ) x
    join ortak.oyuncular o on o.oyun_id = 'sticky' and o.kullanici_id = x.user_id and o.ad is not null
  ),
  sirali as (select s.*, row_number() over (order by deger desc, oyun desc) as sira from s)
  select jsonb_build_object(
    'toplam', (select count(*) from sirali),
    'ben', (select jsonb_build_object('sira', sira, 'deger', deger, 'oyun', oyun) from sirali where user_id = ben),
    'satirlar', coalesce((select jsonb_agg(jsonb_build_object('sira', sira, 'ad', ad, 'deger', deger, 'oyun', oyun,
                                                              'ben', coalesce(user_id = ben, false)) order by sira)
                          from sirali where sira <= p_ilk), '[]'::jsonb))
  into r;
  return r;
end $$;

-- Haftalık ödül (kapanış pazartesi 00:00 İstanbul): biten haftanın sıralamasında ilk 10'a rozet, ilk 3'e o haftanın
-- kart arkası. Kimlikler hafta başlangıcını taşır (ödül tablosunda aynı kimlik bir kez yazılabilir):
-- sira:hafta-ilk10:YYYY-MM-DD, sira:hafta-ilk3:YYYY-MM-DD. Tekrar çağrılması zararsız.
create function sticky.haftalik_odul(p_hafta date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  hafta date := coalesce(p_hafta, (date_trunc('week', now() at time zone 'Europe/Istanbul') - interval '7 days')::date);
  bas timestamptz := hafta::timestamp at time zone 'Europe/Istanbul';
  bit timestamptz := (hafta + 7)::timestamp at time zone 'Europe/Istanbul';
  n integer;
begin
  with s as (
    select l.user_id, row_number() over (order by sum(l.delta) desc, count(*) desc) as sira
    from sticky.rating_log l
    join ortak.oyuncular o on o.oyun_id = 'sticky' and o.kullanici_id = l.user_id and o.ad is not null
    where l.at >= bas and l.at < bit
    group by l.user_id having count(*) >= 5
  )
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak)
    select 'sticky', user_id, 'sira:hafta-ilk10:' || hafta, 'hafta:' || hafta from s where sira <= 10
    union all
    select 'sticky', user_id, 'sira:hafta-ilk3:' || hafta, 'hafta:' || hafta from s where sira <= 3
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- ST-3 (oyuna özgü)

create table sticky.follows (
  user_id uuid not null references auth.users on delete cascade,
  follows_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, follows_id),
  check (user_id <> follows_id)
);
create index follows_takip_edilen on sticky.follows (follows_id);
alter table sticky.follows enable row level security;

-- Dönüş: ok | zaten | bulunamadi | kendin | sinir (en çok 100). Ad, ortak.oyuncular('sticky') adıdır.
create function sticky.takip_et(p_kullanici uuid, p_ad text) returns text
language plpgsql security definer set search_path = '' as $$
declare hedef uuid;
begin
  select kullanici_id into hedef from ortak.oyuncular
    where oyun_id = 'sticky' and ad_anahtari = ortak.ad_anahtari(p_ad);
  if hedef is null then return 'bulunamadi'; end if;
  if hedef = p_kullanici then return 'kendin'; end if;
  perform pg_advisory_xact_lock(hashtextextended('takip:' || p_kullanici::text, 0));
  if exists (select 1 from sticky.follows where user_id = p_kullanici and follows_id = hedef) then return 'zaten'; end if;
  if (select count(*) from sticky.follows where user_id = p_kullanici) >= 100 then return 'sinir'; end if;
  insert into sticky.follows (user_id, follows_id) values (p_kullanici, hedef);
  return 'ok';
end $$;

create function sticky.takibi_birak(p_kullanici uuid, p_ad text) returns void
language sql security definer set search_path = '' as $$
  delete from sticky.follows f using ortak.oyuncular o
  where f.user_id = p_kullanici and f.follows_id = o.kullanici_id
    and o.oyun_id = 'sticky' and o.ad_anahtari = ortak.ad_anahtari(p_ad)
$$;

-- Servis için: takip edilenlerin kimliği (çevrimiçi durumu sunucu bilir) ve adı.
create function sticky.takip_ettiklerim(p_kullanici uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.follows_id, 'ad', o.ad) order by o.ad_anahtari), '[]')
  from sticky.follows f
  join ortak.oyuncular o on o.oyun_id = 'sticky' and o.kullanici_id = f.follows_id and o.ad is not null
  where f.user_id = p_kullanici
$$;

-- ---------------------------------------------------------------- silme ve zamanlanmış işler

-- "Bu oyundaki verimi sil": istatistik, rating günlüğü, ikili sayaçlar (anahtar kimliği içerir), takipler.
create function sticky.oyuncu_verisini_sil(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from sticky.stats where user_id = u;
  delete from sticky.rating_log where user_id = u;
  delete from sticky.rated_pairs where position(u::text in pair) > 0;
  delete from sticky.follows where user_id = u or follows_id = u;
end $$;

select cron.schedule('sticky-haftalik-odul', '1 21 * * 0', $$select sticky.haftalik_odul()$$);  -- pazartesi 00:01 İstanbul
select cron.schedule('sticky-temizlik', '15 3 * * *', $$
  delete from sticky.rated_pairs where at < now() - interval '2 days';
  delete from sticky.rating_log where at < now() - interval '40 days';
$$);

revoke execute on all functions in schema sticky from public, anon, authenticated;
grant execute on function sticky.siralama(text, int, timestamptz) to anon, authenticated;
