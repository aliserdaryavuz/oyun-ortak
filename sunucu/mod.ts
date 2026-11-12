/**
 * oyun-ortak sunucu kitaplığı: dogrula-<oyun> Edge Function'larının ortak iskeleti (Deno).
 *
 * Oyun deposunda deno.json import map'i:
 *   "@oyun/ortak-sunucu": "https://raw.githubusercontent.com/aliserdaryavuz/oyun-ortak/v0.1.0/sunucu/mod.ts"
 *
 * Sağladıkları (sezgi `_shared/lib.ts` başvurusu):
 *   yalnız POST + CORS; JWT doğrulama (anonim oturum da geçer); gövde okunmadan önce kullanıcı başına ve
 *   oyun başına toplam istek sınırı; gövde boyu kesimi; tek hata biçimi { error, reason? } (ayrıntı yalnız günlükte);
 *   skor yazımı (runId tekrarına dayanıklı, lig ataması dahil); durum tutan deneme (sira ile iyimser kilit).
 */
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";
import { pencereAcik, type PencereKurali } from "../src/siralama/zaman.ts";

export { gunGecerli, isoHafta, istanbulGunu, pencereAcik } from "../src/siralama/zaman.ts";
export type { PencereKurali } from "../src/siralama/zaman.ts";

export interface IstekAyari {
  oyunId: string;
  /** Kullanıcı başına dakikada istek, oyunun bütün doğrulama fonksiyonları toplam (varsayılan 30). */
  kullaniciDakika?: number;
  /** Oyun başına, bütün kullanıcılar toplam dakikada istek (varsayılan 3000): tek oyunun spam'i ortak kotayı yemesin. */
  oyunDakika?: number;
  /** Gövde üst sınırı, bayt (varsayılan 64 KB). */
  govdeSiniri?: number;
}

export interface Deneme<D = Record<string, unknown>> {
  anahtar: string;
  sira: number;
  durum: D;
  bitti: boolean;
  olusturma: string;
}

export interface SkorGirdisi {
  tur: "gunluk" | "etkinlik";
  donem: string;
  puan: number;
  runId: string;
  ikincil?: number | null;
  ligPuani?: number | null;
  ayrinti?: unknown;
  bayraklar?: string[];
  seviyePuani?: number | null;
}

export interface Baglam<G = unknown> {
  kullanici: { id: string; anonim: boolean };
  govde: G;
  /** Servis rolü istemcisi, `ortak` şemasına bağlı. */
  db: SupabaseClient<any, "ortak">;
  simdi: Date;
  tamam(veri: unknown, durum?: number): Response;
  hata(durum: number, neden: string): Response;
  pencereAcik(gun: string, kural?: PencereKurali): boolean;
  hizSiniri(anahtar: string, sinir: number, saniye: number): Promise<boolean>;
  /** Dönüş durumu: yeni | tekrar (aynı runId) | prova (dönemde resmî skor zaten var). */
  skorYaz(s: SkorGirdisi): Promise<{ durum: "yeni" | "tekrar" | "prova"; id?: number }>;
  deneme<D = Record<string, unknown>>(anahtar: string): {
    al(): Promise<Deneme<D>>;
    /**
     * Okunan sıra hâlâ geçerliyse durumu yazar, sırayı artırır; değilse (eş zamanlı yazım, bitmiş deneme) null.
     * Yeniden gönderimi tanımak için oyun, olay günlüğünü durumda tutmalı ve eski sırayla gelen olayı günlükteki
     * olayla karşılaştırmalıdır (aynıysa "tekrar", farklıysa 409). Örnek: supabase/functions/dogrula-deneme.
     */
    ilerlet(sira: number, durum: D, bitti?: boolean): Promise<Deneme<D> | null>;
  };
}

const CORS = {
  "Access-Control-Allow-Origin": "*", // Bearer jetonu, çerez yok: herhangi bir köken güvenli
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (veri: unknown, durum = 200) =>
  new Response(JSON.stringify(veri), { status: durum, headers: { ...CORS, "Content-Type": "application/json" } });

class IstekHatasi extends Error {
  durum: number;
  constructor(durum: number, neden: string) {
    super(neden);
    this.durum = durum;
  }
}

async function govdeOku(req: Request, sinir: number): Promise<unknown> {
  if (!req.body) throw new IstekHatasi(400, "govde_yok");
  const okuyucu = req.body.getReader();
  const parcalar: Uint8Array[] = [];
  let boy = 0;
  for (;;) {
    const { done, value } = await okuyucu.read();
    if (done) break;
    boy += value.byteLength;
    if (boy > sinir) {
      await okuyucu.cancel();
      throw new IstekHatasi(413, "govde_buyuk");
    }
    parcalar.push(value);
  }
  const birlesik = new Uint8Array(boy);
  let i = 0;
  for (const p of parcalar) {
    birlesik.set(p, i);
    i += p.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(birlesik));
  } catch {
    throw new IstekHatasi(400, "json");
  }
}

let yonetici: SupabaseClient<any, "ortak"> | undefined;
let dogrulayici: SupabaseClient | undefined;

export function istek<G = unknown>(ayar: IstekAyari, isle: (c: Baglam<G>) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (req.method !== "POST") return json({ error: "yontem" }, 405);
    const fn = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "?";
    try {
      const url = Deno.env.get("SUPABASE_URL")!;
      yonetici ??= createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
        db: { schema: "ortak" },
        auth: { persistSession: false, autoRefreshToken: false },
      });
      dogrulayici ??= createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const db = yonetici;

      const jeton = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
      if (!jeton) throw new IstekHatasi(401, "giris_gerekli");
      const { data, error } = await dogrulayici.auth.getClaims(jeton);
      const sub = data?.claims?.sub;
      if (error || !sub || data.claims.role !== "authenticated") throw new IstekHatasi(401, "giris_gerekli");
      const kullanici = { id: sub, anonim: data.claims.is_anonymous === true };

      const hizSiniri = async (anahtar: string, sinir: number, saniye: number) => {
        const { data, error } = await db.rpc("hiz_siniri", { p_anahtar: anahtar, p_sinir: sinir, p_saniye: saniye });
        if (error) throw error;
        return data === true;
      };
      // Anahtar istek yolundan üretilmez: yola parça eklenerek sınır atlatılamasın.
      if (!(await hizSiniri(`${ayar.oyunId}:${kullanici.id}`, ayar.kullaniciDakika ?? 30, 60)))
        throw new IstekHatasi(429, "cok_istek");
      if (!(await hizSiniri(`${ayar.oyunId}:toplam`, ayar.oyunDakika ?? 3000, 60)))
        throw new IstekHatasi(429, "cok_istek");

      const govde = (await govdeOku(req, ayar.govdeSiniri ?? 65_536)) as G;
      const simdi = new Date();

      const c: Baglam<G> = {
        kullanici,
        govde,
        db,
        simdi,
        tamam: (v, d = 200) => json(v, d),
        hata: (d, neden) => json({ error: neden }, d),
        pencereAcik: (gun, kural) => pencereAcik(gun, simdi, kural),
        hizSiniri,
        async skorYaz(s) {
          const { data, error } = await db.rpc("skor_yaz", {
            p_oyun: ayar.oyunId,
            p_kullanici: kullanici.id,
            p_tur: s.tur,
            p_donem: s.donem,
            p_puan: s.puan,
            p_run_id: s.runId,
            p_ikincil: s.ikincil ?? null,
            p_lig_puani: s.ligPuani ?? null,
            p_ayrinti: s.ayrinti ?? null,
            p_bayraklar: s.bayraklar ?? [],
            p_seviye_puani: s.seviyePuani ?? null,
          });
          if (error) throw error;
          return data;
        },
        deneme(anahtar) {
          const cevir = (r: any) => (r ? { ...r, durum: r.durum } : null);
          return {
            async al() {
              const { data, error } = await db
                .rpc("deneme_al", { p_oyun: ayar.oyunId, p_kullanici: kullanici.id, p_anahtar: anahtar })
                .single();
              if (error) throw error;
              return cevir(data);
            },
            async ilerlet(sira, durum, bitti = false) {
              const { data, error } = await db
                .rpc("deneme_ilerlet", {
                  p_oyun: ayar.oyunId, p_kullanici: kullanici.id, p_anahtar: anahtar,
                  p_sira: sira, p_durum: durum, p_bitti: bitti,
                })
                .maybeSingle();
              if (error) throw error;
              return data && (data as any).anahtar ? cevir(data) : null;
            },
          };
        },
      };
      return await isle(c);
    } catch (e) {
      if (e instanceof IstekHatasi) return json({ error: e.message }, e.durum);
      console.error(`[${ayar.oyunId}/${fn}]`, e);
      return json({ error: "ic_hata" }, 500);
    }
  };
}
