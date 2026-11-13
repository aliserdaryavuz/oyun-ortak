-- BG-1 (Beat Greedy kademeli haftalık lig) ve ortak ligin iki eki:
--   a) ortak.gun_toplami_yaz: günün puanı gün içinde birikiyorsa (Beat Greedy: 10 oyunun toplamı) günlük skor ve lig puanı
--      güncellenebilir. Yalnız servis rolü (oyunun Edge Function'ı). skor_yaz'ın "ilk gönderim resmî" kuralı değişmedi.
--   b) Kademe ödülü sunucudan: ayarlar.lig.kademe_odulu = true ise haftalık kapanışta kademe atlayana
--      `sira:lig-<yeni kademe sırası>-<hafta başı>` yazılır. `sira:` öneki istemciye kapalı.
--   c) sezgi.profiles.username → ortak.oyuncular('sezgi').ad (tetikleyici); ortakta çakışan ad boş kalır.
--   d) Beat Greedy lig ayarları (Serdar onayı bekliyor; ayar JSON'undan değiştirilebilir).

-- ---------------------------------------------------------------- a) birikimli gün toplamı

create function ortak.gun_toplami_yaz(p_oyun text, p_kullanici uuid, p_gun text, p_toplam numeric, p_ikincil numeric default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_hafta date; v_puan numeric;
begin
  if p_gun !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'gun_gecersiz'; end if;
  if p_toplam < 0 then raise exception 'toplam_gecersiz'; end if;
  insert into ortak.oyuncular (oyun_id, kullanici_id) values (p_oyun, p_kullanici)
    on conflict (oyun_id, kullanici_id) do update set son_gorulme = now();
  insert into ortak.skorlar (oyun_id, kullanici_id, tur, donem, puan, ikincil, lig_puani, run_id)
    values (p_oyun, p_kullanici, 'gunluk', p_gun, p_toplam, p_ikincil, p_toplam, gen_random_uuid())
    on conflict (oyun_id, tur, donem, kullanici_id) do update
      set puan = excluded.puan, ikincil = excluded.ikincil, lig_puani = excluded.lig_puani;
  if exists (select 1 from ortak.oyunlar where id = p_oyun and ayarlar ? 'lig') then
    v_hafta := ortak.iso_hafta(p_gun::date);
    perform ortak.lig_ata(p_oyun, p_kullanici, v_hafta);
    perform ortak.lig_puani_guncelle(p_oyun, p_kullanici, v_hafta);
    select puan into v_puan from ortak.lig_uyeleri where oyun_id = p_oyun and hafta = v_hafta and kullanici_id = p_kullanici;
  end if;
  return jsonb_build_object('gun', p_gun, 'toplam', p_toplam, 'hafta_puani', v_puan);
end $$;

-- ---------------------------------------------------------------- b) kapanışta kademe ödülü

-- v0.1 gövdesi + kademe ödülü.
create or replace function ortak.lig_kapat() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  g ortak.lig_gruplari;
  a jsonb;
  ust int;
  kapanan int := 0;
begin
  for g in
    select * from ortak.lig_gruplari
    where not kapandi and hafta < ortak.iso_hafta(ortak.bugun())
    order by id for update skip locked
  loop
    select ayarlar -> 'lig' into a from ortak.oyunlar where id = g.oyun_id;
    ust := greatest(coalesce(jsonb_array_length(a -> 'kademeler'), 1) - 1, 0);

    with r as (
      select kullanici_id,
        rank() over (order by puan desc,
          case when coalesce(a ->> 'esitlik', 'ortak') = 'ikincil' then ikincil end asc nulls last) as sira
      from ortak.lig_uyeleri where grup_id = g.id and puan > 0
    ), sayi as (select count(*)::int as c from r)
    update ortak.lig_uyeleri u set
      sira = r.sira,
      sonuc = case
        when r.sira <= floor(sayi.c * coalesce((a ->> 'cikis_orani')::numeric, 0.2)) and g.kademe < ust then 'cikti'
        when r.sira > sayi.c - floor(sayi.c * coalesce((a ->> 'inis_orani')::numeric, 0.2)) and g.kademe > 0 then 'indi'
        else 'kaldi' end
    from r, sayi
    where u.grup_id = g.id and u.kullanici_id = r.kullanici_id;

    update ortak.lig_uyeleri set sonuc = 'kaldi' where grup_id = g.id and sonuc is null;

    update ortak.oyuncular o set kademe = o.kademe + case u.sonuc when 'cikti' then 1 else -1 end
    from ortak.lig_uyeleri u
    where u.grup_id = g.id and u.sonuc in ('cikti', 'indi')
      and o.oyun_id = g.oyun_id and o.kullanici_id = u.kullanici_id;

    if coalesce((a ->> 'kademe_odulu')::boolean, false) then
      insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak)
        select g.oyun_id, u.kullanici_id, 'sira:lig-' || (g.kademe + 1) || '-' || g.hafta, 'lig:' || g.hafta
        from ortak.lig_uyeleri u where u.grup_id = g.id and u.sonuc = 'cikti'
        on conflict do nothing;
    end if;

    update ortak.lig_gruplari set kapandi = true where id = g.id;
    kapanan := kapanan + 1;
  end loop;
  return kapanan;
end $$;

-- ---------------------------------------------------------------- c) sezgi kullanıcı adı → ortak ad

create function sezgi.ortak_ad_yansit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    insert into ortak.oyuncular (oyun_id, kullanici_id, ad, ad_anahtari, ad_otomatik, ad_degisti)
      values ('sezgi', new.id, new.username::text, ortak.ad_anahtari(new.username::text), false, null)
      on conflict (oyun_id, kullanici_id) do update
        set ad = excluded.ad, ad_anahtari = excluded.ad_anahtari, ad_otomatik = false, ad_degisti = null;
  exception when unique_violation then
    -- Ortakta Türkçe katlamayla çakışan ad (ör. "ali_1" / "ali1"): ortak ad boş kalır, profil kaydı yine olur.
    insert into ortak.oyuncular (oyun_id, kullanici_id) values ('sezgi', new.id)
      on conflict (oyun_id, kullanici_id) do update set ad = null, ad_anahtari = null;
  end;
  return new;
end $$;
create trigger ortak_ad_yansit after insert or update of username on sezgi.profiles
  for each row execute function sezgi.ortak_ad_yansit();

-- Var olan profiller (çakışan atlanır)
do $$ declare p record; begin
  for p in select id, username from sezgi.profiles loop
    begin
      insert into ortak.oyuncular (oyun_id, kullanici_id, ad, ad_anahtari, ad_otomatik)
        values ('sezgi', p.id, p.username::text, ortak.ad_anahtari(p.username::text), false)
        on conflict (oyun_id, kullanici_id) do update set ad = excluded.ad, ad_anahtari = excluded.ad_anahtari;
    exception when unique_violation then null;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------- d) Beat Greedy ayarları

update ortak.oyunlar set ayarlar = ayarlar
  || '{ "ad": { "en_az": 3, "en_cok": 20, "degistirme_gun": 30 } }'::jsonb
  || '{ "lig": { "kademeler": ["Bronz", "Gümüş", "Altın", "Elmas", "Efsane"], "grup_boyu": 30,
                 "cikis_orani": 0.2, "inis_orani": 0.2, "en_iyi_gun": 7, "esitlik": "ortak",
                 "bant_genisligi": 0, "kademe_odulu": true } }'::jsonb
where id = 'sezgi';

revoke execute on all functions in schema ortak from public;
revoke execute on function ortak.gun_toplami_yaz(text, uuid, text, numeric, numeric) from anon, authenticated;
revoke execute on all functions in schema sezgi from public;
revoke execute on function sezgi.ortak_ad_yansit() from anon, authenticated;
