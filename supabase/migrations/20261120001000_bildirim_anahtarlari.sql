-- ST-8 (Sticky Ten, 2026-11-14): cihaz bildirim anahtarlarının (FCM/APNs) kalıcı saklanması. Bütün oyunlar kullanabilir.
-- Uygulama kalıcı hesaplı oyuncunun anahtarını yazar (girişte, açılışta) ve çıkışta siler; oyun sunucusu servis rolüyle
-- bir kullanıcı listesinin anahtarlarını okur ve geçersiz (410/UNREGISTERED) anahtarı siler. Hesap silinince (auth.users
-- cascade) ve "bu oyundan sil"de satırlar kalkar. Anahtar cihaza aittir: aynı anahtar başka hesapla yazılırsa o hesaba geçer.

create table ortak.bildirim_anahtarlari (
  oyun_id text not null references ortak.oyunlar (id) on delete cascade,
  anahtar text not null check (char_length(anahtar) between 20 and 4096),
  kullanici_id uuid not null references auth.users (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios')),
  dil text not null default 'tr' check (dil ~ '^[a-z]{2}$'),
  son_gorulme timestamptz not null default now(),
  primary key (oyun_id, anahtar)
);
create index bildirim_anahtarlari_kullanici on ortak.bildirim_anahtarlari (oyun_id, kullanici_id);
alter table ortak.bildirim_anahtarlari enable row level security;
-- Politika yok: istemci tabloya doğrudan erişemez; yalnız aşağıdaki işlevler ve servis rolü.

-- Anahtarı yazar ya da tazeler. Kullanıcı başına oyun başına en çok 10 cihaz: fazlası en eskiden silinir.
create function ortak.bildirim_anahtari_yaz(p_oyun text, p_platform text, p_anahtar text, p_dil text default 'tr')
returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid := ortak.kim();
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  if not ortak.hiz_siniri('bildirim:' || u, 20, 3600) then raise exception 'cok_istek' using errcode = '54000'; end if;
  insert into ortak.bildirim_anahtarlari as b (oyun_id, anahtar, kullanici_id, platform, dil, son_gorulme)
    values (p_oyun, p_anahtar, u, p_platform, coalesce(p_dil, 'tr'), now())
    on conflict (oyun_id, anahtar) do update
      set kullanici_id = excluded.kullanici_id, platform = excluded.platform, dil = excluded.dil, son_gorulme = now();
  delete from ortak.bildirim_anahtarlari b
    where b.oyun_id = p_oyun and b.kullanici_id = u
      and b.anahtar not in (select x.anahtar from ortak.bildirim_anahtarlari x
                            where x.oyun_id = p_oyun and x.kullanici_id = u
                            order by x.son_gorulme desc limit 10);
end $$;

-- Çıkışta ya da bildirim kapatılınca: yalnız kendi anahtarını siler.
create function ortak.bildirim_anahtari_sil(p_oyun text, p_anahtar text) returns void
language sql security definer set search_path = '' as $$
  delete from ortak.bildirim_anahtarlari where oyun_id = p_oyun and anahtar = p_anahtar and kullanici_id = ortak.kim();
$$;

revoke execute on function ortak.bildirim_anahtari_yaz(text, text, text, text), ortak.bildirim_anahtari_sil(text, text) from public, anon;
grant execute on function ortak.bildirim_anahtari_yaz(text, text, text, text), ortak.bildirim_anahtari_sil(text, text) to authenticated;

-- "Bu oyundan sil" bildirim anahtarlarını da siler.
create or replace function ortak.oyun_verisini_sil_ek(p_oyun text, u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from ortak.skorlar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.denemeler where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.lig_uyeleri where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.oduller where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.haklar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.sikayetler where oyun_id = p_oyun and (sikayet_eden = u or hedef = u);
  delete from ortak.bildirim_anahtarlari where oyun_id = p_oyun and kullanici_id = u;
end $$;
