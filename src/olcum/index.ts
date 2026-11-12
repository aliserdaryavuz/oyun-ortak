/**
 * olcum: olayları PostHog'a (AB bulutu) gönderir. SDK yok, düz fetch; web, Capacitor ve Expo'da aynı kod.
 *
 * - Olay adı çekirdek listede ya da oyunun `uzantiOlaylar` listesinde olmalı; değilse düşer.
 * - Özellikler yalnız basit türler (metin ≤200, sonlu sayı, mantıksal, null); kişisel veri konmaz.
 * - Kuyruk depoda kalır (en çok 500 olay, dolunca en eskisi düşer); ağ gelince toplu gider.
 * - PostHog kalıcı hata (4xx) dönerse ölçüm bu oturumda sessizce durur; oyun hiçbir zaman etkilenmez.
 */
import type { Depo } from "../kayit/index.ts";

export const CEKIRDEK_OLAYLAR = [
  "oturum_basla",
  "seviye_basla",
  "seviye_bitir",
  "seviye_kaybet",
  "gunluk_basla",
  "gunluk_bitir",
  "hesap_bagla",
  "satin_alma_goster",
  "satin_alma_basla",
  "satin_alma_bitir",
  "satin_alma_iptal",
  "hata",
] as const;

export type Ozellikler = Record<string, string | number | boolean | null>;

export interface OlcumAyari {
  oyunId: string;
  /** Oyunun sürümü (ör. "1.4.0"). */
  surum: string;
  platform: "web" | "android" | "ios";
  /** PostHog proje anahtarı (herkese açık anahtar, gizli değil). Boşsa ölçüm kapalı. */
  anahtar: string;
  /** Kayıt paketinden cihaz kimliği. */
  cihaz: string;
  depo: Depo;
  /** Oyuna özgü olay adları (KM-10, KH-8, EN-11, HK-6). */
  uzantiOlaylar?: readonly string[];
  adres?: string;
  /** Kuyruk bu sayıya ulaşınca hemen gönderilir. */
  topluSinir?: number;
  /** Otomatik gönderim aralığı (ms); 0 kapatır. */
  aralik?: number;
  fetch?: typeof fetch;
  simdi?: () => Date;
}

interface Kuyruktaki {
  event: string;
  properties: Ozellikler & { distinct_id: string };
  timestamp: string;
}

export interface Olcum {
  olay(ad: string, ozellik?: Ozellikler): void;
  /** Kuyruğu gönderir; asla hata atmaz. */
  gonder(): Promise<void>;
  /** Zamanlayıcıyı durdurur. */
  kapat(): void;
  /** Test ve tanıtım sayfası için. */
  readonly kuyruk: readonly Kuyruktaki[];
  readonly durdu: boolean;
}

const KUYRUK_SINIRI = 500;
const AD = /^[a-z][a-z0-9_]{0,39}$/;
const OZELLIK_SINIRI = 30;

export function temizOzellikler(o: Ozellikler | undefined): Ozellikler {
  const r: Ozellikler = {};
  let n = 0;
  for (const [k, v] of Object.entries(o ?? {})) {
    if (n >= OZELLIK_SINIRI || !AD.test(k)) continue;
    if (v === null || typeof v === "boolean") r[k] = v;
    else if (typeof v === "number" && Number.isFinite(v)) r[k] = v;
    else if (typeof v === "string") r[k] = v.slice(0, 200);
    else continue;
    n++;
  }
  return r;
}

export async function olcumBaslat(a: OlcumAyari): Promise<Olcum> {
  const izinli = new Set<string>([...CEKIRDEK_OLAYLAR, ...(a.uzantiOlaylar ?? [])]);
  const adres = (a.adres ?? "https://eu.i.posthog.com").replace(/\/$/, "");
  const f = a.fetch ?? globalThis.fetch.bind(globalThis);
  const simdi = a.simdi ?? (() => new Date());
  const KEY = `oyun-ortak:olcum:${a.oyunId}`;
  const test = /^t-([a-z0-9]+)-/.exec(a.cihaz)?.[1] ?? null;
  let durdu = !a.anahtar;
  let gonderiliyor: Promise<void> | null = null;

  let kuyruk: Kuyruktaki[] = [];
  try {
    const ham = await a.depo.oku(KEY);
    const v: unknown = ham ? JSON.parse(ham) : [];
    if (Array.isArray(v)) kuyruk = v.slice(-KUYRUK_SINIRI);
  } catch {
    kuyruk = [];
  }

  const sakla = () => {
    a.depo.yaz(KEY, JSON.stringify(kuyruk)).catch(() => {});
  };

  const gonder = (): Promise<void> => {
    if (durdu || kuyruk.length === 0) return Promise.resolve();
    if (gonderiliyor) return gonderiliyor;
    const parti = kuyruk.slice(0, 100);
    gonderiliyor = (async () => {
      try {
        const r = await f(`${adres}/batch/`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ api_key: a.anahtar, batch: parti }),
          keepalive: true,
        });
        if (r.ok) {
          kuyruk = kuyruk.slice(parti.length);
          sakla();
        } else if (r.status >= 400 && r.status < 500 && r.status !== 429) {
          // Anahtar yanlış, kota kapalı ya da istek reddedildi: tekrar etmenin anlamı yok.
          durdu = true;
          kuyruk = [];
          sakla();
        }
      } catch {
        /* ağ yok: kuyrukta kalır */
      } finally {
        gonderiliyor = null;
      }
    })();
    return gonderiliyor;
  };

  const zamanlayici =
    (a.aralik ?? 30_000) > 0 ? setInterval(() => void gonder(), a.aralik ?? 30_000) : undefined;
  (zamanlayici as { unref?: () => void } | undefined)?.unref?.();

  return {
    olay(ad, ozellik) {
      if (durdu || !izinli.has(ad)) return;
      kuyruk.push({
        event: ad,
        properties: {
          ...temizOzellikler(ozellik),
          distinct_id: a.cihaz,
          oyun_id: a.oyunId,
          surum: a.surum,
          platform: a.platform,
          test,
        },
        timestamp: simdi().toISOString(),
      });
      if (kuyruk.length > KUYRUK_SINIRI) kuyruk = kuyruk.slice(-KUYRUK_SINIRI);
      sakla();
      if (kuyruk.length >= (a.topluSinir ?? 20)) void gonder();
    },
    gonder,
    kapat: () => clearInterval(zamanlayici),
    get kuyruk() {
      return kuyruk;
    },
    get durdu() {
      return durdu;
    },
  };
}
