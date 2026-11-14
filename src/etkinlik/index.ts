/**
 * etkinlik: güncellemesiz açılan etkinlik takvimi ve kozmetik ödüllerin eşitlenmesi
 * (KM-8, KM-9, KH-10, EN-8, EN-9, HK-7).
 *
 * Takvim, oyunun Cloudflare Pages'teki statik JSON'u. Paket takvimin biçimini bilmez (opak); oyunun `dogrula`
 * işlevi geçerli takvimi döner, geçmeyen kayıtları atar. Ağ yoksa son geçerli takvim önbellekten gelir.
 * Ödüller cihazda hesaplanır ve önce yerelde kaydedilir; oturum varsa sunucuya bir kez yazılır
 * (`ortak.odul_kaydet`, tekrar yazım zararsız) ve başka cihazda kazanılanlar geri alınır.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Depo } from "../kayit/index.ts";
import { gunSonu, istanbulGunu } from "../siralama/zaman.ts";

export interface Donemli {
  /** YYYY-MM-DD, İstanbul günü; o gün dahil. */
  baslangic: string;
  /** YYYY-MM-DD, İstanbul günü; o gün dahil. */
  bitis: string;
}

/** Bugün (İstanbul) süren öğeler. */
export function suren<T extends Donemli>(liste: readonly T[], simdi: Date = new Date()): T[] {
  const g = istanbulGunu(simdi);
  return liste.filter((x) => x.baslangic <= g && g <= x.bitis);
}

/** Henüz başlamamış öğeler, başlangıca göre sıralı. */
export function yaklasan<T extends Donemli>(liste: readonly T[], simdi: Date = new Date()): T[] {
  const g = istanbulGunu(simdi);
  return liste.filter((x) => x.baslangic > g).sort((a, b) => a.baslangic.localeCompare(b.baslangic));
}

/** Öğenin bitişine kalan süre (ms); bittiyse 0. Sayaçlar için. */
export const kalanSure = (x: Donemli, simdi: Date = new Date()): number =>
  Math.max(0, gunSonu(x.bitis).getTime() - simdi.getTime());

export interface Odul {
  odul: string;
  kaynak?: string;
  kazanildi: string;
}

export interface EtkinlikAyari<T> {
  oyunId: string;
  /** Takvimin adresi (ör. https://www.halkakelime.com/etkinlik/takvim.json). */
  adres: string;
  depo: Depo;
  /** Ham JSON'u doğrular; geçersizse null. Geçmeyen alt kayıtları atmak oyunun işidir. */
  dogrula: (ham: unknown) => T | null;
  /** Ödül eşitlemesi için; verilmezse ödüller yalnız cihazda kalır. */
  supabase?: SupabaseClient;
  fetch?: typeof fetch;
}

const ODUL = /^[a-z0-9_:.-]{1,64}$/;

export function etkinlikBaslat<T>(a: EtkinlikAyari<T>) {
  const TAKVIM = `oyun-ortak:takvim:${a.oyunId}`;
  const ODULLER = `oyun-ortak:oduller:${a.oyunId}`;
  const f = a.fetch ?? globalThis.fetch.bind(globalThis);

  type OdulKaydi = { oduller: Odul[]; bekleyen: string[] };
  const odulOku = async (): Promise<OdulKaydi> => {
    try {
      const v = JSON.parse((await a.depo.oku(ODULLER)) ?? "null") as OdulKaydi | null;
      if (v && Array.isArray(v.oduller) && Array.isArray(v.bekleyen)) return v;
    } catch {
      /* bozuk: boş başla */
    }
    return { oduller: [], bekleyen: [] };
  };
  const odulYaz = (k: OdulKaydi) => a.depo.yaz(ODULLER, JSON.stringify(k)).catch(() => {});

  return {
    /** Takvimi indirir ve doğrular; olmazsa son geçerli takvimi döner. Hiç yoksa null. */
    async takvim(): Promise<T | null> {
      try {
        const r = await f(a.adres, { cache: "no-cache" });
        if (r.ok) {
          const ham: unknown = await r.json();
          const t = a.dogrula(ham);
          if (t != null) {
            await a.depo.yaz(TAKVIM, JSON.stringify(ham)).catch(() => {});
            return t;
          }
        }
      } catch {
        /* ağ yok: önbellek */
      }
      try {
        const ham = (await a.depo.oku(TAKVIM)) ?? null;
        return ham == null ? null : a.dogrula(JSON.parse(ham));
      } catch {
        return null;
      }
    },

    async oduller(): Promise<Odul[]> {
      return (await odulOku()).oduller;
    },

    /** Cihazda kazanılan ödülü kaydeder (ikinci kez kazanılırsa bir şey olmaz) ve eşitlemeyi dener. */
    async odulKazan(odul: string, kaynak?: string): Promise<boolean> {
      if (!ODUL.test(odul)) throw new Error(`odul_kimligi: ${odul}`);
      const k = await odulOku();
      if (k.oduller.some((x) => x.odul === odul)) return false;
      k.oduller.push({ odul, kaynak, kazanildi: new Date().toISOString() });
      k.bekleyen.push(odul);
      await odulYaz(k);
      await this.esitle();
      return true;
    },

    /** Bekleyen ödülleri sunucuya yazar, başka cihazda kazanılanları alır. Oturum yoksa, misafirse ya da ağ yoksa sessizce geçer (ödül yerelde bekler). */
    async esitle(): Promise<void> {
      const sb = a.supabase;
      if (!sb || !(await sb.auth.getSession()).data.session) return;
      try {
        const k = await odulOku();
        if (k.bekleyen.length) {
          const gidecek = k.oduller.filter((x) => k.bekleyen.includes(x.odul)).slice(0, 100);
          const { error } = await sb.schema("ortak").rpc("odul_kaydet", { p_oyun: a.oyunId, p_oduller: gidecek });
          if (error) return;
          const giden = new Set(gidecek.map((x) => x.odul));
          k.bekleyen = k.bekleyen.filter((x) => !giden.has(x));
        }
        const { data, error } = await sb.schema("ortak").rpc("odullerim", { p_oyun: a.oyunId });
        if (!error) {
          const var_ = new Set(k.oduller.map((x) => x.odul));
          for (const x of data as Odul[]) if (!var_.has(x.odul)) k.oduller.push(x);
        }
        await odulYaz(k);
      } catch {
        /* ağ yok: sonra */
      }
    },
  };
}

export type Etkinlik<T> = ReturnType<typeof etkinlikBaslat<T>>;
