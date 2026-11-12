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
  assert.equal(isler.length, 5);
  for (const j of isler) assert.doesNotMatch(j.command, /public\./, j.jobname);
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
});
