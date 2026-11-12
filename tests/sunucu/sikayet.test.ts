import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { siralamaBaslat } from "../../src/siralama/index.ts";
import { bugun, istemci, kaliciKullanici, sql } from "./yardimci.ts";

after(() => sql.end());

/** Kalıcı hesap; `yasli` ise oyunda 3 gündür oynuyormuş gibi (şikâyeti sayılır). */
const kalici = async (yasli = true) => {
  const k = await kaliciKullanici();
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await h.ben();
  if (yasli) await sql`update ortak.oyuncular set olusturma = now() - interval '3 days' where kullanici_id = ${k.id}`;
  return { c, h, id: k.id, k };
};
const adli = async (onek: string) => {
  const t = await kalici();
  const ad = `${onek}${Math.floor(Math.random() * 1e6)}`;
  await t.h.adDegistir(ad);
  return { ...t, ad };
};

test("ad şikâyeti: 3 farklı eski oyuncu adı sıfırlar; anonim ve yeni hesap sayılmaz; oyuncu hemen yeni ad seçer", async () => {
  const hedef = await adli("Kotu");
  await siralamaBaslat({ supabase: hedef.c, oyunId: "deneme", depo: bellekDepo() })
    .gonder({ islem: "gunluk", gun: bugun(), kayit: [9], kuralSurumu: 1 });

  const anon = hesapBaslat({ supabase: istemci(), oyunId: "deneme", depo: bellekDepo() });
  await anon.anonimGir();
  await assert.rejects(anon.sikayetEt(hedef.ad, "ad"), /kalici_hesap_gerekli/);

  // yeni açılmış hesapların şikâyeti kaydedilir ama sayılmaz
  for (let i = 0; i < 3; i++) assert.deepEqual(await (await kalici(false)).h.sikayetEt(hedef.ad, "ad"), { durum: "ok", ad_sifirlandi: false });
  assert.equal((await hedef.h.ben()).ad, hedef.ad);

  const s1 = await kalici();
  assert.deepEqual(await s1.h.sikayetEt(hedef.ad, "ad"), { durum: "ok", ad_sifirlandi: false });
  assert.deepEqual(await s1.h.sikayetEt(hedef.ad, "ad"), { durum: "zaten" });
  assert.deepEqual(await hedef.h.sikayetEt(hedef.ad, "ad"), { durum: "kendin" });
  assert.deepEqual(await s1.h.sikayetEt("YokBoyleAd", "ad"), { durum: "bulunamadi" });
  await (await kalici()).h.sikayetEt(hedef.ad.toLowerCase(), "ad"); // Türkçe katlamalı ad anahtarıyla bulunur
  assert.deepEqual(await (await kalici()).h.sikayetEt(hedef.ad, "ad"), { durum: "ok", ad_sifirlandi: true });

  assert.equal((await hedef.h.ben()).ad, null);
  const t = await siralamaBaslat({ supabase: hedef.c, oyunId: "deneme", depo: bellekDepo() }).tablo("gunluk", bugun(), { ilk: 100 });
  assert.equal(t.satirlar.find((x) => x.ben)?.ad, null); // "Oyuncu" olarak görünür
  assert.equal((await hedef.h.adDegistir(`Yeni${Math.floor(Math.random() * 1e6)}`)).durum, "ok"); // 30 gün sınırı sıfırlandı
});

test("ad değişince eski ada yapılan şikâyetler sayılmaz", async () => {
  const hedef = await adli("Eski");
  await (await kalici()).h.sikayetEt(hedef.ad, "ad");
  await (await kalici()).h.sikayetEt(hedef.ad, "ad");
  await sql`update ortak.oyuncular set ad_degisti = null where kullanici_id = ${hedef.id}`; // 30 gün beklemeyelim
  const yeni = `Temiz${Math.floor(Math.random() * 1e6)}`;
  assert.equal((await hedef.h.adDegistir(yeni)).durum, "ok");
  assert.deepEqual(await (await kalici()).h.sikayetEt(yeni, "ad"), { durum: "ok", ad_sifirlandi: false });
  assert.equal((await hedef.h.ben()).ad, yeni);
});

test("devir: misafirken alınan şikâyetler kalıcı hesaba taşınır", async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const anonId = await h.anonimGir();
  const ad = `Misafir${Math.floor(Math.random() * 1e6)}`;
  await h.adDegistir(ad);
  await (await kalici()).h.sikayetEt(ad, "ad");
  await (await kalici()).h.sikayetEt(ad, "hile");
  const k = await kaliciKullanici();
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  const satirlar = await sql`select neden from ortak.sikayetler where hedef = ${k.id} order by neden`;
  assert.deepEqual(satirlar.map((r) => r.neden), ["ad", "hile"]);
  assert.equal((await sql`select count(*)::int as n from ortak.sikayetler where hedef = ${anonId}`)[0]!.n, 0);
  // taşınan ad şikâyeti yeni hesaptaki aynı ad için sayılmaya devam eder
  await (await kalici()).h.sikayetEt(ad, "ad");
  assert.deepEqual(await (await kalici()).h.sikayetEt(ad, "ad"), { durum: "ok", ad_sifirlandi: true });
});

test("hile şikâyeti adı değiştirmez, inceleme için kalır; bu oyundan sil şikâyetleri siler", async () => {
  const hedef = await adli("Hileci");
  for (let i = 0; i < 4; i++) await (await kalici()).h.sikayetEt(hedef.ad, "hile");
  assert.equal((await hedef.h.ben()).ad, hedef.ad);
  assert.equal((await sql`select count(*)::int as n from ortak.sikayetler where hedef = ${hedef.id} and neden = 'hile'`)[0]!.n, 4);
  await hedef.h.buOyundanSil();
  assert.equal((await sql`select count(*)::int as n from ortak.sikayetler where hedef = ${hedef.id}`)[0]!.n, 0);
});
