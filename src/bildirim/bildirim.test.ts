import { test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../kayit/index.ts";
import { bildirimBaslat, hatirlatmaZamanlari, type YerelBildirim } from "./index.ts";

const t = (s: string) => new Date(s).toISOString();

test("hatırlatma zamanları: 7 gün, geçen saat ve oynanan gün atlanır", () => {
  const simdi = new Date("2026-11-12T19:00:00+03:00");
  const z = hatirlatmaZamanlari(simdi, 20, 30, null).map((d) => d.toISOString());
  assert.equal(z.length, 7);
  assert.equal(z[0], t("2026-11-12T20:30:00+03:00"));
  assert.equal(z[6], t("2026-11-18T20:30:00+03:00"));
  const oynadi = hatirlatmaZamanlari(simdi, 20, 30, "2026-11-12").map((d) => d.toISOString());
  assert.equal(oynadi[0], t("2026-11-13T20:30:00+03:00"));
  assert.equal(oynadi.length, 7);
  const gecti = hatirlatmaZamanlari(new Date("2026-11-12T21:00:00+03:00"), 20, 30, null);
  assert.equal(gecti[0]!.toISOString(), t("2026-11-13T20:30:00+03:00"));
});

test("izin yoksa kapalı kalır; oynanınca bugünkü atlanır", async () => {
  const planlar: { id: number; zaman: Date }[][] = [];
  let izin = false;
  const yerel: YerelBildirim = {
    izinIste: async () => izin,
    planla: async (l) => void planlar.push(l),
    iptal: async () => {},
  };
  const simdi = () => new Date("2026-11-12T19:00:00+03:00");
  const b = await bildirimBaslat({ yerel, depo: bellekDepo(), simdi });
  const ayar = { acik: true, saat: 20, dakika: 0, baslik: "Günün bulmacası", metin: "Bugünkü halka hazır" };
  assert.equal(await b.ayarla(ayar), false);
  assert.equal(b.ayar()?.acik, false);
  assert.equal(planlar.length, 0);
  izin = true;
  assert.equal(await b.ayarla(ayar), true);
  assert.deepEqual(planlar.at(-1)!.map((x) => x.id), [7100, 7101, 7102, 7103, 7104, 7105, 7106]);
  assert.equal(planlar.at(-1)![0]!.zaman.toISOString(), t("2026-11-12T20:00:00+03:00"));
  await b.oynandi();
  assert.equal(planlar.at(-1)![0]!.zaman.toISOString(), t("2026-11-13T20:00:00+03:00"));
});

test("haftalık seçim: haftada en çok bir (en erkeni), geçmiş atlanır, en çok 4 hafta, oynanan günde atla", async () => {
  const { haftalikSecim } = await import("./index.ts");
  const simdi = new Date("2026-11-16T09:00:00+03:00"); // pazartesi
  const e = (s: string, baslik = s, oynananGundeAtla = false) => ({ zaman: new Date(s), baslik, metin: "", oynananGundeAtla });
  const liste = [
    e("2026-11-16T08:00:00+03:00", "gecmis"),
    e("2026-11-18T10:00:00+03:00", "h1-car"),
    e("2026-11-17T10:00:00+03:00", "h1-sal"), // aynı haftada daha erken: bu seçilir
    e("2026-11-23T10:00:00+03:00", "h2"),
    e("2026-11-30T10:00:00+03:00", "h3"),
    e("2026-12-07T10:00:00+03:00", "h4"),
    e("2026-12-14T10:00:00+03:00", "h5"), // 5. hafta: kurulmaz
  ];
  assert.deepEqual(haftalikSecim(simdi, liste, null).map((x) => x.baslik), ["h1-sal", "h2", "h3", "h4"]);
  // pazar 23:30 ile ertesi pazartesi ayrı haftalar (İstanbul)
  const sinir = haftalikSecim(simdi, [e("2026-11-22T23:30:00+03:00", "pazar"), e("2026-11-23T00:30:00+03:00", "pazartesi")], null);
  assert.deepEqual(sinir.map((x) => x.baslik), ["pazar", "pazartesi"]);
  // oynanan günde atla: o günkü düşer, haftanın sonraki adayı seçilir
  const atla = haftalikSecim(simdi, [e("2026-11-17T10:00:00+03:00", "lig", true), e("2026-11-19T10:00:00+03:00", "yedek")], "2026-11-17");
  assert.deepEqual(atla.map((x) => x.baslik), ["yedek"]);
});

test("ek bildirim: ayrı anahtar, izin yoksa kapalı, 7200'den kimlik, yenile ile yeniden kurulur", async () => {
  const planlar: { id: number; baslik: string }[][] = [];
  const iptaller: number[][] = [];
  let izin = false;
  const yerel: YerelBildirim = {
    izinIste: async () => izin,
    planla: async (l) => void planlar.push(l),
    iptal: async (i) => void iptaller.push(i),
  };
  const simdi = () => new Date("2026-11-16T09:00:00+03:00");
  const depo = bellekDepo();
  const b = await bildirimBaslat({ yerel, depo, simdi });
  await b.ekPlanla([
    { zaman: new Date("2026-11-17T10:00:00+03:00"), baslik: "Usta Turnuvası açıldı", metin: "" },
    { zaman: new Date("2026-11-24T10:00:00+03:00"), baslik: "Usta Turnuvası açıldı", metin: "" },
  ]);
  assert.equal(planlar.length, 0); // kapalıyken kurulmaz
  assert.equal(await b.ekAyarla(true), false);
  assert.equal(b.ekAcik(), false);
  izin = true;
  assert.equal(await b.ekAyarla(true), true);
  assert.deepEqual(planlar.at(-1)!.map((x) => x.id), [7200, 7201]);
  assert.ok(iptaller.some((i) => i.includes(7200) && i.includes(7203)));
  // kalıcı: yeni başlatmada yenile aynı ek bildirimleri kurar
  const b2 = await bildirimBaslat({ yerel, depo, simdi });
  await b2.yenile();
  assert.deepEqual(planlar.at(-1)!.map((x) => x.id), [7200, 7201]);
  await b2.ekAyarla(false);
  const son = planlar.length;
  await b2.yenile();
  assert.equal(planlar.length, son); // kapalı: kurulmaz
});
