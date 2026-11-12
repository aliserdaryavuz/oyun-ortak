import { test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../kayit/index.ts";
import { etkinlikBaslat, kalanSure, suren, yaklasan } from "./index.ts";

type Takvim = { etkinlikler: { id: string; baslangic: string; bitis: string }[] };
const dogrula = (h: unknown): Takvim | null => {
  const t = h as Takvim;
  if (!t || !Array.isArray(t.etkinlikler)) return null;
  // oyunun doğrulayıcısı geçmeyen kaydı atar (KM-8)
  return { etkinlikler: t.etkinlikler.filter((e) => typeof e.id === "string" && /^\d{4}-\d{2}-\d{2}$/.test(e.baslangic)) };
};
const yanit = (v: unknown) => (async () => new Response(JSON.stringify(v), { status: 200 })) as unknown as typeof fetch;
const agsiz = (async () => {
  throw new TypeError("Failed to fetch");
}) as unknown as typeof fetch;

test("takvim indirilir, geçersiz kayıt atılır, ağ yokken önbellekten gelir", async () => {
  const depo = bellekDepo();
  const ham = { etkinlikler: [{ id: "usta", baslangic: "2026-11-14", bitis: "2026-11-15" }, { id: 3, baslangic: "x" }] };
  const a = { oyunId: "deneme", adres: "https://x/t.json", depo, dogrula };
  assert.deepEqual((await etkinlikBaslat({ ...a, fetch: yanit(ham) }).takvim())?.etkinlikler.map((e) => e.id), ["usta"]);
  assert.deepEqual((await etkinlikBaslat({ ...a, fetch: agsiz }).takvim())?.etkinlikler.map((e) => e.id), ["usta"]);
  // bozuk yeni takvim eskisini ezmez
  assert.deepEqual((await etkinlikBaslat({ ...a, fetch: yanit({ yanlis: 1 }) }).takvim())?.etkinlikler.map((e) => e.id), ["usta"]);
});

test("süren, yaklaşan, kalan süre (İstanbul günü)", () => {
  const liste = [
    { id: "a", baslangic: "2026-11-10", bitis: "2026-11-14" },
    { id: "b", baslangic: "2026-11-20", bitis: "2026-11-21" },
    { id: "c", baslangic: "2026-11-16", bitis: "2026-11-16" },
  ];
  const simdi = new Date("2026-11-14T22:30:00+03:00");
  assert.deepEqual(suren(liste, simdi).map((x) => x.id), ["a"]);
  assert.deepEqual(yaklasan(liste, simdi).map((x) => x.id), ["c", "b"]);
  assert.equal(kalanSure(liste[0]!, simdi), 90 * 60_000);
});

test("ödül cihazda bir kez kaydedilir; oturumsuz bekler", async () => {
  const e = etkinlikBaslat({ oyunId: "deneme", adres: "x", depo: bellekDepo(), dogrula });
  assert.equal(await e.odulKazan("rozet-usta", "usta"), true);
  assert.equal(await e.odulKazan("rozet-usta"), false);
  assert.deepEqual((await e.oduller()).map((x) => x.odul), ["rozet-usta"]);
  await assert.rejects(e.odulKazan("Geçersiz Ad"));
});
