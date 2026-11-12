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
