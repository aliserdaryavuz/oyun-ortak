-- Ad süzgeci, ikinci düzeltme (güvenlik incelemesi): 20261119000000 baştaki ve sondaki bütün rakamları atıyordu;
-- bu, harf yerine yazılan rakamı da kaybettiriyordu ("5iktir", "0rospu" geçiyordu; "Naz1", "Go7" tam eşleşmeyi
-- atlatıyordu). Şimdi yalnız bir harften sonra gelen, sondaki iki ya da daha fazla rakamdan oluşan dizi (sayı eki:
-- "Işık156759", "Bekçi4821") atılır; tek rakam ve baştaki rakamlar eskisi gibi harfe çevrilir.

create or replace function ortak.ad_uygun(ad text, ek text[] default '{}') returns boolean
language sql stable set search_path = '' as $$
  with h as (
    select regexp_replace(
             translate(regexp_replace(ortak.ad_anahtari(ad), '([a-z])[0-9]{2,}$', '\1'), '013457', 'oieast'),
             '[^a-z]', '', 'g') as v
  )
  select not exists (
    select 1 from h, ortak.yasakli_sozler y
    where (y.tur = 'icerir' and position(y.soz in h.v) > 0) or (y.tur = 'tam' and h.v = y.soz)
  ) and not exists (
    select 1 from h, unnest(ek) e
    where length(e) > 0 and position(ortak.ad_anahtari(e) in h.v) > 0
  )
$$;

revoke execute on all functions in schema ortak from public;
grant execute on function ortak.ad_uygun(text, text[]) to anon, authenticated;
