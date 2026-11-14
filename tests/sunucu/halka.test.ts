// Halka'nın ortak kaydı: ayarlar ortak paketlerde geçerli, "bu oyundan sil" hk_ tablolarını temizler.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { istemci, kaliciKullanici, sql } from "./yardimci.ts";

after(() => sql.end());

test("Halka ad kuralı (2–20) ve ilk bağlama ödülü", async () => {
  const k = await kaliciKullanici();
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "halka", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  assert.equal((await h.adDegistir("x".repeat(21))).durum, "bicim"); // 20'den uzun
  assert.notEqual((await h.adDegistir("Ay")).durum, "bicim"); // 2 karakter Halka'da geçerli (deneme oyununda 3)
  assert.equal(await h.baglamaOdulu(), "desen-porselen");
});

test("bu oyundan sil: hk_entitlements temizlenir, hesap ve öbür oyunlar kalır", async () => {
  const k = await kaliciKullanici();
  await sql`insert into public.hk_entitlements (user_id, product, source) values (${k.id}, 'paket_tam', 'manual')`;
  await sql`insert into ortak.oyuncular (oyun_id, kullanici_id) values ('deneme', ${k.id})`;
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "halka", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await h.ben();
  await h.buOyundanSil();
  const [r] = await sql`select
    (select count(*) from public.hk_entitlements where user_id = ${k.id})::int as n,
    (select count(*) from ortak.oyuncular where kullanici_id = ${k.id} and oyun_id = 'deneme')::int as deneme,
    (select count(*) from auth.users where id = ${k.id})::int as hesap`;
  assert.deepEqual({ ...r }, { n: 0, deneme: 1, hesap: 1 });
});

test("HK-17: eski hk_ nesneleri yok; hatırlatma aboneliği anon role ve misafire kapalı", async () => {
  const [r] = await sql`select to_regclass('public.hk_profiles') as p, to_regclass('public.hk_daily_scores') as s, to_regclass('public.hk_push') as push`;
  assert.deepEqual([r!.p, r!.s, r!.push], [null, null, "hk_push"]);
  const ep = "https://fcm.googleapis.com/fcm/send/hk17-" + crypto.randomUUID();
  const arg = { p_endpoint: ep, p_p256dh: "B".repeat(87), p_auth: "a".repeat(22), p_hour: 9 };
  assert.match((await istemci().rpc("hk_push_save", arg)).error?.message ?? "", /permission denied/);
  const m = istemci();
  await hesapBaslat({ supabase: m, oyunId: "halka", depo: bellekDepo() }).anonimGir();
  assert.match((await m.rpc("hk_push_save", arg)).error?.message ?? "", /kalici_hesap_gerekli/);
  const k = await kaliciKullanici();
  const c = istemci();
  await c.auth.signInWithPassword({ email: k.eposta, password: k.parola });
  assert.equal((await c.rpc("hk_push_save", arg)).error, null);
  assert.equal((await c.rpc("hk_push_remove", { p_endpoint: ep })).error, null);
});
