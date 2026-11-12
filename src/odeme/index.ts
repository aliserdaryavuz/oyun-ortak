/**
 * odeme: tek seferlik satın alma hakları (RevenueCat), süresiz çevrimdışı hak, iade, web'de hak görünürlüğü,
 * korumalı içerik (KM-12, KH-9, EN-10, HK-8).
 *
 * Hak üç kaynaktan birleşir: cihazdaki önbellek (ağsız da açık kalır), sunucu (`ortak.haklar`, webhook yazar)
 * ve mağaza (RevenueCat SDK; yalnız Android/iOS). Sunucu bir hakkı 'iade' diyorsa ve mağaza da vermiyorsa
 * hak önbellekten düşer. Ağ yoksa önbellek olduğu gibi kalır.
 *
 * Mağaza eklentisi (ör. @revenuecat/purchases-capacitor) oyunun bağımlılığıdır; oyun onu `Magaza` arayüzüne sarar.
 * Web derlemesinde `magaza` verilmez: satın alma kapalıdır, hesaptaki haklar yine görünür.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Depo } from "../kayit/index.ts";

export interface Magaza {
  /** RevenueCat kullanıcı kimliğini Supabase kullanıcı kimliğine bağlar (Purchases.logIn). */
  kullaniciAta(id: string): Promise<void>;
  /** Etkin hak (entitlement) kimlikleri. */
  haklar(): Promise<string[]>;
  /** Ürünü satın alır; iptalde hata atar. Satın almadan sonraki etkin haklar döner. */
  satinAl(urun: string): Promise<string[]>;
  /** Mağazadaki geçmiş satın almaları geri yükler; etkin haklar döner. */
  geriYukle(): Promise<string[]>;
}

export interface OdemeAyari {
  supabase: SupabaseClient;
  oyunId: string;
  depo: Depo;
  /** Yalnız Android/iOS'ta. Web'de verilmez. */
  magaza?: Magaza;
}

interface Onbellek {
  haklar: string[];
  t: number;
}

export function odemeBaslat(a: OdemeAyari) {
  const KEY = `oyun-ortak:haklar:${a.oyunId}`;
  const sb = a.supabase;
  let bellek: Set<string> | null = null;

  const yukle = async (): Promise<Set<string>> => {
    if (bellek) return bellek;
    try {
      const v = JSON.parse((await a.depo.oku(KEY)) ?? "null") as Onbellek | null;
      bellek = new Set(Array.isArray(v?.haklar) ? v!.haklar.filter((x) => typeof x === "string") : []);
    } catch {
      bellek = new Set();
    }
    return bellek;
  };
  const sakla = async (h: Set<string>) => {
    bellek = h;
    await a.depo.yaz(KEY, JSON.stringify({ haklar: [...h].sort(), t: Date.now() } satisfies Onbellek)).catch(() => {});
  };

  const oturum = async () => (await sb.auth.getSession()).data.session;

  /** Sunucudaki haklar: { aktif, iade }. Oturum yoksa ya da ağ yoksa null. */
  async function sunucu(): Promise<{ aktif: Set<string>; iade: Set<string> } | null> {
    if (!(await oturum())) return null;
    try {
      const { data, error } = await sb.schema("ortak").rpc("haklarim", { p_oyun: a.oyunId });
      if (error) return null;
      const r = { aktif: new Set<string>(), iade: new Set<string>() };
      for (const x of data as { hak: string; durum: string }[]) (x.durum === "aktif" ? r.aktif : r.iade).add(x.hak);
      return r;
    } catch {
      return null;
    }
  }

  async function magazaHaklari(): Promise<Set<string> | null> {
    if (!a.magaza) return null;
    try {
      return new Set(await a.magaza.haklar());
    } catch {
      return null;
    }
  }

  async function magazayaBagla(): Promise<void> {
    if (!a.magaza) throw new Error("web_satis_yok");
    let s = await oturum();
    if (!s) {
      const { error } = await sb.auth.signInAnonymously();
      if (error) throw error;
      s = await oturum();
    }
    await a.magaza.kullaniciAta(s!.user.id);
  }

  return {
    /** Önbellekteki haklar; ağ beklemez. Açılışta ilk karar bununla verilir. */
    async haklar(): Promise<ReadonlySet<string>> {
      return new Set(await yukle());
    },

    async hakVar(hak: string): Promise<boolean> {
      return (await yukle()).has(hak);
    },

    /**
     * Sunucu ve mağazayla eşitler. Açılışta, ön plana dönüşte ve girişten sonra çağrılır.
     * Hiçbir kaynağa ulaşılamazsa önbellek değişmez (süresiz çevrimdışı hak).
     */
    async yenile(): Promise<ReadonlySet<string>> {
      const [s, m] = await Promise.all([sunucu(), magazaHaklari()]);
      const h = new Set(await yukle());
      if (!s && !m) return new Set(h);
      for (const x of s?.aktif ?? []) h.add(x);
      for (const x of m ?? []) h.add(x);
      // İade: sunucu iade diyor ve mağaza (varsa) vermiyor.
      for (const x of s?.iade ?? []) if (!s!.aktif.has(x) && !(m?.has(x) ?? false)) h.delete(x);
      await sakla(h);
      return new Set(h);
    },

    /** Satın alma. Web'de `web_satis_yok` hatası. İptal edilirse mağazanın hatası aynen döner. */
    async satinAl(urun: string): Promise<ReadonlySet<string>> {
      await magazayaBagla();
      const yeni = await a.magaza!.satinAl(urun);
      const h = new Set(await yukle());
      for (const x of yeni) h.add(x);
      await sakla(h);
      return new Set(h);
    },

    async geriYukle(): Promise<ReadonlySet<string>> {
      await magazayaBagla();
      const yeni = await a.magaza!.geriYukle();
      const h = new Set(await yukle());
      for (const x of yeni) h.add(x);
      await sakla(h);
      return new Set(h);
    },

    /**
     * Korumalı içerik (HK-8): `korumali` kovasında `<oyun>/<hak>/<dosya>`. Yalnız o hakkı etkin olan hesap indirebilir.
     * İndirilen içeriği çevrimdışı kullanım için saklamak oyunun işidir.
     */
    async korumaliIndir(hak: string, dosya: string): Promise<Blob> {
      const { data, error } = await sb.storage.from("korumali").download(`${a.oyunId}/${hak}/${dosya}`);
      if (error || !data) throw new Error(error?.message ?? "indirilemedi");
      return data;
    },
  };
}

export type Odeme = ReturnType<typeof odemeBaslat>;
