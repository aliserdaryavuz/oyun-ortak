-- "Bu oyundaki verimi sil" Beat Greedy'nin denemelerini de siler (profil → attempts zinciri). Hesap kimliği
-- aynı kaldığından oyuncu silip profilini yeniden açarak günün bulmacasını tekrar oynayabilirdi ("günde tek
-- deneme" kuralı). Silinen oyuncu aynı İstanbul günü içinde profil açamaz; kayıt yalnız kimlik ve zamandır,
-- 2 gün sonra silinir. İstek sınırı sayaçları silme yolunda sıfırlanmaz, kendi temizliğiyle sona erer.

create table sezgi.silinen_oyuncular (
  kullanici_id uuid primary key,
  silindi timestamptz not null default now()
);
alter table sezgi.silinen_oyuncular enable row level security;

create or replace function sezgi.oyuncu_verisini_sil(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from sezgi.leagues where owner_id = u) then
    raise exception 'owns_leagues' using errcode = 'P0001';
  end if;
  insert into sezgi.silinen_oyuncular (kullanici_id) values (u)
    on conflict (kullanici_id) do update set silindi = now();
  delete from sezgi.profiles where id = u;
end $$;

create function sezgi.ayni_gun_profil_engeli() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from sezgi.silinen_oyuncular s
             where s.kullanici_id = new.id
               and (s.silindi at time zone 'Europe/Istanbul')::date >= (now() at time zone 'Europe/Istanbul')::date) then
    raise exception 'ayni_gun_yeniden_profil' using errcode = 'P0001',
      hint = 'Beat Greedy verisi bugün silindi; profil yarın yeniden açılabilir.';
  end if;
  return new;
end $$;
create trigger ayni_gun_profil_engeli before insert on sezgi.profiles
  for each row execute function sezgi.ayni_gun_profil_engeli();

select cron.schedule('sezgi-silinen-temizle', '30 4 * * *',
  $$delete from sezgi.silinen_oyuncular where silindi < now() - interval '2 days'$$);

revoke execute on all functions in schema sezgi from public;
revoke execute on function sezgi.oyuncu_verisini_sil(uuid), sezgi.ayni_gun_profil_engeli() from anon, authenticated;
