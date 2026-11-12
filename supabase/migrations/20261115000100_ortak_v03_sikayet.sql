-- oyun-ortak v0.3: şikâyet (KH-5; koz-hesabi ve sifre-burosu deseni).
--
-- Oyuncu başka bir oyuncuyu sıralamada gördüğü adıyla şikâyet eder (kimlik istemciye hiç verilmez).
-- 'ad' şikâyeti: farklı kalıcı hesaplardan gelen şikâyet sayısı eşiğe (ayarlar.sikayet.ad_esigi, varsayılan 3)
-- ulaşınca oyuncunun adı sıfırlanır. Sıralama ve lig adsız oyuncuyu "Oyuncu" diye gösterir; oyuncu hemen yeni ad
-- seçebilir (30 gün sınırı sıfırlanır). 'hile' ve 'diger' şikâyetleri yalnız inceleme için kaydedilir.
-- Anonim hesapların şikâyeti sayılmaz (anonim hesap bedava; yoksa tek kişi istediği adı sildirebilirdi).

create table ortak.sikayetler (
  oyun_id text not null references ortak.oyunlar on delete cascade,
  sikayet_eden uuid not null references auth.users on delete cascade,
  hedef uuid not null references auth.users on delete cascade,
  neden text not null check (neden in ('ad', 'hile', 'diger')),
  hedef_ad text,                     -- şikâyet anındaki ad (inceleme için)
  olusturma timestamptz not null default now(),
  primary key (oyun_id, sikayet_eden, hedef, neden)
);
create index sikayetler_hedef on ortak.sikayetler (oyun_id, hedef, neden);
alter table ortak.sikayetler enable row level security;

-- Dönüş: { durum: 'ok' | 'zaten' | 'bulunamadi' | 'kendin', ad_sifirlandi?: boolean }
create function ortak.sikayet_et(p_oyun text, p_ad text, p_neden text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid := ortak.kim();
  h ortak.oyuncular;
  esik int;
  sayi int;
begin
  if ortak.anonim() then raise exception 'kalici_hesap_gerekli'; end if;
  if p_neden not in ('ad', 'hile', 'diger') then raise exception 'neden_gecersiz'; end if;
  if not ortak.hiz_siniri('sikayet:' || u, 20, 86400) then raise exception 'cok_istek' using errcode = '54000'; end if;

  select * into h from ortak.oyuncular
    where oyun_id = p_oyun and ad_anahtari = ortak.ad_anahtari(p_ad) for update;
  if not found then return jsonb_build_object('durum', 'bulunamadi'); end if;
  if h.kullanici_id = u then return jsonb_build_object('durum', 'kendin'); end if;

  insert into ortak.sikayetler (oyun_id, sikayet_eden, hedef, neden, hedef_ad)
    values (p_oyun, u, h.kullanici_id, p_neden, h.ad)
    on conflict do nothing;
  if not found then return jsonb_build_object('durum', 'zaten'); end if;
  if p_neden <> 'ad' then return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', false); end if;

  select coalesce((ayarlar -> 'sikayet' ->> 'ad_esigi')::int, 3) into esik from ortak.oyunlar where id = p_oyun;
  select count(*) into sayi from ortak.sikayetler s join auth.users a on a.id = s.sikayet_eden
    where s.oyun_id = p_oyun and s.hedef = h.kullanici_id and s.neden = 'ad' and not a.is_anonymous;
  if sayi < esik then return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', false); end if;

  update ortak.oyuncular set ad = null, ad_anahtari = null, ad_otomatik = true, ad_degisti = null
    where oyun_id = p_oyun and kullanici_id = h.kullanici_id;
  -- Yeni ad temiz başlasın: bu oyuncunun 'ad' şikâyetleri silinir.
  delete from ortak.sikayetler where oyun_id = p_oyun and hedef = h.kullanici_id and neden = 'ad';
  return jsonb_build_object('durum', 'ok', 'ad_sifirlandi', true);
end $$;

-- "Bu oyundaki verimi sil" şikâyetleri de siler (şikâyet eden ve hedef olarak). v0.2 gövdesi + sikayetler.
create or replace function ortak.oyun_verisini_sil_ek(p_oyun text, u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from ortak.skorlar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.denemeler where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.lig_uyeleri where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.oduller where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.haklar where oyun_id = p_oyun and kullanici_id = u;
  delete from ortak.sikayetler where oyun_id = p_oyun and (sikayet_eden = u or hedef = u);
end $$;

revoke execute on all functions in schema ortak from public;
grant execute on function ortak.sikayet_et(text, text, text) to authenticated;
