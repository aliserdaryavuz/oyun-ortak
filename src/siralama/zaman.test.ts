import { test } from "node:test";
import assert from "node:assert/strict";
import { gunGecerli, gunSonu, isoHafta, istanbulGunu, pencereAcik } from "./zaman.ts";

test("İstanbul günü UTC+3 ile döner", () => {
  assert.equal(istanbulGunu(new Date("2026-11-12T20:59:59Z")), "2026-11-12");
  assert.equal(istanbulGunu(new Date("2026-11-12T21:00:00Z")), "2026-11-13");
});

test("ISO haftası pazartesiden başlar", () => {
  assert.equal(isoHafta("2026-11-16"), "2026-11-16"); // pazartesi
  assert.equal(isoHafta("2026-11-22"), "2026-11-16"); // pazar
  assert.equal(isoHafta("2027-01-01"), "2026-12-28"); // yıl sınırı
});

test("gün biçimi", () => {
  assert.ok(gunGecerli("2026-02-28"));
  assert.ok(!gunGecerli("2026-02-30"));
  assert.ok(!gunGecerli("2026-2-3"));
  assert.ok(!gunGecerli("x"));
  assert.equal(gunSonu("2026-11-12").toISOString(), "2026-11-12T21:00:00.000Z");
});

test("pencere: bugün açık, gelecek kapalı, dün yalnız kuralla", () => {
  const simdi = new Date("2026-11-13T00:30:00+03:00"); // cuma 00:30
  assert.ok(pencereAcik("2026-11-13", simdi));
  assert.ok(!pencereAcik("2026-11-14", simdi));
  assert.ok(!pencereAcik("2026-11-12", simdi));
  assert.ok(pencereAcik("2026-11-12", simdi, { gecSaat: 3 }));
  assert.ok(!pencereAcik("2026-11-12", new Date("2026-11-13T03:00:00+03:00"), { gecSaat: 3 }));
});

test("pencere: aynı ISO haftası (KM-5), hafta geçince düşer", () => {
  const cuma = new Date("2026-11-20T12:00:00+03:00");
  assert.ok(pencereAcik("2026-11-16", cuma, { ayniHafta: true }));
  assert.ok(!pencereAcik("2026-11-15", cuma, { ayniHafta: true }));
  // pazar akşamı oynanan gün, pazartesi 02:00'de: hafta geçti ama gecSaat kurtarır
  const pzt = new Date("2026-11-23T02:00:00+03:00");
  assert.ok(!pencereAcik("2026-11-22", pzt, { ayniHafta: true }));
  assert.ok(pencereAcik("2026-11-22", pzt, { ayniHafta: true, gecSaat: 3 }));
});
