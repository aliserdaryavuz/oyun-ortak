import { test } from "node:test";
import assert from "node:assert/strict";
import type { SupabaseClient } from "@supabase/supabase-js";
import { bellekDepo } from "../kayit/index.ts";
import { odemeBaslat, type Magaza } from "./index.ts";

/** haklarim RPC'sini taklit eden en küçük Supabase. sunucu = null → ağ yok. */
const sahteSb = (sunucu: { hak: string; durum: string }[] | null, oturum = true) =>
  ({
    auth: {
      getSession: async () => ({ data: { session: oturum ? { user: { id: "u1" } } : null } }),
      signInAnonymously: async () => ({ error: null }),
    },
    schema: () => ({
      rpc: async () => {
        if (!sunucu) throw new TypeError("Failed to fetch");
        return { data: sunucu, error: null };
      },
    }),
  }) as unknown as SupabaseClient;

const sahteMagaza = (haklar: string[]): Magaza & { atanan?: string } => {
  const m: Magaza & { atanan?: string } = {
    kullaniciAta: async (id) => void (m.atanan = id),
    haklar: async () => haklar,
    satinAl: async () => [...haklar, "tam"],
    geriYukle: async () => haklar,
  };
  return m;
};

test("satın alma hakkı önbelleğe yazılır, ağsız açılışta da açık", async () => {
  const depo = bellekDepo();
  const m = sahteMagaza([]);
  const o = odemeBaslat({ supabase: sahteSb([]), oyunId: "deneme", depo, magaza: m });
  assert.deepEqual([...(await o.satinAl("deneme_tam"))], ["tam"]);
  assert.equal(m.atanan, "u1"); // RevenueCat kimliği = Supabase kimliği
  const agsiz = odemeBaslat({ supabase: sahteSb(null), oyunId: "deneme", depo });
  assert.equal(await agsiz.hakVar("tam"), true);
  assert.deepEqual([...(await agsiz.yenile())], ["tam"]); // ağ yok: önbellek değişmez
});

test("iade: sunucu 'iade' ve mağaza vermiyorsa hak düşer", async () => {
  const depo = bellekDepo({ "oyun-ortak:haklar:deneme": JSON.stringify({ haklar: ["tam"], t: 0 }) });
  const iade = [{ hak: "tam", durum: "iade" }];
  const o = odemeBaslat({ supabase: sahteSb(iade), oyunId: "deneme", depo, magaza: sahteMagaza([]) });
  assert.deepEqual([...(await o.yenile())], []);
  // mağaza hâlâ veriyorsa (ör. aile paylaşımı) kalır
  const o2 = odemeBaslat({ supabase: sahteSb(iade), oyunId: "deneme", depo, magaza: sahteMagaza(["tam"]) });
  assert.deepEqual([...(await o2.yenile())], ["tam"]);
});

test("web: satın alma kapalı, hesaptaki hak görünür", async () => {
  const o = odemeBaslat({ supabase: sahteSb([{ hak: "tam", durum: "aktif" }]), oyunId: "deneme", depo: bellekDepo() });
  await assert.rejects(o.satinAl("deneme_tam"), /web_satis_yok/);
  assert.deepEqual([...(await o.yenile())], ["tam"]);
});
