import { test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../kayit/index.ts";
import { olcumBaslat, temizOzellikler, type OlcumAyari } from "./index.ts";

const sahteFetch = (durum: number | "ag-yok") => {
  const istekler: { url: string; govde: { api_key: string; batch: { event: string; properties: Record<string, unknown> }[] } }[] = [];
  const f = (async (url: string, init: RequestInit) => {
    if (durum === "ag-yok") throw new TypeError("Failed to fetch");
    istekler.push({ url, govde: JSON.parse(String(init.body)) });
    return new Response(null, { status: durum });
  }) as unknown as typeof fetch;
  return { f, istekler };
};

const ayar = (ek: Partial<OlcumAyari>): OlcumAyari => ({
  oyunId: "halka",
  surum: "1.0.0",
  platform: "web",
  anahtar: "phc_test",
  cihaz: "c1",
  depo: bellekDepo(),
  aralik: 0,
  uzantiOlaylar: ["league_joined"],
  ...ek,
});

test("izinli olaylar ortak özelliklerle gider; izinsizler düşer", async () => {
  const { f, istekler } = sahteFetch(200);
  const o = await olcumBaslat(ayar({ fetch: f, cihaz: "t-grup1-x" }));
  o.olay("seviye_bitir", { sure: 12, zorluk: "kolay" });
  o.olay("league_joined");
  o.olay("bilinmeyen");
  await o.gonder();
  assert.equal(istekler.length, 1);
  assert.equal(istekler[0]!.url, "https://eu.i.posthog.com/batch/");
  const b = istekler[0]!.govde.batch;
  assert.deepEqual(b.map((x) => x.event), ["seviye_bitir", "league_joined"]);
  assert.deepEqual(b[0]!.properties, {
    sure: 12, zorluk: "kolay", distinct_id: "t-grup1-x", oyun_id: "halka", surum: "1.0.0", platform: "web", test: "grup1",
  });
  assert.equal(o.kuyruk.length, 0);
});

test("ağ yokken kuyruk depoda kalır, yeni açılışta gönderilir", async () => {
  const depo = bellekDepo();
  const yok = sahteFetch("ag-yok");
  const o = await olcumBaslat(ayar({ fetch: yok.f, depo }));
  o.olay("oturum_basla");
  await o.gonder();
  assert.equal(o.kuyruk.length, 1);
  await new Promise((r) => setTimeout(r, 0));
  const var_ = sahteFetch(200);
  const o2 = await olcumBaslat(ayar({ fetch: var_.f, depo }));
  await o2.gonder();
  assert.equal(var_.istekler[0]!.govde.batch.length, 1);
});

test("kalıcı 4xx: ölçüm sessizce durur; 429 ve 5xx yeniden denenir", async () => {
  for (const [durum, durmali] of [[401, true], [429, false], [503, false]] as const) {
    const { f } = sahteFetch(durum);
    const o = await olcumBaslat(ayar({ fetch: f }));
    o.olay("oturum_basla");
    await o.gonder();
    assert.equal(o.durdu, durmali, String(durum));
    o.olay("oturum_basla");
    assert.equal(o.kuyruk.length, durmali ? 0 : 2, String(durum));
  }
});

test("anahtar yoksa ölçüm kapalı ve hiç istek atmaz", async () => {
  const { f, istekler } = sahteFetch(200);
  const o = await olcumBaslat(ayar({ fetch: f, anahtar: "" }));
  o.olay("oturum_basla");
  await o.gonder();
  assert.equal(istekler.length, 0);
});

test("kuyruk 500 olayda kesilir, en eskiler düşer", async () => {
  const { f } = sahteFetch("ag-yok");
  const o = await olcumBaslat(ayar({ fetch: f, topluSinir: 10_000 }));
  for (let i = 0; i < 510; i++) o.olay("seviye_basla", { n: i });
  assert.equal(o.kuyruk.length, 500);
  assert.equal(o.kuyruk[0]!.properties.n, 10);
});

test("topluSinir dolunca kendiliğinden gönderir; aynı anda tek istek", async () => {
  const { f, istekler } = sahteFetch(200);
  const o = await olcumBaslat(ayar({ fetch: f, topluSinir: 2 }));
  o.olay("seviye_basla");
  o.olay("seviye_bitir");
  o.olay("seviye_basla");
  await o.gonder();
  await o.gonder();
  assert.equal(istekler.reduce((n, i) => n + i.govde.batch.length, 0), 3);
});

test("özellik temizliği", () => {
  assert.deepEqual(
    temizOzellikler({ a: "x".repeat(300), B: 1, n: Number.NaN, ok: true, z: null, d: {} as never }),
    { a: "x".repeat(200), ok: true, z: null },
  );
});
