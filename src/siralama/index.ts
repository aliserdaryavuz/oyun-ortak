/**
 * siralama: doğrulamalı skor gönderimi (çevrimdışı kuyrukla), günlük/etkinlik tablosu, haftalık lig.
 *
 * Gönderim yalnız `dogrula-<oyun>` Edge Function'ına gider; puanı sunucu hesaplar. Ağ yoksa, oturum yenilenemediyse
 * ya da sunucu geçici hata verdiyse gönderim kuyrukta kalır ve sonra yeniden denenir (sezgi giden kutusu deseni).
 * Kalıcı ret (pencere kapandı, sürüm eski, geçersiz kayıt) kuyruktan düşer ve sonuç olarak bildirilir.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Depo } from "../kayit/index.ts";

export * from "./zaman.ts";

export interface GonderimSonucu {
  runId: string;
  /** HTTP durumu; 0 = ağ yok. */
  durum: number;
  veri: unknown;
  /** true ise kuyrukta kaldı, sonra yeniden denenecek. */
  bekliyor: boolean;
}

interface Bekleyen {
  runId: string;
  govde: Record<string, unknown>;
  eklendi: number;
}

export interface Satir {
  sira: number;
  ad: string | null;
  puan: number;
  ikincil: number | null;
  ben: boolean;
}
export interface Tablo {
  toplam: number;
  ben: { sira: number; ust_yuzde: number | null } | null;
  satirlar: Satir[];
}
export interface LigDurumu {
  hafta: string;
  kademe: number;
  kademe_adi: string | null;
  katildi: boolean;
  uyeler: { sira: number; ad: string | null; puan: number; ben: boolean }[];
  onceki: { hafta: string; sira: number | null; sonuc: "cikti" | "kaldi" | "indi"; puan: number } | null;
}

export interface SiralamaAyari {
  supabase: SupabaseClient;
  oyunId: string;
  depo: Depo;
  /** Varsayılan `dogrula-<oyunId>`. */
  fonksiyon?: string;
}

const KUYRUK_SINIRI = 50;
export const yenidenDenenir = (durum: number) => durum === 0 || durum === 401 || durum === 429 || durum >= 500;

/**
 * Kişisel ödül çubuğu (HK-2: 5/10/15/20/25): lig puanına göre ulaşılan kademe sayısı ve bir sonrakine kalan.
 */
export function odulCubugu(puan: number, kademeler: readonly number[]) {
  const ulasilan = kademeler.filter((k) => puan >= k).length;
  const sonraki = kademeler[ulasilan] ?? null;
  return { ulasilan, sonraki, kalan: sonraki == null ? 0 : sonraki - puan };
}

export function siralamaBaslat(a: SiralamaAyari) {
  const sb = a.supabase;
  const fn = a.fonksiyon ?? `dogrula-${a.oyunId}`;
  const KEY = `oyun-ortak:gonderim:${a.oyunId}`;
  let kuyruk: Bekleyen[] | null = null;
  let bosaltiliyor: Promise<GonderimSonucu[]> | null = null;

  const yukle = async (): Promise<Bekleyen[]> => {
    if (kuyruk) return kuyruk;
    try {
      const v: unknown = JSON.parse((await a.depo.oku(KEY)) ?? "[]");
      kuyruk = Array.isArray(v) ? (v as Bekleyen[]) : [];
    } catch {
      kuyruk = [];
    }
    return kuyruk;
  };
  const sakla = () => a.depo.yaz(KEY, JSON.stringify(kuyruk ?? [])).catch(() => {});

  async function cagir(b: Bekleyen): Promise<{ durum: number; veri: unknown }> {
    try {
      if (!(await sb.auth.getSession()).data.session) {
        const { error } = await sb.auth.signInAnonymously();
        if (error) return { durum: 0, veri: { error: "anonim_giris" } };
      }
      const { data, error } = await sb.functions.invoke(fn, { body: { ...b.govde, runId: b.runId } });
      if (!error) return { durum: 200, veri: data };
      const yanit = (error as { context?: unknown }).context;
      if (yanit instanceof Response) {
        let veri: unknown = null;
        try {
          veri = await yanit.json();
        } catch {
          veri = null;
        }
        return { durum: yanit.status, veri };
      }
      return { durum: 0, veri: { error: "ag" } };
    } catch {
      return { durum: 0, veri: { error: "ag" } };
    }
  }

  async function bosalt(): Promise<GonderimSonucu[]> {
    if (bosaltiliyor) return bosaltiliyor;
    bosaltiliyor = (async () => {
      const q = await yukle();
      const sonuclar: GonderimSonucu[] = [];
      for (const b of [...q]) {
        const r = await cagir(b);
        const bekliyor = yenidenDenenir(r.durum);
        sonuclar.push({ runId: b.runId, durum: r.durum, veri: r.veri, bekliyor });
        if (bekliyor) break; // ağ yoksa sıradakiler de gitmez; sırayı koru
        kuyruk = (kuyruk ?? []).filter((x) => x.runId !== b.runId);
        await sakla();
      }
      return sonuclar;
    })();
    try {
      return await bosaltiliyor;
    } finally {
      bosaltiliyor = null;
    }
  }

  return {
    /**
     * Gönderimi kuyruğa ekler ve kuyruğu boşaltmayı dener. `runId` her gönderimde bir kez üretilir;
     * aynı gönderimin yeniden denenmesi sunucuda tek skor üretir.
     */
    async gonder(govde: Record<string, unknown>): Promise<GonderimSonucu> {
      const q = await yukle();
      const b: Bekleyen = { runId: crypto.randomUUID(), govde, eklendi: Date.now() };
      q.push(b);
      if (q.length > KUYRUK_SINIRI) q.splice(0, q.length - KUYRUK_SINIRI);
      await sakla();
      const sonuclar = await bosalt();
      return sonuclar.find((s) => s.runId === b.runId) ?? { runId: b.runId, durum: 0, veri: null, bekliyor: true };
    },
    /** Uygulama açılışında, ön plana dönüşte ve ağ gelince çağrılır. */
    bosalt,
    bekleyenSayisi: async () => (await yukle()).length,

    async tablo(tur: "gunluk" | "etkinlik", donem: string, o: { ilk?: number; cevre?: number } = {}): Promise<Tablo> {
      const { data, error } = await sb.schema("ortak").rpc("siralama", {
        p_oyun: a.oyunId, p_tur: tur, p_donem: donem, p_ilk: o.ilk ?? 10, p_cevre: o.cevre ?? 3,
      });
      if (error) throw new Error(error.message);
      return data as Tablo;
    },

    async lig(): Promise<LigDurumu> {
      const { data, error } = await sb.schema("ortak").rpc("lig_durumu", { p_oyun: a.oyunId });
      if (error) throw new Error(error.message);
      return data as LigDurumu;
    },
  };
}

export type Siralama = ReturnType<typeof siralamaBaslat>;
