-- HK-11 (ISTEKLER.md; Halka GECIS §1.4–1.5). Kaynak: halka-kelime/supabase/hk11_kimlik.sql (dal hk11-kimlik-kapat), testi tests/sql.test.ts "HK-11".

drop policy if exists "skor oku" on public.hk_daily_scores;
create policy "skor oku" on public.hk_daily_scores for select using (auth.uid() = user_id);
drop policy if exists "profil oku" on public.hk_profiles;
create policy "profil oku" on public.hk_profiles for select using (auth.uid() = id);

-- Sahibinin yetkisiyle çalışır (RLS'yi aşar), yalnız ad ve süre verir; oyuncu kendi satırını "me" ile tanır.
drop view if exists public.hk_leaderboard;
create view public.hk_leaderboard as
select s.date, coalesce(s.user_id = auth.uid(), false) as me, coalesce(p.name, 'Oyuncu') as name, s.seconds, s.hints, s.moves, s.rank_seconds,
       rank() over (partition by s.date order by s.rank_seconds, s.created_at) as place
from public.hk_daily_scores s left join public.hk_profiles p on p.id = s.user_id;
revoke all on public.hk_leaderboard from public, anon, authenticated;
grant select on public.hk_leaderboard to anon, authenticated;

revoke execute on function public.hk_load_puzzles(text, text) from public, anon, authenticated;
grant execute on function public.hk_load_puzzles(text, text) to service_role;
