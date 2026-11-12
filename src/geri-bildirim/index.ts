/**
 * geri-bildirim: kapalı test için kısa uygulama içi anket (KM-11, KH-11, EN-12, HK-9).
 *
 * Paket arayüz çizmez (oyuna özgü arayüz bu depoda olmaz); hangi anketin ne zaman gösterileceğine karar verir
 * ve cevabı ölçüme (PostHog, `geri_bildirim` olayı) gönderir. Ayrı tablo yok.
 * Gösterim koşulları oyundan: bir sayacın eşiği (ör. "5. çözümden sonra") ve/veya ilk açılıştan bu yana gün
 * (ör. "7. günde"). Her anket bir kez gösterilir. Yalnız `etkin` ise (kapalı test sürümü) çalışır.
 */
import type { Depo } from "../kayit/index.ts";
import type { Olcum } from "../olcum/index.ts";

export type Soru =
  | { id: string; tur: "secim"; metin: string; secenekler: string[]; serbestMetin?: boolean }
  | { id: string; tur: "olcek"; metin: string; en_az: number; en_cok: number; serbestMetin?: boolean }
  | { id: string; tur: "metin"; metin: string };

export interface Anket {
  id: string;
  sorular: Soru[];
  /** Koşulların hepsi sağlanınca gösterilir. */
  kosul: { sayac?: { ad: string; esik: number }; gun?: number };
}

export type Cevap = { secim?: string; olcek?: number; metin?: string };

export interface GeriBildirimAyari {
  depo: Depo;
  olcum: Pick<Olcum, "olay">;
  anketler: Anket[];
  /** Kapalı test sürümünde true (ör. derleme bayrağı ya da cihaz kimliğinde test kodu). */
  etkin: boolean;
  simdi?: () => Date;
}

interface Durum {
  ilk: string;
  sayaclar: Record<string, number>;
  gosterilen: string[];
}

const KEY = "oyun-ortak:geri-bildirim";
const METIN_SINIRI = 200;

export async function geriBildirimBaslat(a: GeriBildirimAyari) {
  const simdi = a.simdi ?? (() => new Date());
  let d: Durum;
  try {
    d = JSON.parse((await a.depo.oku(KEY)) ?? "null") as Durum;
    if (!d || typeof d.ilk !== "string") throw 0;
  } catch {
    d = { ilk: simdi().toISOString(), sayaclar: {}, gosterilen: [] };
  }
  const yaz = () => a.depo.yaz(KEY, JSON.stringify(d)).catch(() => {});
  await yaz();

  const gecenGun = () => Math.floor((simdi().getTime() - new Date(d.ilk).getTime()) / 86_400_000);

  return {
    /** Oyun olayını sayar (ör. "cozum"). */
    async say(ad: string, n = 1): Promise<void> {
      d.sayaclar[ad] = (d.sayaclar[ad] ?? 0) + n;
      await yaz();
    },

    /** Şimdi gösterilmesi gereken anket (yoksa null). Gösterildi sayılması için `gosterildi` çağrılır. */
    siradaki(): Anket | null {
      if (!a.etkin) return null;
      return (
        a.anketler.find((k) => {
          if (d.gosterilen.includes(k.id)) return false;
          const s = k.kosul.sayac;
          if (s && (d.sayaclar[s.ad] ?? 0) < s.esik) return false;
          if (k.kosul.gun != null && gecenGun() < k.kosul.gun) return false;
          return true;
        }) ?? null
      );
    },

    /** Anket ekrana geldi; oyuncu kapatsa da bir daha gösterilmez. */
    async gosterildi(anketId: string): Promise<void> {
      if (!d.gosterilen.includes(anketId)) d.gosterilen.push(anketId);
      await yaz();
    },

    /** Cevapları ölçüme gönderir. Serbest metin 200 karakterde kesilir. */
    async cevapla(anketId: string, cevaplar: Record<string, Cevap>): Promise<void> {
      const anket = a.anketler.find((k) => k.id === anketId);
      if (!anket) throw new Error(`anket_yok: ${anketId}`);
      const ozellik: Record<string, string | number | null> = { anket: anketId, gun: gecenGun() };
      for (const s of anket.sorular) {
        const c = cevaplar[s.id];
        if (!c) continue;
        if (s.tur === "secim" && c.secim != null && s.secenekler.includes(c.secim)) ozellik[`${s.id}_secim`] = c.secim;
        if (s.tur === "olcek" && typeof c.olcek === "number" && c.olcek >= s.en_az && c.olcek <= s.en_cok)
          ozellik[`${s.id}_olcek`] = c.olcek;
        if (c.metin?.trim() && (s.tur === "metin" || s.serbestMetin))
          ozellik[`${s.id}_metin`] = c.metin.trim().slice(0, METIN_SINIRI);
      }
      a.olcum.olay("geri_bildirim", ozellik);
      await this.gosterildi(anketId);
    },
  };
}
