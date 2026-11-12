/**
 * Gün ve hafta sınırları (Europe/Istanbul). İstemci kuyruğu ve sunucu (dogrula-<oyun>) aynı dosyayı kullanır;
 * bu dosya ne Node'a ne Deno'ya özgü bir şey içermez.
 */

const GUN_BICIMI = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Istanbul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** Verilen anın İstanbul takvim günü, YYYY-MM-DD. */
export const istanbulGunu = (an: Date = new Date()): string => GUN_BICIMI.format(an);

export const gunGecerli = (gun: string): boolean => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(gun)) return false;
  const d = new Date(`${gun}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === gun;
};

const gunEkle = (gun: string, n: number): string => {
  const d = new Date(`${gun}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

/** ISO haftasının pazartesisi. */
export const isoHafta = (gun: string): string => {
  const gd = new Date(`${gun}T00:00:00Z`).getUTCDay(); // 0 pazar
  return gunEkle(gun, -((gd + 6) % 7));
};

/** Günün İstanbul'da bittiği an (ertesi gün 00:00, UTC+3). Türkiye 2016'dan beri yaz saati uygulamıyor. */
export const gunSonu = (gun: string): Date => new Date(`${gunEkle(gun, 1)}T00:00:00+03:00`);

export interface PencereKurali {
  /** Gün bittikten sonra kaç saat daha kabul edilir (EN-2: 3; kargo-nobeti: 3). */
  gecSaat?: number;
  /** Aynı ISO haftası içinde gönderilen geçmiş gün kabul edilir (KM-5). */
  ayniHafta?: boolean;
}

/**
 * Bir günün skoru şimdi gönderilebilir mi. Gelecek gün hiçbir zaman kabul edilmez.
 * Kural boşsa yalnız bugün.
 */
export function pencereAcik(gun: string, simdi: Date, k: PencereKurali = {}): boolean {
  if (!gunGecerli(gun)) return false;
  const bugun = istanbulGunu(simdi);
  if (gun > bugun) return false;
  if (gun === bugun) return true;
  if (k.gecSaat && simdi.getTime() < gunSonu(gun).getTime() + k.gecSaat * 3_600_000) return true;
  if (k.ayniHafta && isoHafta(gun) === isoHafta(bugun)) return true;
  return false;
}
