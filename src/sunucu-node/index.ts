/**
 * sunucu-node: oyunun kendi Node sunucusu (ör. Sticky Ten'in Render'daki Socket.IO sunucusu) için (ST-4).
 *
 * - `jetonDogrulayici`: istemcinin gönderdiği Supabase oturum jetonunu (JWT) doğrular. İmza (JWKS ya da Supabase Auth),
 *   süre (`exp`), `aud = authenticated` ve `role = authenticated` denetlenir. Geçersiz, süresi geçmiş ya da sahte jeton → null.
 *   Ek bağımlılık yok: supabase-js `auth.getClaims` kullanılır.
 * - `servisIstemcisi`: servis rolüyle yazan istemci (yalnız sunucuda; servis anahtarı istemciye asla gitmez).
 *
 * Socket.IO örneği:
 *   const dogrula = jetonDogrulayici({ url: process.env.SUPABASE_URL!, anahtar: process.env.SUPABASE_ANON_KEY! });
 *   io.use(async (soket, ileri) => {
 *     const oyuncu = await dogrula(soket.handshake.auth?.jeton);
 *     if (!oyuncu) return ileri(new Error("giris_gerekli"));
 *     soket.data.oyuncu = oyuncu;
 *     ileri();
 *   });
 * Jetonun süresi bağlantı açıkken dolabilir: istemci yenilenen jetonu (supabase-js `onAuthStateChange`) olayla
 * yeniden gönderir, sunucu yeniden doğrular.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export interface DogrulanmisOyuncu {
  id: string;
  anonim: boolean;
  eposta: string | null;
  /** Jetonun bitiş anı (ms). */
  bitis: number;
}

export function jetonDogrulayici(a: { url: string; anahtar: string }) {
  const sb = createClient(a.url, a.anahtar, { auth: { persistSession: false, autoRefreshToken: false } });
  return async (jeton: unknown): Promise<DogrulanmisOyuncu | null> => {
    if (typeof jeton !== "string" || jeton.length < 20 || jeton.length > 8192) return null;
    try {
      const { data, error } = await sb.auth.getClaims(jeton);
      if (error || !data) return null;
      const c = data.claims as Record<string, unknown>;
      const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
      if (c.role !== "authenticated" || !aud.includes("authenticated") || typeof c.sub !== "string") return null;
      const bitis = Number(c.exp) * 1000;
      if (!Number.isFinite(bitis) || bitis <= Date.now()) return null;
      return { id: c.sub, anonim: c.is_anonymous === true, eposta: typeof c.email === "string" ? c.email : null, bitis };
    } catch {
      return null;
    }
  };
}

/** Servis rolüyle istemci. `sema` verilirse varsayılan şema odur (ör. "sticky"). */
export function servisIstemcisi(a: { url: string; servisAnahtari: string; sema?: string }): SupabaseClient<any, any> {
  return createClient(a.url, a.servisAnahtari, {
    db: { schema: a.sema ?? "public" },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
