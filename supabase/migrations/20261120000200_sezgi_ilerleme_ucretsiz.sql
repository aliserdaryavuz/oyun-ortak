-- BG-2 (Beat Greedy, K105 adalet kuralı): İlerleme tablosu yalnız ücretsiz bölümleri (1–4, seviye kodu < 4000) sayar.
-- Tam sürüm (Bölüm 5–8) sıralamada üstünlük vermez. Usta'da 3 yıldız (master3, kod 7000+) bu süzgeçte hep 0 olacağı
-- için eşitlik bozucudan çıkarıldı; sütun, istemci aynı sütunları okuduğu için 0 olarak kalır.
-- Sıra: ücretsiz bölümlerdeki ham yıldız, sonra bu toplama ilk ulaşma.

create or replace view sezgi.board_levels as
with t as (
  select user_id, coalesce(game, 'all') as game, sum(raw_stars)::int as stars,
         0 as master3,
         max(verified_at) as reached_at
  from sezgi.level_verified
  where level < 4000
  group by grouping sets ((user_id, game), (user_id))
)
select t.game, t.user_id, pr.username, pr.avatar, t.stars, t.master3, t.reached_at,
       rank() over (partition by t.game order by t.stars desc, t.reached_at asc) as rank
from t join sezgi.profiles pr on pr.id = t.user_id
where t.stars > 0;
