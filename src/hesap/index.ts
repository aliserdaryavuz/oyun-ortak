/**
 * hesap: misafir (anonim oturum) → Google / Apple / e-posta kodu; takma ad; bulut kaydı; silme.
 *
 * Misafir: oyuncu hiç giriş yapmadan oynar. Sunucuya ilk iş gerektiğinde (skor gönderimi vb.) anonim oturum açılır.
 * Kalıcı hesaba geçiş her yöntemde aynı yoldan yürür: anonim oturum kısa ömürlü bir devir kodu alır,
 * oyuncu girer, `hesap_devral` anonim hesabın sunucu satırlarını yeni ya da var olan hesaba taşır.
 * Yerel kayıt, oyunun birleştirme işleviyle bulut kaydına katılır (KM-3, EN-5, HK-4).
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Depo } from "../kayit/index.ts";

export type Saglayici = "google" | "apple";

export interface Ben {
  ad: string | null;
  ad_otomatik: boolean;
  ad_degisti: string | null;
  kademe: number;
  seviye_puani: number;
  baglama_odulu: string | null;
  yas_onay: string | null;
  anonim: boolean;
}

export type AdSonucu =
  | { durum: "ok"; ad: string }
  | { durum: "bicim" | "uygunsuz" | "alinmis" }
  | { durum: "bekle"; bekle_gun: number };

export interface GirisSonucu {
  /** Anonim hesaptan taşınan verinin olduğu oyunlar. */
  devredilen: string[];
  /** Devir kodu süresi dolmuş ya da geçersizse true; anonim hesabın sunucu verisi taşınamadı. */
  devirBasarisiz?: boolean;
}

export interface Birlesim<T> {
  kayit: T;
  /** Oyuncuya gösterilecek kısa özet (ör. "12 seviye ve 5 gün eklendi"). */
  ozet?: string;
}

export interface HesapAyari {
  supabase: SupabaseClient;
  oyunId: string;
  /** Web yönlendirmeli girişte devir kodunu sayfa yenilemesine taşımak için. */
  depo: Depo;
}

const DEVIR = "oyun-ortak:devir";

export function hesapBaslat(a: HesapAyari) {
  const sb = a.supabase;
  const ortak = () => sb.schema("ortak");

  async function rpc<T>(ad: string, arg?: Record<string, unknown>): Promise<T> {
    const { data, error } = await ortak().rpc(ad, arg);
    if (error) throw new Error(error.message);
    return data as T;
  }

  const oturum = async () => (await sb.auth.getSession()).data.session;

  /** Kalıcı girişin ortak gövdesi: anonimse devir kodu al, gir, devral. */
  async function kaliciGiris(gir: () => Promise<{ error: unknown }>, kodHazir?: string | null): Promise<GirisSonucu> {
    const s = await oturum();
    const kod = kodHazir ?? (s?.user.is_anonymous ? await rpc<string>("devir_kodu_al") : null);
    const { error } = await gir();
    if (error) throw error instanceof Error ? error : new Error(String((error as { message?: string }).message ?? error));
    if (!kod) return { devredilen: [] };
    try {
      const r = await rpc<{ oyunlar: string[] }>("hesap_devral", { p_kod: kod });
      return { devredilen: r.oyunlar };
    } catch {
      return { devredilen: [], devirBasarisiz: true };
    }
  }

  return {
    supabase: sb,

    async kullanici() {
      const s = await oturum();
      return s ? { id: s.user.id, anonim: s.user.is_anonymous === true, eposta: s.user.email ?? null } : null;
    },

    /** Oturum yoksa anonim oturum açar. Sunucuya ilk iş gerektiğinde çağrılır. */
    async anonimGir(): Promise<string> {
      const s = await oturum();
      if (s) return s.user.id;
      const { data, error } = await sb.auth.signInAnonymously();
      if (error || !data.user) throw error ?? new Error("anonim_giris");
      return data.user.id;
    },

    /** Yerel Google/Apple eklentisinden gelen kimlik jetonuyla giriş (Android/iOS). */
    idTokenIleGir(saglayici: Saglayici, token: string, nonce?: string) {
      return kaliciGiris(() => sb.auth.signInWithIdToken({ provider: saglayici, token, nonce }));
    },

    /** Web'de yönlendirmeli giriş. Dönüşte `webDonusunuTamamla` çağrılır. */
    async webIleGir(saglayici: Saglayici, donusAdresi: string): Promise<void> {
      const s = await oturum();
      if (s?.user.is_anonymous) await a.depo.yaz(DEVIR, await rpc<string>("devir_kodu_al"));
      const { error } = await sb.auth.signInWithOAuth({ provider: saglayici, options: { redirectTo: donusAdresi } });
      if (error) throw error;
    },

    /** Yönlendirmeden dönünce (oturum supabase-js tarafından kurulduktan sonra) devri tamamlar. */
    async webDonusunuTamamla(): Promise<GirisSonucu | null> {
      const kod = await a.depo.oku(DEVIR).catch(() => null);
      const s = await oturum();
      if (!kod || !s || s.user.is_anonymous) return null;
      await a.depo.sil(DEVIR).catch(() => {});
      return kaliciGiris(async () => ({ error: null }), kod);
    },

    /** E-posta kodu (yedek yöntem). */
    async epostaKoduGonder(eposta: string): Promise<void> {
      const { error } = await sb.auth.signInWithOtp({ email: eposta, options: { shouldCreateUser: true } });
      if (error) throw error;
    },
    epostaKoduIleGir(eposta: string, kod: string) {
      return kaliciGiris(() => sb.auth.verifyOtp({ email: eposta, token: kod, type: "email" }));
    },

    /** Başka bir giriş yöntemi (ör. testlerde parola) için genel kapı; devir aynı biçimde işler. */
    disGiris: (gir: () => Promise<{ error: unknown }>) => kaliciGiris(gir),

    async cikis() {
      await sb.auth.signOut();
    },

    ben: () => rpc<Ben>("ben", { p_oyun: a.oyunId }),
    yasOnayla: () => rpc<void>("yas_onayla"),
    adDegistir: (ad: string) => rpc<AdSonucu>("ad_degistir", { p_oyun: a.oyunId, p_ad: ad, p_otomatik: false }),

    /** Önekli otomatik ad (KM-4, EN-6): "Bekçi4821". Elle seçilmiş adı ezmez, 30 gün hakkını harcamaz. */
    async otomatikAd(onekler: readonly string[], rastgele: () => number = Math.random): Promise<AdSonucu> {
      let son: AdSonucu = { durum: "alinmis" };
      for (let i = 0; i < 6; i++) {
        const onek = onekler[Math.floor(rastgele() * onekler.length)] ?? "Oyuncu";
        const ad = `${onek}${1000 + Math.floor(rastgele() * 9000)}`;
        son = await rpc<AdSonucu>("ad_degistir", { p_oyun: a.oyunId, p_ad: ad, p_otomatik: true });
        if (son.durum !== "alinmis") return son;
      }
      return son;
    },

    /** İlk kalıcı hesapta bir kez verilen kozmetik ödül kimliği; verildiyse null. */
    baglamaOdulu: () => rpc<string | null>("baglama_odulu_al", { p_oyun: a.oyunId }),

    bulutKaydi<T>() {
      const oku = () => rpc<{ veri: T; surum: number } | null>("kayit_oku", { p_oyun: a.oyunId });
      return {
        oku,
        /**
         * Yerel kaydı bulut kaydıyla oyunun işleviyle birleştirip yazar. Arada başka cihaz yazdıysa
         * yeniden okur ve yeniden birleştirir (iyimser kilit).
         */
        async birlestir(yerel: T, birlestir: (yerel: T, uzak: T) => Birlesim<T>): Promise<Birlesim<T>> {
          for (let i = 0; i < 4; i++) {
            const uzak = await oku();
            const b = uzak ? birlestir(yerel, uzak.veri) : { kayit: yerel };
            const s = await rpc<number | null>("kayit_yaz", { p_oyun: a.oyunId, p_veri: b.kayit, p_surum: uzak?.surum ?? 0 });
            if (s != null) return b;
          }
          throw new Error("kayit_cakisma");
        },
      };
    },

    hesapOzeti: () => rpc<{ oyun_id: string; ad: string }[]>("hesap_ozeti"),
    /** "Bu oyundaki verimi sil": hesap ve öbür oyunlar kalır. */
    buOyundanSil: () => rpc<void>("oyun_verisini_sil", { p_oyun: a.oyunId }),
    /** "Hesabımı tamamen sil": bütün oyunlar; sonra oturum kapanır. */
    async tamamenSil() {
      await rpc<void>("hesabi_sil");
      await sb.auth.signOut({ scope: "local" });
    },
  };
}

export type Hesap = ReturnType<typeof hesapBaslat>;
