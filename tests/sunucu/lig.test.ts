import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { bellekDepo } from "../../src/kayit/index.ts";
import { hesapBaslat } from "../../src/hesap/index.ts";
import { odulCubugu, siralamaBaslat } from "../../src/siralama/index.ts";
import { istemci, oyunuTemizle, sql } from "./yardimci.ts";

before(() => oyunuTemizle());
after(() => sql.end());

const [{ bu, gecen }] = await sql`select ortak.iso_hafta(ortak.bugun())::text as bu, (ortak.iso_hafta(ortak.bugun()) - 7)::text as gecen`;
const gunu = (hafta: string, n: number) => {
  const d = new Date(`${hafta}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

async function sahteOyuncu(kademe = 0, seviye = 0) {
  const [{ id }] = await sql`insert into auth.users (id, aud, role, is_anonymous) values (gen_random_uuid(), 'authenticated', 'authenticated', true) returning id`;
  await sql`insert into ortak.oyuncular (oyun_id, kullanici_id, kademe, seviye_puani) values ('deneme', ${id}, ${kademe}, ${seviye})`;
  return id as string;
}
const skor = (id: string, gun: string, lig: number) =>
  sql`select ortak.skor_yaz('deneme', ${id}, 'gunluk', ${gun}, ${lig * 10}, gen_random_uuid(), 1, ${lig})`;

test("eş zamanlı 60 katılım: hiçbir grup 50'yi aşmaz", async () => {
  const idler = await Promise.all(Array.from({ length: 60 }, () => sahteOyuncu(2)));
  await Promise.all(idler.map((id) => skor(id, gunu(bu, 0), 3)));
  const gruplar = await sql`
    select g.id, count(u.*)::int as n from ortak.lig_gruplari g join ortak.lig_uyeleri u on u.grup_id = g.id
    where g.oyun_id = 'deneme' and g.hafta = ${bu} and g.kademe = 2 group by g.id order by g.id`;
  assert.deepEqual(gruplar.map((g) => g.n), [50, 10]);
});

test("haftalık puan en iyi 5 gün; seviye bandı ayrı grup (KH-4)", async () => {
  const id = await sahteOyuncu(3);
  for (let i = 0; i < 7; i++) await skor(id, gunu(bu, i), i + 1);
  const [u] = await sql`select puan::int from ortak.lig_uyeleri where kullanici_id = ${id}`;
  assert.equal(u!.puan, 3 + 4 + 5 + 6 + 7);

  await sql`update ortak.oyunlar set ayarlar = jsonb_set(ayarlar, '{lig,bant_genisligi}', '100') where id = 'deneme'`;
  try {
    const a = await sahteOyuncu(4, 50);
    const b = await sahteOyuncu(4, 250);
    const c = await sahteOyuncu(4, 60);
    for (const x of [a, b, c]) await skor(x, gunu(bu, 0), 3);
    const g = await sql`select kullanici_id, grup_id from ortak.lig_uyeleri where kullanici_id in ${sql([a, b, c])}`;
    const grup = Object.fromEntries(g.map((r) => [r.kullanici_id, r.grup_id]));
    assert.equal(grup[a], grup[c]);
    assert.notEqual(grup[a], grup[b]);
  } finally {
    await sql`update ortak.oyunlar set ayarlar = jsonb_set(ayarlar, '{lig,bant_genisligi}', '0') where id = 'deneme'`;
  }
});

test("kapanış: ilk %20 çıkar, son %20 iner, 0 puan sıraya girmez; ikinci çağrı bir şey yapmaz", async () => {
  const idler: string[] = [];
  for (let i = 1; i <= 10; i++) {
    const id = await sahteOyuncu(1);
    idler.push(id);
    await skor(id, gunu(gecen, 2), i); // puan 1..10
  }
  const sifir = await sahteOyuncu(1);
  await skor(sifir, gunu(gecen, 2), 0);

  assert.ok((await sql`select ortak.lig_kapat() as n`)[0]!.n >= 1);
  const k = async (id: string) => (await sql`select kademe from ortak.oyuncular where oyun_id = 'deneme' and kullanici_id = ${id}`)[0]!.kademe;
  assert.deepEqual(await Promise.all(idler.map(k)), [0, 0, 1, 1, 1, 1, 1, 1, 2, 2]);
  const [s] = await sql`select sira, sonuc from ortak.lig_uyeleri where kullanici_id = ${sifir}`;
  assert.deepEqual({ ...s }, { sira: null, sonuc: "kaldi" });
  assert.equal((await sql`select ortak.lig_kapat() as n`)[0]!.n, 0);
  // kapanmış haftaya geç gelen skor puanı değiştirmez
  await skor(idler[0]!, gunu(gecen, 3), 9);
  assert.equal(Number((await sql`select puan from ortak.lig_uyeleri where kullanici_id = ${idler[0]!}`)[0]!.puan), 1);
});

test("lig durumu: grup üyeleri, ben bayrağı, geçen haftanın sonucu", async () => {
  const c = istemci();
  const h = hesapBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const id = await h.anonimGir();
  await h.adDegistir(`Ligci${Math.floor(Math.random() * 1e6)}`);
  await sql`update ortak.oyuncular set kademe = 1 where oyun_id = 'deneme' and kullanici_id = ${id}`;
  await skor(id, gunu(gecen, 0), 4);
  const rakip = await sahteOyuncu(1);
  await skor(rakip, gunu(gecen, 0), 2);
  await sql`select ortak.lig_kapat()`;
  await skor(id, gunu(bu, 0), 5);

  const s = siralamaBaslat({ supabase: c, oyunId: "deneme", depo: bellekDepo() });
  const l = await s.lig();
  assert.equal(l.hafta, bu);
  assert.equal(l.katildi, true);
  assert.equal(l.onceki?.hafta, gecen);
  assert.ok(["cikti", "kaldi"].includes(l.onceki!.sonuc));
  assert.equal(l.kademe_adi, l.onceki!.sonuc === "cikti" ? "Gümüş" : "Bakır");
  const ben = l.uyeler.filter((u) => u.ben);
  assert.equal(ben.length, 1);
  assert.equal(ben[0]!.puan, 5);
});

test("kişisel ödül çubuğu", () => {
  assert.deepEqual(odulCubugu(12, [5, 10, 15, 20, 25]), { ulasilan: 2, sonraki: 15, kalan: 3 });
  assert.deepEqual(odulCubugu(30, [5, 10]), { ulasilan: 2, sonraki: null, kalan: 0 });
});
