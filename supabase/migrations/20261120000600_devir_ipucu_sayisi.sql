-- Güvenlik incelemesi (Halka, 2026-11-14, ORTA): hesap devrinde çakışan denemenin ipuçları `jsonb_agg(distinct x)`
-- ile birleşiyordu; Halka ipucunu türüne göre sayar (dogrula-halka kural.ts), 5 kilit + 1 tema ipucu 2'ye düşüyordu
-- (120 sn eksik ceza; günlük sıralama ve Usta Turnuvası). Şimdi her öğe greatest(hedefteki sayı, eskideki sayı) kez.
-- Tekrarsız listelerde sonuç öncekiyle aynıdır.

create or replace function ortak.devir_her_zaman(eski uuid, yeni uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into ortak.haklar (oyun_id, kullanici_id, hak, durum, kaynak, urun, dis_id)
    select oyun_id, yeni, hak, durum, kaynak, urun, dis_id from ortak.haklar where kullanici_id = eski
    on conflict (oyun_id, kullanici_id, hak) do update
      set durum = case when ortak.haklar.durum = 'aktif' or excluded.durum = 'aktif' then 'aktif' else 'iade' end;
  insert into ortak.oduller (oyun_id, kullanici_id, odul, kaynak, kazanildi)
    select oyun_id, yeni, odul, kaynak, kazanildi from ortak.oduller where kullanici_id = eski
    on conflict do nothing;
  insert into ortak.sikayetler (oyun_id, sikayet_eden, hedef, neden, hedef_ad, olusturma)
    select oyun_id, sikayet_eden, yeni, neden, hedef_ad, olusturma from ortak.sikayetler
    where hedef = eski and sikayet_eden <> yeni
    on conflict do nothing;

  -- Çakışan denemeler: hedefin durumu kalır; erken başlangıç ve ipuçlarının çoklu küme birleşimi.
  update ortak.denemeler y set
    olusturma = least(y.olusturma, e.olusturma),
    durum = case
      when jsonb_typeof(e.durum -> 'ipuclari') = 'array' then
        y.durum || jsonb_build_object('ipuclari', (
          -- Her öğe iki listeden hangisinde daha çok geçiyorsa o kadar tekrarlanır (çoklu küme birleşimi):
          -- ipucunu türüne göre sayan oyunlarda (Halka) sayı düşmez, iki cihazdaki aynı ipucu da iki kez sayılmaz.
          select coalesce(jsonb_agg(s.x order by s.x, s.n), '[]'::jsonb)
          from (
            select t.x, generate_series(1, greatest(count(*) filter (where t.k = 'y'), count(*) filter (where t.k = 'e'))::int) as n
            from (
              select 'y' as k, a.x from jsonb_array_elements(
                case when jsonb_typeof(y.durum -> 'ipuclari') = 'array' then y.durum -> 'ipuclari' else '[]'::jsonb end) a(x)
              union all
              select 'e', b.x from jsonb_array_elements(e.durum -> 'ipuclari') b(x)
            ) t
            group by t.x
          ) s))
      else y.durum end,
    guncelleme = now()
  from ortak.denemeler e
  where e.kullanici_id = eski and y.kullanici_id = yeni and y.oyun_id = e.oyun_id and y.anahtar = e.anahtar;

  -- Çakışmayan denemeler: yalnız ceza bilgisi (ipuçları, başlangıç, bitti); oyun durumu taşınmaz.
  insert into ortak.denemeler (oyun_id, kullanici_id, anahtar, sira, durum, bitti, olusturma, guncelleme)
    select e.oyun_id, yeni, e.anahtar, 0,
           case when jsonb_typeof(e.durum -> 'ipuclari') = 'array'
                then jsonb_build_object('ipuclari', e.durum -> 'ipuclari') else '{}'::jsonb end,
           e.bitti, e.olusturma, now()
    from ortak.denemeler e where e.kullanici_id = eski
    on conflict (oyun_id, kullanici_id, anahtar) do nothing;
end $$;
