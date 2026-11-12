/**
 * bildirim: günlük yerel hatırlatma. Sunucu yok, ücret yok, izin yalnız cihazda.
 *
 * Önümüzdeki 7 gün için tek tek hatırlatma kurulur; o gün oynandıysa (`oynandi`) bugünkü atlanır.
 * Kalıcı tekrar yerine tarihli bildirim kullanılır, çünkü tekrarlayan bildirimde "bugün oynadı, atla" yapılamaz.
 * Uygulama her açıldığında `yenile` çağrılır; böylece pencere hep 7 gün ileri kayar.
 *
 * Yerel bildirim eklentisi (ör. @capacitor/local-notifications) oyunun bağımlılığıdır; oyun onu `YerelBildirim`e sarar.
 * Sunucudan push (FCM/APNs) Firebase projesi açılınca eklenecek.
 */
import type { Depo } from "../kayit/index.ts";
import { istanbulGunu } from "../siralama/zaman.ts";

export interface YerelBildirim {
  izinIste(): Promise<boolean>;
  planla(liste: { id: number; baslik: string; metin: string; zaman: Date }[]): Promise<void>;
  iptal(idler: number[]): Promise<void>;
}

export interface HatirlatmaAyari {
  acik: boolean;
  /** İstanbul saatiyle. */
  saat: number;
  dakika: number;
  baslik: string;
  metin: string;
}

export interface BildirimAyari {
  yerel: YerelBildirim;
  depo: Depo;
  /** Bildirim kimliklerinin başlangıcı; oyunun başka bildirimleriyle çakışmasın (varsayılan 7100). */
  kimlikTabani?: number;
  simdi?: () => Date;
}

const GUN = 7;
const KEY = "oyun-ortak:hatirlatma";

/** Kurulacak hatırlatma zamanları (saf; test edilir). */
export function hatirlatmaZamanlari(simdi: Date, saat: number, dakika: number, sonOynanan: string | null): Date[] {
  const bugun = istanbulGunu(simdi);
  const sonuc: Date[] = [];
  for (let i = 0; i < GUN + 1 && sonuc.length < GUN; i++) {
    const d = new Date(`${bugun}T00:00:00+03:00`);
    d.setUTCDate(d.getUTCDate() + i);
    const gun = istanbulGunu(new Date(d.getTime() + 12 * 3_600_000));
    const z = new Date(`${gun}T${String(saat).padStart(2, "0")}:${String(dakika).padStart(2, "0")}:00+03:00`);
    if (z <= simdi) continue;
    if (gun === sonOynanan) continue;
    sonuc.push(z);
  }
  return sonuc;
}

export async function bildirimBaslat(a: BildirimAyari) {
  const taban = a.kimlikTabani ?? 7100;
  const simdi = a.simdi ?? (() => new Date());
  const idler = Array.from({ length: GUN + 1 }, (_, i) => taban + i);
  type Durum = { ayar: HatirlatmaAyari | null; sonOynanan: string | null };
  let d: Durum;
  try {
    d = JSON.parse((await a.depo.oku(KEY)) ?? "null") ?? { ayar: null, sonOynanan: null };
  } catch {
    d = { ayar: null, sonOynanan: null };
  }
  const yaz = () => a.depo.yaz(KEY, JSON.stringify(d)).catch(() => {});

  async function kur(): Promise<void> {
    await a.yerel.iptal(idler).catch(() => {});
    if (!d.ayar?.acik) return;
    const zamanlar = hatirlatmaZamanlari(simdi(), d.ayar.saat, d.ayar.dakika, d.sonOynanan);
    await a.yerel.planla(zamanlar.map((zaman, i) => ({ id: taban + i, baslik: d.ayar!.baslik, metin: d.ayar!.metin, zaman })));
  }

  return {
    ayar: () => d.ayar,
    /** Oyuncu hatırlatmayı açınca/kapatınca. Açarken izin istenir; verilmezse false döner ve kapalı kalır. */
    async ayarla(ayar: HatirlatmaAyari): Promise<boolean> {
      if (ayar.acik && !(await a.yerel.izinIste())) {
        d.ayar = { ...ayar, acik: false };
        await yaz();
        await kur();
        return false;
      }
      d.ayar = ayar;
      await yaz();
      await kur();
      return true;
    },
    /** Günün oyunu oynandı: bugünkü hatırlatma atlanır. */
    async oynandi(): Promise<void> {
      d.sonOynanan = istanbulGunu(simdi());
      await yaz();
      await kur();
    },
    /** Uygulama açılışında: 7 günlük pencereyi ileri kaydırır. */
    yenile: kur,
  };
}
