import { after, test } from "node:test";
import assert from "node:assert/strict";
import { sql } from "./yardimci.ts";

after(() => sql.end());

/** İstemciye (anon / authenticated) açık olması gereken fonksiyonların tam listesi. Yeni RPC buraya bilerek eklenir. */
const IZINLI = {
  anon: ["ad_anahtari", "ad_bicimi", "ad_uygun", "bugun", "iso_hafta", "siralama"],
  authenticated: [
    "ad_anahtari", "ad_bicimi", "ad_degistir", "ad_uygun", "baglama_odulu_al", "ben", "bildirim_anahtari_sil",
    "bildirim_anahtari_yaz", "bugun", "devir_kodu_al",
    "hakki_var", "haklarim", "hesabi_sil", "hesap_devral", "hesap_ozeti", "iso_hafta", "kayit_oku", "kayit_yaz",
    "lig_durumu", "odul_kaydet", "odullerim", "otomatik_ad", "oyun_verisini_sil", "sikayet_et", "siralama", "yas_onayla",
  ],
};

for (const rol of ["anon", "authenticated"] as const) {
  test(`${rol}: ortak şemasında yalnız izin listesindeki fonksiyonlar çalıştırılabilir`, async () => {
    const satirlar = await sql`
      select distinct p.proname as ad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'ortak' and has_function_privilege(${rol}, p.oid, 'execute')
      order by 1`;
    assert.deepEqual(satirlar.map((r) => r.ad), IZINLI[rol]);
  });

  test(`${rol}: ortak tablolarından yalnız oyunlar ve urunler okunabilir, hiçbirine yazılamaz`, async () => {
    const satirlar = await sql`
      select c.relname as ad, has_table_privilege(${rol}, c.oid, 'select') as oku,
             has_table_privilege(${rol}, c.oid, 'insert,update,delete') as yaz
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'ortak' and c.relkind in ('r', 'v', 'm')`;
    for (const s of satirlar) {
      assert.equal(s.yaz, false, `${s.ad} yazılabilir`);
      assert.equal(s.oku, ["oyunlar", "urunler"].includes(s.ad), `${s.ad} okuma`);
    }
  });
}

test("her ortak tablosunda RLS açık", async () => {
  const kapali = await sql`
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'ortak' and c.relkind = 'r' and not c.relrowsecurity`;
  assert.deepEqual([...kapali], []);
});
