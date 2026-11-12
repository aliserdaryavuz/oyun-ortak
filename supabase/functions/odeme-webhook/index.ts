/**
 * odeme-webhook: RevenueCat olaylarını `ortak.haklar`'a işler. oyun-ortak'tan yayınlanır, JWT istemez;
 * RevenueCat panelindeki "Authorization header" değeri ODEME_WEBHOOK_SIRRI gizlisiyle aynı olmalıdır.
 *
 * Uygulama tarafında RevenueCat kullanıcı kimliği = Supabase kullanıcı kimliği (odeme paketi `logIn` eder).
 * Olaylar: satın alma → hak 'aktif'; tek seferlik üründe CANCELLATION (iade) ve EXPIRATION → 'iade';
 * TRANSFER → haklar yeni kimliğe geçer. Aynı olay iki kez gelirse bir kez işlenir.
 * Kapalı testteki (sandbox) satın almalar da kabul edilir: Play kapalı testi bunlarla yürür.
 */
import { createClient } from "npm:@supabase/supabase-js@2.119.0";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VER = new Set(["INITIAL_PURCHASE", "NON_RENEWING_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE"]);
const MAGAZA: Record<string, string> = {
  PLAY_STORE: "play", APP_STORE: "appstore", MAC_APP_STORE: "appstore",
  STRIPE: "web", RC_BILLING: "web", PADDLE: "web", PROMOTIONAL: "elle",
};

interface Olay {
  id?: string;
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  product_id?: string;
  store?: string;
  transaction_id?: string;
  expiration_at_ms?: number | null;
  transferred_from?: string[];
  transferred_to?: string[];
}

const json = (v: unknown, durum = 200) =>
  new Response(JSON.stringify(v), { status: durum, headers: { "Content-Type": "application/json" } });

/** Uzunluk dışında zamanlamadan bilgi sızdırmayan karşılaştırma. */
function esit(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let fark = 0;
  for (let i = 0; i < a.length; i++) fark |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return fark === 0;
}

const kullanici = (o: Olay): string | null =>
  [o.app_user_id, o.original_app_user_id, ...(o.aliases ?? [])].find((x): x is string => !!x && UUID.test(x)) ?? null;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "yontem" }, 405);
  const sir = Deno.env.get("ODEME_WEBHOOK_SIRRI");
  if (!sir) {
    console.error("[odeme-webhook] ODEME_WEBHOOK_SIRRI tanımlı değil");
    return json({ error: "ayar" }, 500);
  }
  if (!esit(req.headers.get("Authorization") ?? "", sir)) return json({ error: "yetkisiz" }, 401);

  let o: Olay;
  try {
    o = ((await req.json()) as { event?: Olay }).event ?? {};
  } catch {
    return json({ error: "json" }, 400);
  }
  if (!o.id || !o.type) return json({ error: "olay" }, 400);
  if (o.type === "TEST") return json({ sonuc: "test" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    db: { schema: "ortak" },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    if (o.type === "TRANSFER") {
      const kime = (o.transferred_to ?? []).find((x) => UUID.test(x));
      const kimden = (o.transferred_from ?? []).filter((x) => UUID.test(x));
      if (!kime || kimden.length === 0) return json({ sonuc: "yok_sayildi" });
      const { data, error } = await db.rpc("hak_aktar", { p_olay_id: o.id, p_kimden: kimden, p_kime: kime });
      if (error) throw error;
      return json({ sonuc: data });
    }

    const tur = VER.has(o.type)
      ? "ver"
      : o.type === "EXPIRATION" || (o.type === "CANCELLATION" && o.expiration_at_ms == null)
        ? "iade" // tek seferlik üründe CANCELLATION iadedir; abonelikte yalnız yenilemenin kapanmasıdır
        : null;
    if (!tur) return json({ sonuc: "yok_sayildi" });
    const id = kullanici(o);
    if (!id || !o.product_id) return json({ sonuc: "kullanici_yok" });

    const { data, error } = await db.rpc("odeme_olayi", {
      p_olay_id: o.id, p_kullanici: id, p_urun: o.product_id, p_tur: tur,
      p_kaynak: MAGAZA[o.store ?? ""] ?? "elle", p_dis_id: o.transaction_id ?? null,
    });
    if (error) throw error;
    return json({ sonuc: data });
  } catch (e) {
    console.error("[odeme-webhook]", e);
    return json({ error: "ic_hata" }, 500); // RevenueCat yeniden dener
  }
});
