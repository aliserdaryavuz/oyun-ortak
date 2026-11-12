/**
 * dogrula-<oyun> şablonu. Oyun deposunda `supabase/functions/dogrula-<oyun>/` altına kopyalanır.
 * Yalnız bu fonksiyon oyun deposundan yayınlanır: npx supabase functions deploy dogrula-<oyun> --project-ref <oyun-canli>
 *
 * Yapılacaklar (OYUN ile işaretli yerler):
 *  1. oyunId'yi ve motor içe aktarımını düzelt.
 *  2. Gövde sözleşmesini oyunun ISTEKLER satırına göre doğrula (ör. KM-6, EN-1, HK-1).
 *  3. Puanı motorla yeniden oynatarak hesapla; istemcinin bildirdiği puanı asla kullanma.
 *  4. Durum tutan deneme gerekiyorsa (KH-1) supabase/functions/dogrula-deneme örneğindeki `olay` dalına bak.
 */
import { gunGecerli, istek } from "@oyun/ortak-sunucu";
// OYUN: motor saf TypeScript; Edge Function oyun deposundaki motoru doğrudan içe aktarır.
// import { oynat, puanla, KURAL_SURUMU } from "../../../src/engine/index.ts";
const KURAL_SURUMU = 1;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(
  istek<Record<string, unknown>>({ oyunId: "OYUN" }, async (c) => {
    const g = c.govde;
    if (typeof g.gun !== "string" || !gunGecerli(g.gun)) return c.hata(400, "gun");
    // OYUN: gönderim penceresi (EN-2: gecSaat 3; KM-5: ayniHafta).
    if (!c.pencereAcik(g.gun, { gecSaat: 3 })) return c.hata(409, "pencere");
    if (g.kuralSurumu !== KURAL_SURUMU) return c.hata(426, "surum");
    if (typeof g.runId !== "string" || !UUID.test(g.runId)) return c.hata(400, "run_id");

    // OYUN: günün içeriğini sunucudan al (istemciye cevap gönderilmez, KH-2), kaydı motorla yeniden oynat.
    // const sonuc = puanla(oynat(await gununBulmacasi(c.db, g.gun), g.kayit));
    const sonuc = { puan: 0, ikincil: 0, ligPuani: 0 };

    const r = await c.skorYaz({
      tur: "gunluk",
      donem: g.gun,
      puan: sonuc.puan,
      ikincil: sonuc.ikincil, // eşitlik bozucu (ör. süre); oyunlar.ayarlar.siralama.esitlik = "ikincil" ise kullanılır
      ligPuani: sonuc.ligPuani, // oyunun günlük lig puanı formülü; null ise lige sayılmaz
      runId: g.runId,
      ayrinti: { kayit: g.kayit }, // denetim için, 90 gün sonra boşaltılır
    });
    return c.tamam({ ...r, ...sonuc });
  }),
);
