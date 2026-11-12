import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { siralamaBaslat } from "../../src/siralama/index.ts";
import { bugun, fonksiyon, istemci, oyunuTemizle, sql } from "./yardimci.ts";

before(() => oyunuTemizle());
after(() => sql.end());

const oyuncu = async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const id = await h.anonimGir();
  return { c, h, id };
};

/** SQL ile sahte oyuncu (auth.users satırı) ve doğrudan skor. */
async function sahteSkor(donem: string, puan: number, ikincil = 1) {
  const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous) values (gen_random_uuid(), 'authenticated', 'authenticated', true) returning id`;
  await sql`select ortak.skor_yaz('deneme', ${id}, 'gunluk', ${donem}, ${puan}, gen_random_uuid(), ${ikincil})`;
  return id as string;
}

const gunluk = (kayit: number[], ek: Record<string, unknown> = {}) => ({
  islem: "gunluk", gun: bugun(), kayit, kuralSurumu: 1, runId: crypto.randomUUID(), ...ek,
});

test("günlük gönderim: puanı sunucu hesaplar; aynı runId tek skor; ikinci gönderim prova", async () => {
  const { c } = await oyuncu();
  const g = gunluk([9, 9, 1]);
  const r1 = await fonksiyon(c, "dogrula-deneme", { ...g, puan: 999 });
  assert.equal(r1.durum, 200);
  assert.equal(r1.veri.durum, "yeni");
  assert.equal(r1.veri.puan, 19);
  const r2 = await fonksiyon(c, "dogrula-deneme", g);
  assert.equal(r2.veri.durum, "tekrar");
  const r3 = await fonksiyon(c, "dogrula-deneme", gunluk([1]));
  assert.equal(r3.veri.durum, "prova");
});

test("ret: gelecek gün, sürüm, biçim, oturum, gövde", async () => {
  const { c } = await oyuncu();
  const yarin = new Date(Date.now() + 86_400_000).toLocaleDateString("en-CA", { timeZone: "Europe/Istanbul" });
  const durum = async (g: unknown, cc: typeof c | null = c) => (await fonksiyon(cc, "dogrula-deneme", g)).durum;
  assert.equal(await durum(gunluk([1], { gun: yarin })), 409);
  assert.equal(await durum(gunluk([1], { gun: "2020-01-01" })), 409);
  assert.equal(await durum(gunluk([1], { kuralSurumu: 0 })), 426);
  assert.equal(await durum(gunluk([10])), 400);
  assert.equal(await durum(gunluk([])), 400);
  assert.equal(await durum(gunluk([1], { runId: "x" })), 400);
  assert.equal(await durum("{bozuk"), 400);
  assert.equal(await durum({ islem: "gunluk", gun: bugun(), kayit: [1], kuralSurumu: 1, runId: crypto.randomUUID(), dolgu: "x".repeat(70_000) }), 413);
  assert.equal(await durum(gunluk([1]), null), 401);
});

test("durum tutan deneme: sıra, yeniden gönderim, eş zamanlı yarış, bitiş", async () => {
  const { c } = await oyuncu();
  const olay = (sira: number, o: number) => fonksiyon(c, "dogrula-deneme", { islem: "olay", gun: bugun(), sira, olay: o });
  assert.equal((await olay(0, 4)).veri.durum, "devam");
  assert.equal((await olay(0, 4)).veri.durum, "tekrar"); // aynı olay ikinci kez: tek sayılır
  assert.equal((await olay(5, 1)).durum, 409);
  const [a, b] = await Promise.all([olay(1, 7), olay(1, 8)]);
  assert.deepEqual([a.durum, b.durum].sort(), [200, 409]);
  const son = await olay(2, -1);
  assert.equal(son.veri.durum, "yeni");
  assert.ok(son.veri.puan === 11 || son.veri.puan === 12);
  assert.equal((await olay(3, 1)).durum, 409); // bitmiş deneme yeniden açılmaz
});

test("istek sınırı: kullanıcı başına dakikada 30", async () => {
  const { c } = await oyuncu();
  const durumlar: number[] = [];
  for (let i = 0; i < 31; i++) durumlar.push((await fonksiyon(c, "dogrula-deneme", { islem: "yok", gun: bugun() })).durum);
  assert.equal(durumlar.filter((d) => d === 429).length, 1);
  assert.equal(durumlar.at(-1), 429);
});

test("gönderim kuyruğu: ağ yokken bekler, ağ gelince gider", async () => {
  const depo = bellekDepo();
  const olu = createClient("http://127.0.0.1:9", "x", { auth: { persistSession: false } });
  const s1 = siralamaBaslat({ supabase: olu, oyunId: "deneme", depo });
  const r = await s1.gonder(gunluk([3, 3]));
  assert.equal(r.bekliyor, true);
  assert.equal(await s1.bekleyenSayisi(), 1);

  const { c } = await oyuncu();
  const s2 = siralamaBaslat({ supabase: c, oyunId: "deneme", depo });
  const sonuc = await s2.bosalt();
  assert.equal(sonuc[0]!.durum, 200);
  assert.equal((sonuc[0]!.veri as { puan: number }).puan, 6);
  assert.equal(await s2.bekleyenSayisi(), 0);

  // kalıcı ret kuyruktan düşer
  const r2 = await s2.gonder(gunluk([1], { kuralSurumu: 99 }));
  assert.deepEqual([r2.durum, r2.bekliyor], [426, false]);
  assert.equal(await s2.bekleyenSayisi(), 0);
});

test("tablo: eşit puana aynı sıra, ilk N + çevre, 50 altında yüzdelik yok", async () => {
  const donem = "2026-01-05";
  await sahteSkor(donem, 50);
  await sahteSkor(donem, 50);
  for (let i = 0; i < 6; i++) await sahteSkor(donem, 40 - i);
  const { c, id } = await oyuncu();
  await sql`select ortak.skor_yaz('deneme', ${id}, 'gunluk', ${donem}, 1, gen_random_uuid(), 1)`;
  for (let i = 0; i < 3; i++) await sahteSkor(donem, 0);

  const s = siralamaBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const t = await s.tablo("gunluk", donem, { ilk: 2, cevre: 1 });
  assert.equal(t.toplam, 12);
  assert.deepEqual(t.satirlar.slice(0, 2).map((x) => x.sira), [1, 1]);
  assert.deepEqual(t.satirlar.map((x) => x.puan), [50, 50, 35, 1, 0]);
  assert.deepEqual(t.ben, { sira: 9, ust_yuzde: null });
  assert.equal(t.satirlar.filter((x) => x.ben).length, 1);
  assert.ok(t.satirlar.every((x) => !("kullanici_id" in x)));

  for (let i = 0; i < 40; i++) await sahteSkor(donem, 100);
  const t2 = await s.tablo("gunluk", donem);
  assert.equal(t2.ben?.ust_yuzde, Math.ceil((100 * 49) / 52));
});
