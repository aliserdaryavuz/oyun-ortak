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
