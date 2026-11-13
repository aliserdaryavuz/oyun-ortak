-- HK-12 düzeltmesi (güvenlik incelemesi, orta): istek sınırı istemcinin yazabildiği IP başlığına (x-forwarded-for)
-- dayanıyordu; her istekte farklı değerle aşılabilir ve hamle kontrolüyle günün cevabı kaba kuvvetle bulunabilirdi.
-- Artık IP'ye güvenilmez: günlük işlevleri oturum ister (anonim oturum yeter; Supabase anonim girişi IP başına
-- kendisi sınırlar) ve sınır oturum kimliğine göre sayılır. Halka istemcisi günlükte anonim oturum açar.
create or replace function halka.gunluk_sinir() returns void
language plpgsql set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then
    raise exception 'oturum_gerekli' using errcode = '28000';
  end if;
  if not ortak.hiz_siniri('halka-gunluk:' || u, 300, 60) then
    raise exception 'cok_istek' using errcode = '54000';
  end if;
end $$;
revoke execute on function halka.gunluk_sinir() from public, anon, authenticated;
