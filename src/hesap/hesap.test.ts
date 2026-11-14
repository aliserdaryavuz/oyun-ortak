import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { googleNonce } from "./index.ts";

test("Google nonce: özet ham değerin SHA-256'sı, her çağrıda yeni", async () => {
  const a = await googleNonce();
  const b = await googleNonce();
  assert.match(a.ham, /^[0-9a-f]{64}$/);
  assert.equal(a.ozet, createHash("sha256").update(a.ham).digest("hex"));
  assert.notEqual(a.ham, b.ham);
});

test("giriş seçenekleri: iOS'ta Apple ve Google, Android'de Google; e-posta yedek, misafir en sonda", async () => {
  const { girisSecenekleri, GIRIS_RENKLERI, GIRIS_METINLERI, GOOGLE_G_SVG } = await import("./index.ts");
  assert.deepEqual(girisSecenekleri({ platform: "ios" }), ["apple", "google", "eposta", "misafir"]);
  assert.deepEqual(girisSecenekleri({ platform: "android" }), ["google", "eposta", "misafir"]);
  assert.deepEqual(girisSecenekleri({ platform: "web", apple: true }), ["google", "apple", "eposta", "misafir"]);
  assert.deepEqual(girisSecenekleri({ platform: "android", misafir: false }), ["google", "eposta"]);
  assert.equal(GIRIS_RENKLERI.google.acik.kenar, "#747775");
  assert.equal(GIRIS_METINLERI.tr.google, "Google ile devam et");
  for (const r of ["#EA4335", "#4285F4", "#FBBC05", "#34A853"]) assert.ok(GOOGLE_G_SVG.includes(r));
});
