// Beat Greedy (sezgi) şemasının ortak projedeki davranışı. Oyunun kendi kural testleri sezgi deposunda
// (tools/servertest); burada yalnız şemanın erişilebilirliği, zamanlanmış işler ve ortak silme yolu denetlenir.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { istemci, sql } from "./yardimci.ts";

after(() => sql.end());

const oyuncu = async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "sezgi", depo: bellekDepo() });
  const id = await h.anonimGir();
  return { c, h, id, sezgi: () => c.schema("sezgi") };
};

test("sezgi şeması API'de: profil kendi satırını yazar, başkası okuyabilir, başkasının adına yazamaz", async () => {
  const a = await oyuncu();
  const ad = `bg_${Math.floor(Math.random() * 1e8)}`;
  assert.equal((await a.sezgi().from("profiles").insert({ id: a.id, username: ad })).error, null);
  const b = await oyuncu();
  const { data } = await b.sezgi().from("profiles").select("username").eq("id", a.id);
  assert.deepEqual(data, [{ username: ad }]);
  assert.ok((await b.sezgi().from("profiles").insert({ id: a.id, username: "baska_ad" })).error);
  assert.ok((await b.sezgi().from("profiles").insert({ id: b.id, username: "sik" })).error, "küfür süzgeci");
});

test("zamanlanmış işlerin çağırdığı fonksiyonlar sezgi şemasında çalışır", async () => {
  for (const f of ["expire_attempts", "refresh_boards", "update_beaten_targets", "purge_attempt_details"])
    await sql.unsafe(`select sezgi.${f}()`);
  const isler = await sql`select jobname, command from cron.job where jobname like 'sezgi-%' order by 1`;
  assert.equal(isler.length, 6); // sezgi'nin 5 işi + silinen_oyuncular temizliği
  for (const j of isler) assert.doesNotMatch(j.command, /public\./, j.jobname);
});

test("BG-1: kullanıcı adı ortak kurallarla denetlenip ortak kayda yansır (süzgeç, 30 gün, benzersizlik)", async () => {
  const a = await oyuncu();
  const ad = `bg_ad${Math.floor(Math.random() * 1e8)}`;
  assert.equal((await a.sezgi().from("profiles").insert({ id: a.id, username: ad })).error, null);
  const oku = async (id: string) => (await sql`select ad from ortak.oyuncular where oyun_id = 'sezgi' and kullanici_id = ${id}`)[0]?.ad;
  assert.equal(await oku(a.id), ad);
  // 30 gün dolmadan değiştirilemez
  const yeni = `${ad}x`;
  assert.match((await a.sezgi().from("profiles").update({ username: yeni }).eq("id", a.id)).error?.message ?? "", /ad_bekle/);
  await sql`update ortak.oyuncular set ad_degisti = now() - interval '31 days' where oyun_id = 'sezgi' and kullanici_id = ${a.id}`;
  assert.equal((await a.sezgi().from("profiles").update({ username: yeni }).eq("id", a.id)).error, null);
  assert.equal(await oku(a.id), yeni);
  // "bgad…x" ile "bg_ad…x" ortakta aynı anahtar: ikinci kayıt reddedilir
  const b = await oyuncu();
  assert.match((await b.sezgi().from("profiles").insert({ id: b.id, username: yeni.replace("_", "") })).error?.message ?? "", /ad_alinmis/);
  // sezgi'nin kendi süzgecinden geçen ama ortak süzgece takılan ad
  assert.match((await b.sezgi().from("profiles").insert({ id: b.id, username: "Sik42" })).error?.message ?? "", /ad_uygunsuz/);
});

test("BG-1: şikâyetle sıfırlanan ad Beat Greedy profilinde de değişir ve yeniden alınamaz", async () => {
  const hedef = await oyuncu();
  const ad = `kotu_bg${Math.floor(Math.random() * 1e6)}`;
  await hedef.sezgi().from("profiles").insert({ id: hedef.id, username: ad });
  for (let i = 0; i < 3; i++) {
    const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous, email) values (gen_random_uuid(), 'authenticated', 'authenticated', false, ${`s${crypto.randomUUID()}@test.local`}) returning id`;
    await sql`insert into ortak.oyuncular (oyun_id, kullanici_id, olusturma) values ('sezgi', ${id}, now() - interval '3 days')`;
    // Kimlik ve çağrı aynı işlemde (havuzdaki başka bağlantıya düşmesin)
    await sql.begin(async (t) => {
      await t`select set_config('request.jwt.claims', ${JSON.stringify({ sub: id, role: "authenticated", is_anonymous: false })}, true)`;
      await t`select ortak.sikayet_et('sezgi', ${ad}, 'ad')`;
    });
  }
  const [p] = await sql`select username::text as u from sezgi.profiles where id = ${hedef.id}`;
  assert.match(p!.u, /^oyuncu_[0-9a-f]{10}$/);
  assert.equal((await sql`select ad from ortak.oyuncular where oyun_id = 'sezgi' and kullanici_id = ${hedef.id}`)[0]!.ad, null);
  // aynı ad ne Beat Greedy'den ne ortak yoldan yeniden alınabilir; başka bir ad hemen alınabilir
  assert.match((await hedef.sezgi().from("profiles").update({ username: ad }).eq("id", hedef.id)).error?.message ?? "", /ad_uygunsuz/);
  assert.deepEqual(await hedef.h.adDegistir(ad), { durum: "uygunsuz" });
  assert.equal((await hedef.sezgi().from("profiles").update({ username: `temiz_${Math.floor(Math.random() * 1e6)}` }).eq("id", hedef.id)).error, null);
});

test("BG-1: gün toplamı birikir, hafta 7 gün toplanır; istemci yazamaz; kapanışta kademe atlayana sunucu ödülü", async () => {
  const c = await oyuncu();
  assert.match((await c.c.schema("ortak").rpc("gun_toplami_yaz", { p_oyun: "sezgi", p_kullanici: c.id, p_gun: "2026-11-16", p_toplam: 1 })).error?.message ?? "", /permission denied/);

  const [{ hafta }] = await sql`select (ortak.iso_hafta(ortak.bugun()) - 7)::text as hafta`;
  const gun = (n: number) => { const d = new Date(`${hafta}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const kisiler: string[] = [];
  for (let i = 0; i < 10; i++) {
    const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous) values (gen_random_uuid(), 'authenticated', 'authenticated', false) returning id`;
    kisiler.push(id);
    // Gün içinde artan toplam: son değer geçerli
    await sql`select ortak.gun_toplami_yaz('sezgi', ${id}, ${gun(0)}, 100)`;
    await sql`select ortak.gun_toplami_yaz('sezgi', ${id}, ${gun(0)}, ${1000 + i * 100})`;
    for (let g = 1; g < 7; g++) await sql`select ortak.gun_toplami_yaz('sezgi', ${id}, ${gun(g)}, 10)`;
  }
  const [{ puan }] = await sql`select puan::int from ortak.lig_uyeleri where oyun_id = 'sezgi' and kullanici_id = ${kisiler[0]}`;
  assert.equal(puan, 1000 + 6 * 10); // 7 günün hepsi
  await sql`select ortak.lig_kapat()`;
  const od = await sql`select kullanici_id, odul from ortak.oduller where oyun_id = 'sezgi' and kaynak = ${"lig:" + hafta} and kullanici_id in ${sql(kisiler)}`;
  assert.deepEqual(new Set(od.map((r) => r.kullanici_id)), new Set(kisiler.slice(8)));
  assert.ok(od.every((r) => r.odul === `sira:lig-1-${hafta}`));
});

test("BG-2: İlerleme tablosu yalnız ücretsiz bölümleri (seviye < 4000) sayar; tam sürüm üstünlük vermez", async () => {
  const oyun = `bg2_${Math.floor(Math.random() * 1e8)}`;
  const yap = async (seviyeler: number[]) => {
    const o = await oyuncu();
    await o.sezgi().from("profiles").insert({ id: o.id, username: `ilr_${Math.floor(Math.random() * 1e8)}` });
    for (const [i, level] of seviyeler.entries())
      await sql`insert into sezgi.level_verified (user_id, game, level, raw_stars, value, verified_at)
                values (${o.id}, ${oyun}, ${level}, 3, 1, now() - make_interval(secs => ${100 - i}))`;
    return o.id;
  };
  const ucretsiz = await yap([0, 1, 2001]);          // 9 ücretsiz yıldız
  const tam = await yap([0, 1, 4000, 5000, 7000]);  // 6 ücretsiz + 9 ücretli yıldız
  const satir = async (id: string, game: string) =>
    (await sql`select stars, master3, rank::int from sezgi.board_levels where user_id = ${id} and game = ${game}`)[0];
  assert.deepEqual(await satir(tam, oyun), { stars: 6, master3: 0, rank: 2 });
  assert.deepEqual(await satir(ucretsiz, oyun), { stars: 9, master3: 0, rank: 1 });
  assert.equal((await satir(tam, "all"))!.stars, 6);
  // Yalnız ücretli bölümde yıldızı olan oyuncu tabloda görünmez
  const yalnizTam = await yap([4001]);
  assert.equal(await satir(yalnizTam, oyun), undefined);
});

test("ortak silme yolu: bu oyundan sil sezgi profilini siler; lig kurucusu önce devretmeli", async () => {
  const a = await oyuncu();
  await a.h.ben(); // ortak.oyuncular('sezgi') satırı
  await a.sezgi().from("profiles").insert({ id: a.id, username: `sil_${Math.floor(Math.random() * 1e8)}` });
  await sql`insert into sezgi.leagues (name, owner_id) values ('Deneme Ligi', ${a.id})`;
  await assert.rejects(a.h.buOyundanSil(), /owns_leagues/);
  await sql`delete from sezgi.leagues where owner_id = ${a.id}`;
  await a.h.buOyundanSil();
  const [{ n }] = await sql`select count(*)::int as n from sezgi.profiles where id = ${a.id}`;
  assert.equal(n, 0);
  assert.deepEqual(await a.h.hesapOzeti(), []);
  // Aynı gün profil yeniden açılıp günün bulmacası tekrar oynanamaz
  const { error } = await a.sezgi().from("profiles").insert({ id: a.id, username: `geri_${Math.floor(Math.random() * 1e8)}` });
  assert.match(error?.message ?? "", /ayni_gun_yeniden_profil/);
  // Ertesi gün açılabilir
  await sql`update sezgi.silinen_oyuncular set silindi = now() - interval '1 day' where kullanici_id = ${a.id}`;
  assert.equal((await a.sezgi().from("profiles").insert({ id: a.id, username: `yarin_${Math.floor(Math.random() * 1e8)}` })).error, null);
  // İstek sınırı sayacı silme yolunda sıfırlanmaz
  await sql`insert into sezgi.rate_limits values (${a.id}, 'start_attempt', now(), 30)`;
  await sql`delete from sezgi.leagues where owner_id = ${a.id}`;
  await a.h.buOyundanSil();
  const [{ r }] = await sql`select count(*)::int as r from sezgi.rate_limits where user_id = ${a.id}`;
  assert.equal(r, 1);
});
