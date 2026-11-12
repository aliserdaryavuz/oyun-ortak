import { test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo, cihazKimligi, kayitDeposu, testKodu, type Depo } from "./index.ts";

type Oyun = { seviye: number };
const ayar = (depo: Depo, ek: Partial<Parameters<typeof kayitDeposu<Oyun>>[0]> = {}) =>
  kayitDeposu<Oyun>({ depo, anahtar: "k", surum: 2, bos: () => ({ seviye: 0 }), ...ek });

test("ilk açılış yeni; yazılan geri okunur", async () => {
  const d = bellekDepo();
  const k = ayar(d);
  assert.deepEqual(await k.ac(), { veri: { seviye: 0 }, durum: "yeni" });
  assert.equal(await k.yaz({ seviye: 3 }), true);
  assert.deepEqual(await ayar(d).ac(), { veri: { seviye: 3 }, durum: "ana" });
});

test("ikinci yazımda önceki sağlam kayıt yedeğe gider", async () => {
  const d = bellekDepo();
  const k = ayar(d);
  await k.ac();
  await k.yaz({ seviye: 1 });
  await k.yaz({ seviye: 2 });
  assert.equal(JSON.parse(d.veri.get("k:yedek")!).v.seviye, 1);
});

test("bozuk ana kayıt yedekten açılır, sonraki yazım yedeği bozmaz", async () => {
  const d = bellekDepo();
  const k = ayar(d);
  await k.ac();
  await k.yaz({ seviye: 1 });
  await k.yaz({ seviye: 2 });
  d.veri.set("k", '{"s":2,"v":{"sev'); // yarım yazım
  const k2 = ayar(d);
  assert.deepEqual(await k2.ac(), { veri: { seviye: 1 }, durum: "yedek" });
  await k2.yaz({ seviye: 5 });
  assert.equal(JSON.parse(d.veri.get("k:yedek")!).v.seviye, 1);
  assert.equal(JSON.parse(d.veri.get("k")!).v.seviye, 5);
});

test("ikisi de bozuksa ham veri korunur, durum bozuk", async () => {
  const d = bellekDepo({ k: "{{", "k:yedek": "çöp" });
  const r = await ayar(d).ac();
  assert.equal(r.durum, "bozuk");
  assert.deepEqual(JSON.parse(d.veri.get("k:bozuk")!).ana, "{{");
  // ikinci bozuk açılış ilk kurtarma kopyasını ezmez
  d.veri.set("k", "başka");
  await ayar(d).ac();
  assert.equal(JSON.parse(d.veri.get("k:bozuk")!).ana, "{{");
});

test("dolu depo: yaz false döner, eski kayıt yerinde kalır", async () => {
  const d = bellekDepo();
  const k = ayar(d);
  await k.ac();
  await k.yaz({ seviye: 4 });
  const dolu: Depo = { ...d, yaz: async () => { throw new Error("QuotaExceeded"); } };
  const k2 = ayar(dolu);
  await k2.ac();
  assert.equal(await k2.yaz({ seviye: 9 }), false);
  assert.equal(JSON.parse(d.veri.get("k")!).v.seviye, 4);
});

test("depo hiç yok: açılır, yazım false", async () => {
  const yok: Depo = {
    oku: async () => { throw new Error("SecurityError"); },
    yaz: async () => { throw new Error("SecurityError"); },
    sil: async () => { throw new Error("SecurityError"); },
  };
  const k = ayar(yok);
  assert.equal((await k.ac()).durum, "yeni");
  assert.equal(await k.yaz({ seviye: 1 }), false);
});

test("sürüm göçü ve geçersiz biçim", async () => {
  const d = bellekDepo({ k: JSON.stringify({ s: 1, v: { lv: 7 }, t: 0 }) });
  const k = ayar(d, { goc: (v, s) => (s === 1 ? { seviye: (v as { lv: number }).lv } : (undefined as never)) });
  assert.deepEqual(await k.ac(), { veri: { seviye: 7 }, durum: "ana" });
  const d2 = bellekDepo({ k: JSON.stringify({ s: 2, v: { seviye: "x" }, t: 0 }) });
  const k2 = ayar(d2, { gecerli: (v) => typeof (v as Oyun).seviye === "number" });
  assert.equal((await k2.ac()).durum, "bozuk");
});

test("gelecek sürümün kaydına dokunulmaz", async () => {
  const ham = JSON.stringify({ s: 3, v: { seviye: 1 }, t: 0 });
  const d = bellekDepo({ k: ham });
  assert.equal((await ayar(d).ac()).durum, "bozuk");
  assert.equal(d.veri.get("k"), ham);
});

test("eski anahtardan bir kez içe alma; eski anahtar kalır", async () => {
  const d = bellekDepo({ "halka-kelime:v1": '{"2026-11-01":{"solved":true}}' });
  let cagri = 0;
  const iceAl = {
    anahtar: "halka-kelime:v1",
    donustur: (ham: string) => (cagri++, { seviye: Object.keys(JSON.parse(ham)).length }),
  };
  assert.deepEqual(await ayar(d, { iceAl }).ac(), { veri: { seviye: 1 }, durum: "ice-alindi" });
  assert.deepEqual(await ayar(d, { iceAl }).ac(), { veri: { seviye: 1 }, durum: "ana" });
  assert.equal(cagri, 1);
  assert.ok(d.veri.has("halka-kelime:v1"));
});

test("bozuk eski kayıt içe alınmaz", async () => {
  const d = bellekDepo({ eski: "{{" });
  const r = await ayar(d, { iceAl: { anahtar: "eski", donustur: (h) => JSON.parse(h) } }).ac();
  assert.equal(r.durum, "yeni");
});

test("temizle her şeyi siler", async () => {
  const d = bellekDepo();
  const k = ayar(d);
  await k.ac();
  await k.yaz({ seviye: 1 });
  await k.yaz({ seviye: 2 });
  await k.temizle();
  assert.equal(d.veri.size, 0);
});

test("cihaz kimliği kalıcı; test kodu eklenir ve korunur", async () => {
  const d = bellekDepo();
  const a = await cihazKimligi(d);
  assert.equal(await cihazKimligi(d), a);
  const t = await cihazKimligi(d, "Grup-1!");
  assert.equal(t, `t-grup1-${a}`);
  assert.equal(testKodu(t), "grup1");
  assert.equal(await cihazKimligi(d), t);
  assert.equal(testKodu(a), null);
});
