import { after, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { siralamaBaslat } from "../../src/siralama/index.ts";
import { bugun, istemci, kaliciKullanici, MAILPIT, ortak, rastgeleEposta, rpc, sql } from "./yardimci.ts";

after(() => sql.end());

const yeniHesap = () => {
  const supabase = istemci();
  return hesapBaslat({ supabase, oyunId: "deneme", depo: bellekDepo() });
};

test("istemci ortak tablolara doğrudan erişemez; servis fonksiyonlarını çağıramaz", async () => {
  const h = yeniHesap();
  await h.anonimGir();
  for (const t of ["skorlar", "oyuncular", "kayitlar", "profiller", "denemeler", "lig_uyeleri", "devirler"]) {
    const { error } = await ortak(h.supabase).from(t).select("*").limit(1);
    assert.ok(error, `${t} okunabildi`);
  }
  const { error } = await ortak(h.supabase).rpc("lig_kapat");
  assert.match(error?.message ?? "", /permission denied/);
  // oyunlar tablosu (ayarlar) herkese açık
  const { data } = await ortak(istemci()).from("oyunlar").select("id").eq("id", "deneme");
  assert.equal(data?.length, 1);
});

test("oturumsuz: sıralama okunur, kişisel işler reddedilir", async () => {
  const c = istemci();
  const t = await rpc<{ toplam: number }>(c, "siralama", { p_oyun: "deneme", p_tur: "gunluk", p_donem: "2000-01-01" });
  assert.equal(t.toplam, 0);
  await assert.rejects(rpc(c, "ben", { p_oyun: "deneme" }));
});

test("anonim oturum: ben, yaş onayı, otomatik ad", async () => {
  const h = yeniHesap();
  await h.anonimGir();
  const b = await h.ben();
  assert.equal(b.anonim, true);
  assert.equal(b.ad, null);
  await h.yasOnayla();
  assert.ok((await h.ben()).yas_onay);
  const r = await h.otomatikAd(["Bekçi", "Çoban"]);
  assert.equal(r.durum, "ok");
  assert.match((r as { ad: string }).ad, /^(Bekçi|Çoban)\d{4}$/);
});

test("takma ad: biçim, uygunsuz söz, Türkçe katlamalı benzersizlik, 30 gün", async () => {
  const a = yeniHesap();
  await a.anonimGir();
  const ad = `Işık${Math.floor(Math.random() * 1e6)}`;
  assert.deepEqual(await a.adDegistir(ad), { durum: "ok", ad });
  assert.deepEqual(await a.adDegistir("Başka1"), { durum: "bekle", bekle_gun: 30 });

  const b = yeniHesap();
  await b.anonimGir();
  assert.equal((await b.adDegistir(ad.replace("Işık", "isik"))).durum, "alinmis");
  assert.equal((await b.adDegistir(ad.replace("Işık", "I.ŞIK"))).durum, "alinmis");
  for (const kotu of ["S1kt1r42", "orospucocugu", "Admin", "sik", "BahisKral", "denemeci"])
    assert.equal((await b.adDegistir(kotu)).durum, "uygunsuz", kotu);
  for (const yanlis of ["ab", "x".repeat(17), "iki  boşluk", "123", "a<b>c", "x\ty"])
    assert.equal((await b.adDegistir(yanlis)).durum, "bicim", yanlis);
  // yanlış pozitif olmamalı
  for (const iyi of ["Memet", "Seksen", "Sıkı Dost"]) {
    const c = yeniHesap();
    await c.anonimGir();
    assert.equal((await c.adDegistir(`${iyi}${Math.floor(Math.random() * 1000)}`)).durum, "ok", iyi);
  }
  // otomatik ad elle seçileni ezmez
  assert.deepEqual(await a.otomatikAd(["Avcı"]), { durum: "ok", ad });
});

test("bulut kaydı: iyimser kilit ve birleştirme işlevi", async () => {
  const h = yeniHesap();
  await h.anonimGir();
  const k = h.bulutKaydi<{ seviyeler: Record<string, number> }>();
  const birlestir = (y: { seviyeler: Record<string, number> }, u: { seviyeler: Record<string, number> }) => {
    const s = { ...u.seviyeler };
    for (const [n, v] of Object.entries(y.seviyeler)) s[n] = Math.max(s[n] ?? 0, v);
    return { kayit: { seviyeler: s }, ozet: `${Object.keys(s).length} seviye` };
  };
  await k.birlestir({ seviyeler: { "1": 2 } }, birlestir);
  const r = await k.birlestir({ seviyeler: { "1": 1, "2": 3 } }, birlestir);
  assert.deepEqual(r, { kayit: { seviyeler: { "1": 2, "2": 3 } }, ozet: "2 seviye" });
  // aynı sürümle iki yazımdan biri kazanır
  const s = (await k.oku())!.surum;
  const y1 = await rpc(h.supabase, "kayit_yaz", { p_oyun: "deneme", p_veri: { a: 1 }, p_surum: s });
  const y2 = await rpc(h.supabase, "kayit_yaz", { p_oyun: "deneme", p_veri: { a: 2 }, p_surum: s });
  assert.equal(y1, s + 1);
  assert.equal(y2, null);
  await assert.rejects(rpc(h.supabase, "kayit_yaz", { p_oyun: "deneme", p_veri: { x: "y".repeat(270_000) }, p_surum: s + 1 }));
});

test("misafir → var olan kalıcı hesap: sunucu verisi taşınır, anonim hesap silinir", async () => {
  const k = await kaliciKullanici();
  // kalıcı hesabın daha önceki verisi
  const eski = yeniHesap();
  await eski.disGiris(() => eski.supabase.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await eski.ben();

  const h = yeniHesap();
  const anonId = await h.anonimGir();
  const ad = `Misafir${Math.floor(Math.random() * 1e6)}`;
  await h.adDegistir(ad);
  await h.bulutKaydi().birlestir({ n: 1 }, (y) => ({ kayit: y }));
  const s = siralamaBaslat({ supabase: h.supabase, oyunId: "deneme", depo: bellekDepo() });
  assert.equal((await s.gonder({ islem: "gunluk", gun: bugun(), kayit: [5, 5], kuralSurumu: 1 })).durum, 200);

  const r = await h.disGiris(() => h.supabase.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  assert.deepEqual(r, { devredilen: ["deneme"] });
  const ben = await h.ben();
  assert.equal(ben.anonim, false);
  assert.equal(ben.ad, ad); // kalıcı hesapta ad yoktu, misafirinki alındı
  assert.deepEqual((await h.bulutKaydi().oku())?.veri, { n: 1 });
  const t = await s.tablo("gunluk", bugun(), { ilk: 100 });
  assert.equal(t.satirlar.find((x) => x.ben)?.puan, 10);
  const [{ n }] = await sql`select count(*)::int as n from auth.users where id = ${anonId}`;
  assert.equal(n, 0);
  // ödül yalnız kalıcı hesapta ve bir kez
  assert.equal(await h.baglamaOdulu(), "deneme-rozet");
  assert.equal(await h.baglamaOdulu(), null);
});

test("anonim hesap ödül alamaz; devir kodu tek kullanımlık", async () => {
  const h = yeniHesap();
  await h.anonimGir();
  assert.equal(await h.baglamaOdulu(), null);
  const kod = await rpc<string>(h.supabase, "devir_kodu_al");
  const k = await kaliciKullanici();
  await h.supabase.auth.signInWithPassword({ email: k.eposta, password: k.parola });
  await rpc(h.supabase, "hesap_devral", { p_kod: kod });
  await assert.rejects(rpc(h.supabase, "hesap_devral", { p_kod: kod }), /devir_kodu_gecersiz/);
  // kalıcı hesap devir kodu alamaz
  await assert.rejects(rpc(h.supabase, "devir_kodu_al"), /anonim_degil/);
});

test("e-posta koduyla giriş (gerçek yol, Mailpit)", async () => {
  const h = yeniHesap();
  await h.anonimGir();
  await h.ben();
  const eposta = rastgeleEposta();
  await h.epostaKoduGonder(eposta);
  let kod: string | undefined;
  let son = "";
  for (let i = 0; i < 60 && !kod; i++) {
    await new Promise((r) => setTimeout(r, 500));
    const liste = (await (await fetch(`${MAILPIT}/api/v1/messages?limit=50`)).json()) as {
      messages: { ID: string; To: { Address: string }[] }[];
    };
    const id = liste.messages.find((m) => m.To.some((t) => t.Address === eposta))?.ID;
    if (id) {
      const m = (await (await fetch(`${MAILPIT}/api/v1/message/${id}`)).json()) as { Text: string; Subject: string };
      son = `${m.Subject}: ${m.Text.slice(0, 200)}`;
      kod = /(\d{6})/.exec(m.Text)?.[1];
    }
  }
  assert.ok(kod, `kod e-postası gelmedi; son ileti: ${son || "yok"}`);
  const r = await h.epostaKoduIleGir(eposta, kod!);
  assert.deepEqual(r, { devredilen: ["deneme"] });
  assert.equal((await h.kullanici())?.eposta, eposta);
});

test("silme: bu oyundan sil ve tamamen sil", async () => {
  const k = await kaliciKullanici();
  const h = yeniHesap();
  await h.disGiris(() => h.supabase.auth.signInWithPassword({ email: k.eposta, password: k.parola }));
  await h.adDegistir(`Silinecek${Math.floor(Math.random() * 1e6)}`);
  await h.bulutKaydi().birlestir({ a: 1 }, (y) => ({ kayit: y }));
  const s = siralamaBaslat({ supabase: h.supabase, oyunId: "deneme", depo: bellekDepo() });
  await s.gonder({ islem: "gunluk", gun: bugun(), kayit: [1], kuralSurumu: 1 });
  assert.deepEqual(await h.hesapOzeti(), [{ oyun_id: "deneme", ad: "Deneme Oyunu" }]);

  await h.buOyundanSil();
  assert.deepEqual(await h.hesapOzeti(), []);
  const kalan = await sql`
    select (select count(*) from ortak.skorlar where kullanici_id = ${k.id})
         + (select count(*) from ortak.kayitlar where kullanici_id = ${k.id})
         + (select count(*) from ortak.lig_uyeleri where kullanici_id = ${k.id})::int as n`;
  assert.equal(Number(kalan[0]!.n), 0);
  assert.equal((await sql`select count(*)::int as n from auth.users where id = ${k.id}`)[0]!.n, 1);

  await h.ben();
  await s.gonder({ islem: "gunluk", gun: bugun(), kayit: [2], kuralSurumu: 1 });
  await h.tamamenSil();
  assert.equal(await h.kullanici(), null);
  // kimlik hiçbir tabloda kalmadı
  const izler = await sql`
    select c.table_schema || '.' || c.table_name as t
    from information_schema.columns c
    where c.table_schema = 'ortak' and c.column_name in ('kullanici_id', 'anonim_id')`;
  for (const { t } of izler) {
    const col = t === "ortak.devirler" ? "anonim_id" : "kullanici_id";
    const [{ n }] = await sql.unsafe(`select count(*)::int as n from ${t} where ${col} = $1`, [k.id]);
    assert.equal(n, 0, t);
  }
});
