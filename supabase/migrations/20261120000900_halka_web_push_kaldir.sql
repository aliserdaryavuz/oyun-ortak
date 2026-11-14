-- Halka Web Push kaldırıldı (Serdar'ın kararı, 2026-11-14, seçenek A; Halka docs/BILDIRIM.md).
-- Günlük hatırlatma artık yalnız mağaza uygulamasında, cihazın yerel bildirimiyle (@oyun/ortak/bildirim); sunucu gerekmez.
-- Kalkanlar: abonelik tablosu public.hk_push ve hk_push_* işlevleri; varsa saatlik gönderim işi (pg_cron).

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname ilike 'hk-push%' or command ilike '%hk-push%';
  end if;
end $$;

drop function if exists public.hk_push_claim(int, date);
drop function if exists public.hk_push_save(text, text, text, int);
drop function if exists public.hk_push_remove(text);
drop table if exists public.hk_push;
drop function if exists public.hk_push_host_ok(text);
