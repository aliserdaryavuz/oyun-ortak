/**
 * kayit: cihazda güvenli oyun kaydı.
 *
 * İki anahtarlı yazım (KM-1): `anahtar` son kayıt, `anahtar:yedek` ondan önceki sağlam kayıt.
 * Yazım sırası önce yedeği (bilinen son sağlam kopya), sonra ana kaydı yazar; yarım kalan
 * ana yazım bir sonraki açılışta yedekten kurtarılır. İkisi de okunamazsa ham veri
 * `anahtar:bozuk` altına saklanır, böylece hiçbir zaman boş kayıt eskisinin yerine sessizce geçmez.
 */

/** Anahtar-değer deposu. Web'de localStorage, Capacitor'da Preferences, Expo'da AsyncStorage. */
export interface Depo {
  oku(anahtar: string): Promise<string | null>;
  yaz(anahtar: string, deger: string): Promise<void>;
  sil(anahtar: string): Promise<void>;
}

/** localStorage yoksa (gizli pencere, sunucu) okuma null, yazma hata verir; kayit bunu yakalar. */
export function webDepo(ls: Storage | undefined = globalThis.localStorage): Depo {
  const d = (): Storage => {
    if (!ls) throw new Error("depo-yok");
    return ls;
  };
  return {
    oku: async (k) => (ls ? ls.getItem(k) : null),
    yaz: async (k, v) => d().setItem(k, v),
    sil: async (k) => d().removeItem(k),
  };
}

/** Capacitor Preferences eklentisi (oyun verir; paket eklentiye bağımlı değildir). */
export interface PreferencesBenzeri {
  get(o: { key: string }): Promise<{ value: string | null }>;
  set(o: { key: string; value: string }): Promise<void>;
  remove(o: { key: string }): Promise<void>;
}
export function capacitorDepo(p: PreferencesBenzeri): Depo {
  return {
    oku: async (key) => (await p.get({ key })).value,
    yaz: (key, value) => p.set({ key, value }),
    sil: (key) => p.remove({ key }),
  };
}

/** Bellek içi depo: testler ve depolamanın hiç olmadığı ortam için. */
export function bellekDepo(ilk: Record<string, string> = {}): Depo & { veri: Map<string, string> } {
  const veri = new Map(Object.entries(ilk));
  return {
    veri,
    oku: async (k) => veri.get(k) ?? null,
    yaz: async (k, v) => void veri.set(k, v),
    sil: async (k) => void veri.delete(k),
  };
}

export interface KayitAyari<T> {
  depo: Depo;
  anahtar: string;
  /** Kayıt biçiminin sürümü; artınca `goc` çağrılır. */
  surum: number;
  /** Hiç kayıt yokken başlangıç değeri. */
  bos: () => T;
  /** Eski sürümdeki veriyi bugünkü biçime çevirir. Hata atarsa o kopya okunamaz sayılır. */
  goc?: (veri: unknown, eskiSurum: number) => T;
  /** Okunan verinin biçimini denetler; false dönerse o kopya okunamaz sayılır. */
  gecerli?: (veri: unknown) => boolean;
  /** Bu paketten önceki kayıttan bir kez içe alma (KM-2). Eski anahtar silinmez, yedek olarak kalır. */
  iceAl?: { anahtar: string; donustur: (ham: string) => T | null; depo?: Depo };
}

export type AcilisDurumu = "yeni" | "ana" | "yedek" | "ice-alindi" | "bozuk";

export interface Kayit<T> {
  /** Kaydı okur. Asla hata atmaz. */
  ac(): Promise<{ veri: T; durum: AcilisDurumu }>;
  /** Kaydı yazar. Depo dolu ya da yoksa false döner; oyun bellekteki veriyle sürer. */
  yaz(veri: T): Promise<boolean>;
  /** Ana kayıt, yedek ve bozuk kopyayı siler (hesap silme, "baştan başla"). */
  temizle(): Promise<void>;
}

interface Zarf {
  s: number;
  v: unknown;
  t: number;
}

export function kayitDeposu<T>(a: KayitAyari<T>): Kayit<T> {
  const YEDEK = `${a.anahtar}:yedek`;
  const BOZUK = `${a.anahtar}:bozuk`;
  /** Bilinen son sağlam ana kaydın ham hali; bir sonraki yazımda yedeğe gider. */
  let sonSaglam: string | null = null;

  const coz = (ham: string | null): T | undefined => {
    if (ham == null) return undefined;
    try {
      const z = JSON.parse(ham) as Zarf;
      if (!z || typeof z !== "object" || typeof z.s !== "number" || !("v" in z)) return undefined;
      if (z.s > a.surum) return undefined; // yeni sürümün kaydı: eski uygulama dokunmaz
      const v = z.s === a.surum ? (z.v as T) : a.goc ? a.goc(z.v, z.s) : undefined;
      if (v === undefined) return undefined;
      if (a.gecerli && !a.gecerli(v)) return undefined;
      return v;
    } catch {
      return undefined;
    }
  };

  const guvenliOku = async (d: Depo, k: string): Promise<string | null> => {
    try {
      return await d.oku(k);
    } catch {
      return null;
    }
  };

  const zarfla = (veri: T): string => JSON.stringify({ s: a.surum, v: veri, t: Date.now() } satisfies Zarf);

  return {
    async ac() {
      const anaHam = await guvenliOku(a.depo, a.anahtar);
      const ana = coz(anaHam);
      if (ana !== undefined) {
        sonSaglam = anaHam;
        return { veri: ana, durum: "ana" };
      }
      const yedekHam = await guvenliOku(a.depo, YEDEK);
      const yedek = coz(yedekHam);
      if (yedek !== undefined) {
        sonSaglam = yedekHam;
        return { veri: yedek, durum: "yedek" };
      }
      if (anaHam != null || yedekHam != null) {
        // İkisi de okunamıyor: ham veriyi elle kurtarma için sakla, üstüne yazma.
        try {
          if ((await guvenliOku(a.depo, BOZUK)) == null) {
            await a.depo.yaz(BOZUK, JSON.stringify({ ana: anaHam, yedek: yedekHam, t: Date.now() }));
          }
        } catch {
          /* depo dolu: bozuk kopya korunamadı, ama ana anahtar yine de yerinde */
        }
        return { veri: a.bos(), durum: "bozuk" };
      }
      if (a.iceAl) {
        const eski = await guvenliOku(a.iceAl.depo ?? a.depo, a.iceAl.anahtar);
        if (eski != null) {
          let v: T | null = null;
          try {
            v = a.iceAl.donustur(eski);
          } catch {
            v = null;
          }
          if (v != null) {
            const ham = zarfla(v);
            try {
              await a.depo.yaz(a.anahtar, ham);
              sonSaglam = ham;
            } catch {
              /* yazılamadıysa bir dahaki açılışta yeniden içe alınır */
            }
            return { veri: v, durum: "ice-alindi" };
          }
        }
      }
      return { veri: a.bos(), durum: "yeni" };
    },

    async yaz(veri) {
      const ham = zarfla(veri);
      try {
        if (sonSaglam != null && sonSaglam !== ham) await a.depo.yaz(YEDEK, sonSaglam);
        await a.depo.yaz(a.anahtar, ham);
        sonSaglam = ham;
        return true;
      } catch {
        return false;
      }
    },

    async temizle() {
      sonSaglam = null;
      for (const k of [a.anahtar, YEDEK, BOZUK]) {
        try {
          await a.depo.sil(k);
        } catch {
          /* yok say */
        }
      }
    },
  };
}

const CIHAZ_ANAHTARI = "oyun-ortak:cihaz";

/**
 * Cihaz kimliği: ilk açılışta üretilir, depoda kalır. Ölçümde `distinct_id` olarak kullanılır.
 * `testKodu` verilirse (kapalı test bağlantısı `?t=kod`) kimlik `t-<kod>-<uuid>` olur ve testçi
 * olayları ayrılabilir. Kod küçük harf/rakam, en çok 12 karakter.
 */
export async function cihazKimligi(depo: Depo, testKodu?: string | null): Promise<string> {
  let id: string | null = null;
  try {
    id = await depo.oku(CIHAZ_ANAHTARI);
  } catch {
    id = null;
  }
  const kok = id?.replace(/^t-[a-z0-9]+-/, "") || crypto.randomUUID();
  const k = (testKodu ?? "").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 12);
  const yeni = k ? `t-${k}-${kok}`.slice(0, 64) : (id ?? kok);
  if (yeni !== id) {
    try {
      await depo.yaz(CIHAZ_ANAHTARI, yeni);
    } catch {
      /* depo yoksa kimlik bu oturumluk */
    }
  }
  return yeni;
}

/** Kimlik kapalı test cihazına mı ait; aitse test kodunu döner. */
export const testKodu = (cihaz: string): string | null => /^t-([a-z0-9]+)-/.exec(cihaz)?.[1] ?? null;
