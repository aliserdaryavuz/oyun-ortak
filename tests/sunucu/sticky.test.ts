// Sticky Ten (sticky şeması): ST-1 yazma kuralları ve tek işlemli oyun sonucu, ST-2 sıralamanın bugünkü
// accounts.ts ile eşitliği ve haftalık ödül, ST-3 takip, ST-4 Node jeton doğrulama, ortak silme yolu.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { jetonDogrulayici, servisIstemcisi } from "../../src/sunucu-node/index.ts";
import { istemci, kaliciGir, sql, URL } from "./yardimci.ts";

after(() => sql.end());

const ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";
const SERVIS =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

/** SQL ile adlı oyuncu (auth.users + ortak.oyuncular('sticky')). */
async function oyuncu(ad: string | null = `st_${Math.floor(Math.random() * 1e9)}`) {
  const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous) values (gen_random_uuid(), 'authenticated', 'authenticated', false) returning id`;
  await sql`insert into ortak.oyuncular (oyun_id, kullanici_id, ad, ad_anahtari) values ('sticky', ${id}, ${ad}, ${ad ? sql`ortak.ad_anahtari(${ad})` : null})`;
  return { id: id as string, ad };
}

test("ST-1: istemci sticky tablolarına dokunamaz ve oyun_sonu çağıramaz; servis tek işlemde yazar", async () => {
  const c = istemci();
  await hesapBaslat({ supabase: c, oyunId: "sticky", depo: bellekDepo() }).anonimGir();
  for (const t of ["stats", "rating_log", "rated_pairs", "handoff", "follows"]) {
    assert.ok((await c.schema("sticky").from(t).select("*").limit(1)).error, `${t} okunabildi`);
    assert.ok((await c.schema("sticky").from(t).insert({})).error, `${t} yazılabildi`);
  }
  assert.match((await c.schema("sticky").rpc("oyun_sonu", { p_oyuncular: [], p_gun: "2026-11-13" })).error?.message ?? "", /permission denied/);

  const a = await oyuncu();
  const b = await oyuncu();
  const y = servisIstemcisi({ url: URL, servisAnahtari: SERVIS, sema: "sticky" });
  const oyna = (gun: string, da: number, db: number) =>
    y.rpc("oyun_sonu", {
      p_oyuncular: [
        { user_id: a.id, score: 120, won: true, delta: da },
        { user_id: b.id, score: 80, won: false, delta: db },
      ],
      p_gun: gun, p_ciftler: [`${a.id}|${b.id}`],
    });
  const r1 = await oyna("2026-11-13", 16, -16);
  assert.equal(r1.error, null);
  assert.deepEqual(r1.data, [
    { user_id: a.id, rating: 1216, rated_games: 1, rated_today: 1 },
    { user_id: b.id, rating: 1184, rated_games: 1, rated_today: 1 },
  ]);
  await oyna("2026-11-13", 8, -8);
  const r3 = await oyna("2026-11-14", 4, -4); // gün değişince bugünkü sayaç sıfırlanır
  assert.equal(r3.data[0].rated_today, 1);
  const [s] = await sql`select games, wins, total_score, best_score, rating, rated_games, rated_day from sticky.stats where user_id = ${a.id}`;
  assert.deepEqual({ ...s }, { games: 3, wins: 3, total_score: 360, best_score: 120, rating: 1228, rated_games: 3, rated_day: "2026-11-14" });
  assert.equal((await sql`select count(*)::int as n from sticky.rating_log where user_id = ${a.id}`)[0]!.n, 3);
  assert.equal((await sql`select count(*)::int as n from sticky.rated_pairs where pair = ${a.id + "|" + b.id}`)[0]!.n, 3);
  // Puansız oyun (delta yok): yalnız istatistik
  await y.rpc("oyun_sonu", { p_oyuncular: [{ user_id: a.id, score: 50, won: false }], p_gun: "2026-11-14" });
  const [s2] = await sql`select games, rated_games from sticky.stats where user_id = ${a.id}`;
  assert.deepEqual({ ...s2 }, { games: 4, rated_games: 3 });
});

// ---- ST-2: accounts.ts'teki mantığın aynısı (periodStart + bellek deposundaki ranking)
const PERIODS = { gun: 3, hafta: 5, ay: 10, tum: 10 } as const;
function periodStart(p: keyof typeof PERIODS, now = Date.now()): number | null {
  if (p === "tum") return null;
  const IST = 3 * 3600_000;
  const d = new Date(now + IST);
  const start = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), p === "ay" ? 1 : d.getUTCDate());
  return start - (p === "hafta" ? ((d.getUTCDay() + 6) % 7) * 86_400_000 : 0) - IST;
}

test("ST-2: dört dönem bugünkü accounts.ts ranking sonucuyla aynı", async () => {
  const simdi = Date.now();
  const kisiler = await Promise.all(Array.from({ length: 6 }, () => oyuncu()));
  const adsiz = await oyuncu(null); // adı olmayan sıralamaya girmez
  const kayit: { id: string; at: number; delta: number }[] = [];
  const stats = new Map<string, { rating: number; games: number }>();
  // Her kişiye farklı zamanlarda (bugün, bu hafta, bu ay, 35 gün önce) farklı sayıda oyun
  const zamanlar = [0, 2 * 3600_000, 3 * 86_400_000, 12 * 86_400_000, 35 * 86_400_000];
  [...kisiler, adsiz].forEach((k, i) => {
    let rating = 1200;
    let games = 0;
    for (let j = 0; j < 4 + i * 2; j++) {
      const at = simdi - zamanlar[j % zamanlar.length]! - j * 1000;
      const delta = ((i * 7 + j * 3) % 11) - 4.5; // .5'li, kayan nokta toplamı tam
      kayit.push({ id: k.id, at, delta });
      rating += delta;
      games++;
    }
    stats.set(k.id, { rating, games });
  });
  for (const l of kayit) await sql`insert into sticky.rating_log (user_id, at, delta) values (${l.id}, ${new Date(l.at)}, ${l.delta})`;
  for (const [id, s] of stats)
    await sql`insert into sticky.stats (user_id, rating, rated_games) values (${id}, ${s.rating}, ${s.games})`;
  const ad = new Map([...kisiler, adsiz].map((k) => [k.id, k.ad]));
  const bizim = new Set(kisiler.map((k) => k.id));

  for (const p of ["gun", "hafta", "ay", "tum"] as const) {
    const since = periodStart(p, simdi);
    let rows: { name: string; value: number; games: number }[];
    if (since === null) rows = [...stats].map(([id, s]) => ({ name: ad.get(id)!, value: s.rating, games: s.games }));
    else {
      const m = new Map<string, { name: string; value: number; games: number }>();
      for (const l of kayit)
        if (l.at >= since) {
          const r = m.get(l.id) ?? { name: ad.get(l.id)!, value: 0, games: 0 };
          r.value += l.delta;
          r.games++;
          m.set(l.id, r);
        }
      rows = [...m.values()];
    }
    const beklenen = rows.filter((r) => r.name && r.games >= PERIODS[p]).sort((a, b) => b.value - a.value || b.games - a.games);
    const { satirlar } = (await sql`select sticky.siralama(${p}, 500, ${since === null ? null : new Date(since)}) as r`)[0]!.r as {
      satirlar: { ad: string; deger: number; oyun: number }[];
    };
    const gercek = satirlar.filter((s) => [...bizim].some((id) => ad.get(id) === s.ad));
    assert.deepEqual(
      gercek.map((s) => [s.ad, Number(s.deger), s.oyun]),
      beklenen.map((r) => [r.name, r.value, r.games]),
      p,
    );
  }
  // Herkese açık: anon okuyabilir, kimlik dönmez
  const { data, error } = await istemci().schema("sticky").rpc("siralama", { p_donem: "tum" });
  assert.equal(error, null);
  assert.ok((data as { satirlar: object[] }).satirlar.every((s) => !("user_id" in s) && !("id" in s)));
});

test("ST-2: haftalık ödül — biten haftada ilk 10'a rozet, ilk 3'e kart arkası (en az 5 oyun)", async () => {
  const [{ hafta }] = await sql`select (date_trunc('week', now() at time zone 'Europe/Istanbul') - interval '14 days')::date::text as hafta`;
  const bas = new Date(`${hafta}T12:00:00+03:00`).getTime();
  // Testin haftası yalnız bu testin verisini taşısın (yığın sıfırlanmadan tekrar koşulabilir)
  await sql`delete from sticky.rating_log where at >= ${new Date(`${hafta}T00:00:00+03:00`)} and at < ${new Date(new Date(`${hafta}T00:00:00+03:00`).getTime() + 7 * 86_400_000)}`;
  await sql`delete from ortak.oduller where oyun_id = 'sticky' and kaynak = ${"hafta:" + hafta}`;
  const kisiler = await Promise.all(Array.from({ length: 12 }, () => oyuncu()));
  for (const [i, k] of kisiler.entries())
    for (let j = 0; j < 5; j++) await sql`insert into sticky.rating_log (user_id, at, delta) values (${k.id}, ${new Date(bas + j * 3600_000)}, ${20 - i})`;
  const azOynayan = await oyuncu();
  for (let j = 0; j < 4; j++) await sql`insert into sticky.rating_log (user_id, at, delta) values (${azOynayan.id}, ${new Date(bas)}, 100)`;

  await sql`select sticky.haftalik_odul(${hafta}::date)`;
  await sql`select sticky.haftalik_odul(${hafta}::date)`; // tekrar zararsız
  const od = await sql`select kullanici_id, odul from ortak.oduller where oyun_id = 'sticky' and kaynak = ${"hafta:" + hafta}`;
  const kim = (odul: string) => new Set(od.filter((r) => r.odul === odul).map((r) => r.kullanici_id));
  assert.deepEqual(kim(`sira:hafta-ilk3:${hafta}`), new Set(kisiler.slice(0, 3).map((k) => k.id)));
  assert.deepEqual(kim(`sira:hafta-ilk10:${hafta}`), new Set(kisiler.slice(0, 10).map((k) => k.id)));
});

test("ST-3: takip — et, zaten, kendin, bulunamadı, sınır 100, bırak, liste", async () => {
  const ben = await oyuncu();
  const hedef = await oyuncu();
  const t = (ad: string) => sql`select sticky.takip_et(${ben.id}, ${ad}) as r`.then((r) => r[0]!.r);
  assert.equal(await t(hedef.ad!), "ok");
  assert.equal(await t(hedef.ad!.toUpperCase()), "zaten");
  assert.equal(await t(ben.ad!), "kendin");
  assert.equal(await t("yok_boyle_biri"), "bulunamadi");
  const liste = (await sql`select sticky.takip_ettiklerim(${ben.id}) as l`)[0]!.l;
  assert.deepEqual(liste, [{ id: hedef.id, ad: hedef.ad }]);
  await sql`select sticky.takibi_birak(${ben.id}, ${hedef.ad})`;
  assert.deepEqual((await sql`select sticky.takip_ettiklerim(${ben.id}) as l`)[0]!.l, []);

  const yuz = await Promise.all(Array.from({ length: 101 }, () => oyuncu()));
  for (const k of yuz.slice(0, 100)) assert.equal(await t(k.ad!), "ok");
  assert.equal(await t(yuz[100]!.ad!), "sinir");
});

test("ST-4: Node jeton doğrulama — geçerli kabul; süresi geçmiş, sahte imzalı ve anon anahtar reddedilir", async () => {
  const dogrula = jetonDogrulayici({ url: URL, anahtar: ANON });
  const c = istemci();
  const id = await hesapBaslat({ supabase: c, oyunId: "sticky", depo: bellekDepo() }).anonimGir();
  const jeton = (await c.auth.getSession()).data.session!.access_token;
  const o = await dogrula(jeton);
  assert.equal(o?.id, id);
  assert.equal(o?.anonim, true);

  const b64 = (v: object) => Buffer.from(JSON.stringify(v)).toString("base64url");
  const imzala = (yuk: object, sir: string) => {
    const g = `${b64({ alg: "HS256", typ: "JWT" })}.${b64(yuk)}`;
    return `${g}.${createHmac("sha256", sir).update(g).digest("base64url")}`;
  };
  const YEREL_SIR = "super-secret-jwt-token-with-at-least-32-characters-long"; // Supabase CLI'ın yerel demo sırrı
  const yuk = { sub: id, role: "authenticated", aud: "authenticated", iat: 1_700_000_000 };
  assert.equal(await dogrula(imzala({ ...yuk, exp: Math.floor(Date.now() / 1000) - 60 }, YEREL_SIR)), null, "süresi geçmiş");
  assert.equal(await dogrula(imzala({ ...yuk, exp: Math.floor(Date.now() / 1000) + 3600 }, "baska-bir-sir-en-az-32-karakter-olan-x")), null, "sahte imza");
  assert.equal(await dogrula(ANON), null, "anon anahtarı oyuncu değildir");
  assert.equal(await dogrula("çöp"), null);
  assert.equal(await dogrula(undefined), null);
});

test("silme: bu oyundan sil sticky verisini, takipleri ve ikili sayaçları temizler", async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "sticky", depo: bellekDepo() });
  const id = await kaliciGir(h);
  await h.adDegistir(`silsticky${Math.floor(Math.random() * 1e6)}`);
  const diger = await oyuncu();
  await sql`select sticky.oyun_sonu(${sql.json([{ user_id: id, score: 1, won: true, delta: 5 }])}, '2026-11-13', ${[`${diger.id}|${id}`]})`;
  await sql`insert into sticky.follows (user_id, follows_id) values (${diger.id}, ${id})`;
  await h.buOyundanSil();
  const [r] = await sql`select
    (select count(*) from sticky.stats where user_id = ${id})::int
    + (select count(*) from sticky.rating_log where user_id = ${id})::int
    + (select count(*) from sticky.rated_pairs where position(${id} in pair) > 0)::int
    + (select count(*) from sticky.follows where user_id = ${id} or follows_id = ${id})::int as n`;
  assert.equal(r!.n, 0);
});
