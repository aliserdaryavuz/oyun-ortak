// Halka'nın ortak kaydı: ayarlar ortak paketlerde geçerli, "bu oyundan sil" hk_ tablolarını temizler.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { istemci, kaliciKullanici, sql } from "./yardimci.ts";

after(() => sql.end());

test("Halka ad kuralı (2–20) ve ilk bağlama ödülü", async () => {
  const k = await kaliciKullanici();
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "halka", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  assert.equal((await h.adDegistir("x".repeat(21))).durum, "bicim"); // 20'den uzun
  assert.notEqual((await h.adDegistir("Ay")).durum, "bicim"); // 2 karakter Halka'da geçerli (deneme oyununda 3)
  assert.equal(await h.baglamaOdulu(), "desen-porselen");
});

test("bu oyundan sil: hk_ tabloları temizlenir, hesap ve öbür oyunlar kalır", async () => {
  const k = await kaliciKullanici();
  await sql`insert into public.hk_profiles (id, name) values (${k.id}, ${"Silinecek" + Math.floor(Math.random() * 1e6)})`;
  await sql`insert into public.hk_level_progress (user_id, key, moves, hints, seconds) values (${k.id}, '1-1', 5, 0, 30)`;
  await sql`insert into public.hk_entitlements (user_id, product, source) values (${k.id}, 'paket_tam', 'manual')`;
  await sql`insert into ortak.oyuncular (oyun_id, kullanici_id) values ('deneme', ${k.id})`;
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "halka", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await h.ben();
  await h.buOyundanSil();
  const [r] = await sql`select
    (select count(*) from public.hk_profiles where id = ${k.id})::int
    + (select count(*) from public.hk_level_progress where user_id = ${k.id})::int
    + (select count(*) from public.hk_entitlements where user_id = ${k.id})::int as n,
    (select count(*) from ortak.oyuncular where kullanici_id = ${k.id} and oyun_id = 'deneme')::int as deneme,
    (select count(*) from auth.users where id = ${k.id})::int as hesap`;
  assert.deepEqual({ ...r }, { n: 0, deneme: 1, hesap: 1 });
});
