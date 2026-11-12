/**
 * dogrula-deneme: şablonun çalışan örneği (sahte "deneme" oyunu). Tanıtım sayfası ve sunucu testleri bunu kullanır.
 *
 * Sahte motor: kayıt 1–10 rakamlık dizi (0–9), puan = rakamlar toplamı. Kural sürümü 1.
 *   { islem: "gunluk", gun, kayit, kuralSurumu, runId }  → tek seferlik gönderim (EN-1, KM-6)
 *   { islem: "olay", gun, sira, olay }                   → durum tutan deneme (KH-1); olay -1 denemeyi bitirir
 */
import { istek, gunGecerli } from "../../../sunucu/mod.ts";

const KURAL_SURUMU = 1;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const rakamlar = (x: unknown): x is number[] =>
  Array.isArray(x) && x.length >= 1 && x.length <= 10 && x.every((n) => Number.isInteger(n) && n >= 0 && n <= 9);
const ligPuani = (puan: number) => (puan >= 60 ? 5 : puan >= 30 ? 4 : 3); // oyunun formülü (HK-2 benzeri)

Deno.serve(
  istek<Record<string, unknown>>({ oyunId: "deneme" }, async (c) => {
    const g = c.govde;
    if (typeof g.gun !== "string" || !gunGecerli(g.gun)) return c.hata(400, "gun");
    if (!c.pencereAcik(g.gun, { gecSaat: 3 })) return c.hata(409, "pencere");

    if (g.islem === "gunluk") {
      if (g.kuralSurumu !== KURAL_SURUMU) return c.hata(426, "surum");
      if (typeof g.runId !== "string" || !UUID.test(g.runId)) return c.hata(400, "run_id");
      if (!rakamlar(g.kayit)) return c.hata(400, "kayit");
      const puan = g.kayit.reduce((a, b) => a + b, 0);
      const r = await c.skorYaz({
        tur: "gunluk", donem: g.gun, puan, ikincil: g.kayit.length, ligPuani: ligPuani(puan),
        runId: g.runId, ayrinti: { kayit: g.kayit },
      });
      return c.tamam({ ...r, puan });
    }

    if (g.islem === "olay") {
      if (!Number.isInteger(g.sira) || !Number.isInteger(g.olay) || (g.olay as number) < -1 || (g.olay as number) > 9)
        return c.hata(400, "olay");
      const d = c.deneme<{ kayit: number[] }>(`gunluk:${g.gun}`);
      const simdiki = await d.al();
      const kayit = [...(simdiki.durum.kayit ?? [])];
      if ((g.sira as number) < simdiki.sira) {
        // Yeniden gönderim yalnız o sıradaki olay AYNIYSA "tekrar"dır; eski sırayla gelen farklı olay reddedilir.
        const ayni = g.olay === -1 ? simdiki.bitti && g.sira === simdiki.sira - 1 : kayit[g.sira as number] === g.olay;
        return ayni ? c.tamam({ durum: "tekrar", deneme: simdiki }) : c.hata(409, "sira");
      }
      if ((g.sira as number) > simdiki.sira || simdiki.bitti) return c.hata(409, "sira");
      const bitti = g.olay === -1 || kayit.length >= 9;
      if (g.olay !== -1) kayit.push(g.olay as number);
      const yeni = await d.ilerlet(simdiki.sira, { kayit }, bitti);
      if (!yeni) return c.hata(409, "sira"); // eş zamanlı başka istek kazandı
      if (!bitti) return c.tamam({ durum: "devam", deneme: yeni });
      const puan = kayit.reduce((a, b) => a + b, 0);
      const r = await c.skorYaz({
        tur: "gunluk", donem: g.gun, puan, ikincil: kayit.length, ligPuani: ligPuani(puan),
        runId: crypto.randomUUID(), ayrinti: { kayit },
      });
      return c.tamam({ ...r, puan, deneme: yeni });
    }
    return c.hata(400, "islem");
  }),
);
