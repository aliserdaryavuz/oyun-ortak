import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { odemeBaslat } from "../../src/odeme/index.ts";
import { etkinlikBaslat } from "../../src/etkinlik/index.ts";
import { istemci, kaliciKullanici, rpc, sql, URL, yonetici } from "./yardimci.ts";

after(() => sql.end());

const SIR = "yerel-test-sirri"; // supabase/functions/.env (yalnız yerel ve CI)

const webhook = async (event: Record<string, unknown>, sir = SIR) => {
  const r = await fetch(`${URL}/functions/v1/odeme-webhook`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: sir },
    body: JSON.stringify({ api_version: "1.0", event }),
  });
  return { durum: r.status, veri: (await r.json()) as { sonuc?: string; error?: string } };
};
const satinAlma = (kullanici: string, ek: Record<string, unknown> = {}) => ({
  id: crypto.randomUUID(), type: "NON_RENEWING_PURCHASE", app_user_id: kullanici, product_id: "deneme_tam",
  store: "PLAY_STORE", transaction_id: "GPA.1234", expiration_at_ms: null, ...ek,
});

const oyuncu = async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const id = await h.anonimGir();
  return { c, h, id };
};
const haklarim = (c: ReturnType<typeof istemci>) => rpc<{ hak: string; durum: string }[]>(c, "haklarim", { p_oyun: "deneme" });

test("webhook: yanlış sır 401; TEST olayı; satın alma hakkı verir, aynı olay bir kez işlenir", async () => {
  const { c, id } = await oyuncu();
  assert.equal((await webhook(satinAlma(id), "yanlis")).durum, 401);
  assert.equal((await webhook({ id: "t1", type: "TEST" })).veri.sonuc, "test");
  const olay = satinAlma(id);
  assert.equal((await webhook(olay)).veri.sonuc, "ok");
  assert.equal((await webhook(olay)).veri.sonuc, "tekrar");
  assert.deepEqual(await haklarim(c), [{ hak: "tam", durum: "aktif" }]);
  assert.equal((await webhook(satinAlma(id, { product_id: "yok_urun" }))).veri.sonuc, "urun_yok");
  assert.equal((await webhook(satinAlma("$RCAnonymousID:abc"))).veri.sonuc, "kullanici_yok");
  // abonelik iptali (bitiş tarihi var) iade değildir
  assert.equal((await webhook(satinAlma(id, { type: "CANCELLATION", expiration_at_ms: Date.now() + 1e9 }))).veri.sonuc, "yok_sayildi");
});

test("iade: tek seferlik üründe CANCELLATION hakkı düşürür; istemci önbelleği de düşer", async () => {
  const { c, id } = await oyuncu();
  await webhook(satinAlma(id));
  const o = odemeBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  assert.deepEqual([...(await o.yenile())], ["tam"]);
  await webhook(satinAlma(id, { type: "CANCELLATION", cancel_reason: "CUSTOMER_SUPPORT" }));
  assert.deepEqual(await haklarim(c), [{ hak: "tam", durum: "iade" }]);
  assert.deepEqual([...(await o.yenile())], []);
});

test("TRANSFER: haklar yeni kimliğe geçer", async () => {
  const a = await oyuncu();
  const b = await oyuncu();
  await webhook(satinAlma(a.id));
  const r = await webhook({ id: crypto.randomUUID(), type: "TRANSFER", transferred_from: [a.id], transferred_to: [b.id] });
  assert.equal(r.veri.sonuc, "ok");
  assert.deepEqual(await haklarim(b.c), [{ hak: "tam", durum: "aktif" }]);
  assert.deepEqual(await haklarim(a.c), []);
});

test("korumalı içerik: yalnız hakkı olan indirir, başka oyunun yolu kapalı", async () => {
  const y = yonetici();
  const govde = new Blob([JSON.stringify({ seviye: 99 })], { type: "application/json" });
  for (const yol of ["deneme/tam/zor.json", "baska/tam/zor.json"]) {
    const { error } = await y.storage.from("korumali").upload(yol, govde, { upsert: true });
    assert.equal(error, null, yol);
  }
  const { c, id } = await oyuncu();
  const o = odemeBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  await assert.rejects(o.korumaliIndir("tam", "zor.json"));
  await webhook(satinAlma(id));
  assert.equal(JSON.parse(await (await o.korumaliIndir("tam", "zor.json")).text()).seviye, 99);
  const { error } = await c.storage.from("korumali").download("baska/tam/zor.json");
  assert.ok(error, "başka oyunun dosyası indirilebildi");
  assert.ok((await c.storage.from("korumali").upload("deneme/tam/x.json", govde)).error, "istemci yükleyebildi");
});

test("ödüller: ağsızken bekler, oturumla bir kez eşitlenir, başka cihaza gelir", async () => {
  const c = istemci();
  const e = etkinlikBaslat({ oyunId: "deneme", adres: "x", depo: bellekDepo(), dogrula: () => null, supabase: c });
  await e.odulKazan("rozet-ilk", "usta"); // oturum yok: yerelde bekler
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  await h.anonimGir();
  await e.esitle();
  await e.esitle();
  assert.deepEqual((await rpc<{ odul: string }[]>(c, "odullerim", { p_oyun: "deneme" })).map((x) => x.odul), ["rozet-ilk"]);
  // aynı hesap, başka cihaz
  const e2 = etkinlikBaslat({ oyunId: "deneme", adres: "x", depo: bellekDepo(), dogrula: () => null, supabase: c });
  await e2.esitle();
  assert.deepEqual((await e2.oduller()).map((x) => x.odul), ["rozet-ilk"]);
  // geçersiz kimlik ve gelecek tarih
  await assert.rejects(rpc(c, "odul_kaydet", { p_oyun: "deneme", p_oduller: [{ odul: "Büyük Harf" }] }));
  await rpc(c, "odul_kaydet", { p_oyun: "deneme", p_oduller: [{ odul: "gelecek", kazanildi: "2099-01-01T00:00:00Z" }] });
  const [g] = await sql`select kazanildi <= now() as ok from ortak.oduller where odul = 'gelecek' and oyun_id = 'deneme' limit 1`;
  assert.equal(g!.ok, true);
});

test("sıralama ödülü: etkinlik sıralamasında ilk %10 (en az 1), eşitler dahil", async () => {
  const donem = `etk-${crypto.randomUUID().slice(0, 8)}`;
  const idler: string[] = [];
  for (let i = 0; i < 20; i++) {
    const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous) values (gen_random_uuid(), 'authenticated', 'authenticated', true) returning id`;
    idler.push(id);
    const puan = i === 1 ? 100 : 100 - i; // ilk iki oyuncu eşit (100)
    await sql`select ortak.skor_yaz('deneme', ${id}, 'etkinlik', ${donem}, ${puan}, gen_random_uuid(), 1)`;
  }
  const [{ n }] = await sql`select ortak.siralama_odulu_ver('deneme', 'etkinlik', ${donem}, 'usta-rozeti', 0.1) as n`;
  assert.equal(n, 2);
  const alan = await sql`select kullanici_id from ortak.oduller where odul = 'usta-rozeti' and kaynak = ${"etkinlik:" + donem}`;
  assert.deepEqual(new Set(alan.map((r) => r.kullanici_id)), new Set([idler[0], idler[1]]));
});

test("devir: hak ve ödül var olan hesaba da taşınır; bu oyundan sil ikisini de siler", async () => {
  const k = await kaliciKullanici();
  const eski = istemci();
  const he = hesapBaslat({ supabase: eski, oyunId: "deneme", depo: bellekDepo() });
  await he.disGiris(() => eski.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await he.ben(); // hesap boş değil

  const { c, h, id } = await oyuncu();
  await webhook(satinAlma(id));
  await rpc(c, "odul_kaydet", { p_oyun: "deneme", p_oduller: [{ odul: "misafir-rozeti" }] });
  const r = await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  assert.equal(r.skorlarTasindi, false);
  assert.deepEqual(await haklarim(c), [{ hak: "tam", durum: "aktif" }]);
  assert.deepEqual((await rpc<{ odul: string }[]>(c, "odullerim", { p_oyun: "deneme" })).map((x) => x.odul), ["misafir-rozeti"]);

  await h.buOyundanSil();
  assert.deepEqual(await haklarim(c), []);
  assert.deepEqual(await rpc(c, "odullerim", { p_oyun: "deneme" }), []);
});
