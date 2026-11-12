import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { siralamaBaslat } from "../../src/siralama/index.ts";
import { bugun, istemci, kaliciKullanici, sql } from "./yardimci.ts";

after(() => sql.end());

const kalici = async () => {
  const k = await kaliciKullanici();
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  await h.disGiris(() => c.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  return { c, h, id: k.id };
};
const anonim = async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  await h.anonimGir();
  return { c, h };
};

test("ad şikâyeti: 3 farklı kalıcı hesap adı sıfırlar; anonim sayılmaz; oyuncu hemen yeni ad seçer", async () => {
  const hedef = await kalici();
  const ad = `Kotu${Math.floor(Math.random() * 1e6)}`;
  await hedef.h.adDegistir(ad);
  await siralamaBaslat({ supabase: hedef.c, oyunId: "deneme", depo: bellekDepo() })
    .gonder({ islem: "gunluk", gun: bugun(), kayit: [9], kuralSurumu: 1 });

  const a = await anonim();
  await assert.rejects(a.h.sikayetEt(ad, "ad"), /kalici_hesap_gerekli/);

  const s1 = await kalici();
  assert.deepEqual(await s1.h.sikayetEt(ad, "ad"), { durum: "ok", ad_sifirlandi: false });
  assert.deepEqual(await s1.h.sikayetEt(ad, "ad"), { durum: "zaten" }); // aynı kişi iki kez sayılmaz
  assert.deepEqual(await hedef.h.sikayetEt(ad, "ad"), { durum: "kendin" });
  assert.deepEqual(await s1.h.sikayetEt("YokBoyleAd", "ad"), { durum: "bulunamadi" });
  await (await kalici()).h.sikayetEt(ad.toLowerCase(), "ad"); // Türkçe katlamalı ad anahtarıyla bulunur
  const son = await (await kalici()).h.sikayetEt(ad, "ad");
  assert.deepEqual(son, { durum: "ok", ad_sifirlandi: true });

  const ben = await hedef.h.ben();
  assert.equal(ben.ad, null);
  const t = await siralamaBaslat({ supabase: hedef.c, oyunId: "deneme", depo: bellekDepo() }).tablo("gunluk", bugun(), { ilk: 100 });
  assert.equal(t.satirlar.find((x) => x.ben)?.ad, null); // "Oyuncu" olarak görünür
  // 30 gün sınırı sıfırlandı: hemen yeni ad
  assert.equal((await hedef.h.adDegistir(`Yeni${Math.floor(Math.random() * 1e6)}`)).durum, "ok");
  const [{ n }] = await sql`select count(*)::int as n from ortak.sikayetler where hedef = ${hedef.id} and neden = 'ad'`;
  assert.equal(n, 0);
});

test("hile şikâyeti adı değiştirmez, inceleme için kalır; bu oyundan sil şikâyetleri siler", async () => {
  const hedef = await kalici();
  const ad = `Hileci${Math.floor(Math.random() * 1e6)}`;
  await hedef.h.adDegistir(ad);
  for (let i = 0; i < 4; i++) await (await kalici()).h.sikayetEt(ad, "hile");
  assert.equal((await hedef.h.ben()).ad, ad);
  const [{ n }] = await sql`select count(*)::int as n from ortak.sikayetler where hedef = ${hedef.id} and neden = 'hile'`;
  assert.equal(n, 4);
  await hedef.h.buOyundanSil();
  const [{ m }] = await sql`select count(*)::int as m from ortak.sikayetler where hedef = ${hedef.id}`;
  assert.equal(m, 0);
});
