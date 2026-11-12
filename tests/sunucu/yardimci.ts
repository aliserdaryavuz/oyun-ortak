/**
 * Sunucu testleri yerel Supabase yığınına (oyun-test) karşı koşar: `npm run db:start`, sonra `npm run test:sunucu`.
 * Anahtarlar Supabase CLI'ın herkesçe bilinen yerel demo anahtarlarıdır; yalnız 127.0.0.1 kabul edilir.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import postgres from "postgres";

export const URL = process.env.SUPABASE_URL ?? "http://127.0.0.1:55321";
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(URL)) throw new Error("Sunucu testleri yalnız yerel yığında koşar");
const ANON =
  process.env.SUPABASE_ANON_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";
const SERVIS =
  process.env.SUPABASE_SERVICE_ROLE_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";
export const DB_URL = process.env.SUPABASE_DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:55322/postgres";
export const MAILPIT = process.env.MAILPIT_URL ?? "http://127.0.0.1:55324";

const ayar = { auth: { persistSession: false, autoRefreshToken: false } };
export const istemci = (): SupabaseClient => createClient(URL, ANON, ayar);
export const yonetici = (): SupabaseClient => createClient(URL, SERVIS, ayar);
export const sql = postgres(DB_URL, { max: 5, onnotice: () => {} });

export const rastgeleEposta = () => `t${crypto.randomUUID().slice(0, 12)}@test.local`;

/** Parolalı kalıcı kullanıcı (gerçek Google/Apple jetonu yerelde üretilemez; devir yolu aynıdır). */
export async function kaliciKullanici() {
  const eposta = rastgeleEposta();
  const parola = `P-${crypto.randomUUID()}`;
  const { data, error } = await yonetici().auth.admin.createUser({ email: eposta, password: parola, email_confirm: true });
  if (error) throw error;
  return { id: data.user.id, eposta, parola };
}

export const ortak = (c: SupabaseClient) => c.schema("ortak");

export async function rpc<T = unknown>(c: SupabaseClient, ad: string, arg?: Record<string, unknown>): Promise<T> {
  const { data, error } = await ortak(c).rpc(ad, arg);
  if (error) throw new Error(error.message);
  return data as T;
}

/** Edge Function'ı doğrudan çağırır (durum kodunu görmek için). */
export async function fonksiyon(c: SupabaseClient | null, ad: string, govde: unknown) {
  const jeton = c ? (await c.auth.getSession()).data.session?.access_token : undefined;
  const r = await fetch(`${URL}/functions/v1/${ad}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: ANON, ...(jeton ? { Authorization: `Bearer ${jeton}` } : {}) },
    body: typeof govde === "string" ? govde : JSON.stringify(govde),
  });
  let veri: unknown = null;
  try {
    veri = await r.json();
  } catch {
    veri = null;
  }
  return { durum: r.status, veri: veri as Record<string, any> };
}

/** Testler arasında oyunun skor/lig tablolarını temizler (kullanıcılar kalır; her test kendi kullanıcısını açar). */
export async function oyunuTemizle(oyun = "deneme") {
  await sql`delete from ortak.lig_gruplari where oyun_id = ${oyun}`;
  await sql`delete from ortak.skorlar where oyun_id = ${oyun}`;
  await sql`delete from ortak.denemeler where oyun_id = ${oyun}`;
  await sql`delete from ortak.hiz_sinirlari`;
}

export const bugun = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Istanbul" }).format(new Date());
