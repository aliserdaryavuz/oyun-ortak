# Beat Greedy (sezgi) geçişi

Okuyucu: sezgi deposunda çalışan oturum ve Serdar. Tarih: 13 Kasım 2026.

## Durum

- Beat Greedy'nin eski Supabase projesi (Londra, `ynlapmkqrgjpjbrlypct`) silindi. Verisi `C:\Projeler\oyunlar\_ortak\arsiv\beat-greedy-2026-11-12` klasöründe.
- 10 göç `oyun-ortak/supabase/migrations/20261114000100_sezgi.sql` dosyasında, **`sezgi` şemasında** toplandı. Dönüşüm mekanik: `public.` → `sezgi.` ve `search_path` ayarı.
- Orijinal ile dönüştürülmüş şema katalogda karşılaştırıldı. 27 fonksiyon gövdesi, 12 görünüm, tablolar, kısıtlar, indeksler, RLS politikaları, tablo/fonksiyon yetkileri ve 5 cron işi birebir aynı; tek fark şema adı.
- İçerik arşivden yüklendi: 331 günlük bulmaca, 331 çözüm, 48.621 seviye bulmacası. Test kullanıcıları ve denemeleri taşınmadı.
- Tek davranış farkı: `guvenlik.sql`'deki şemasız `alter default privileges … revoke execute on functions from public` satırı kaldırıldı. Bu satır bütün veritabanını (ortak ve diğer oyunları) etkilerdi. Yerine `sezgi` şemasına bağlı açık bir `revoke` var.

## Kural

**Şema göçleri yalnız `oyun-ortak` deposunda yazılır.** sezgi deposundaki `supabase/migrations` artık uygulanmaz; yeni bir şema değişikliği gerektiğinde oyun-ortak'a göç isteği yazılır (`ISTEKLER.md`). sezgi deposu yalnız kendi Edge Function'larını yayınlar.

## sezgi deposunda yapılacaklar

1. **Ortam değişkenleri:**
   - `EXPO_PUBLIC_SUPABASE_URL=https://qzxchutjzhyzzaoxzroh.supabase.co`
   - Anahtar: `npx supabase projects api-keys --remote=qzxchutjzhyzzaoxzroh`
   - Önizleme için `oyun-test` (`vbygbyurswjjmiqrhvmo`); aynı şema ve içerik orada da var.
2. **İstemci** (`apps/mobile/src/net/supabase.ts`): `createClient(url, key, { db: { schema: "sezgi" }, auth: … })`. Ortak paket kullanılırsa onun çağrıları zaten `ortak` şemasını açıkça seçer.
3. **Edge Function'lar** (`supabase/functions/_shared/lib.ts`, `admin()`): `/rest/v1/` isteklerine iki başlık eklenir: `Accept-Profile: sezgi` ve `Content-Profile: sezgi`. Fonksiyonlar `oyun-canli`'ya sezgi deposundan yayınlanır:
   ```
   npx supabase functions deploy start_attempt submit_attempt submit_level daily_solution race_hint --remote=qzxchutjzhyzzaoxzroh
   ```
4. **Hesap silme:** `delete_account` fonksiyonu `auth.users` kaydını siliyor. Ortak projede bu, oyuncunun bütün oyunlardaki hesabını siler; bu yüzden değişmeli:
   - "Bu oyundaki verimi sil": istemciden `ortak.oyun_verisini_sil('sezgi')`. Bu çağrı `sezgi.oyuncu_verisini_sil`'i çalıştırır; lig kurucusuysa `owns_leagues` hatası verir (K50 korunur).
   - "Hesabımı tamamen sil": `ortak.hesabi_sil()` (önce `ortak.hesap_ozeti()` ile oyunları listele).
   - `delete_account` fonksiyonu kaldırılabilir.
5. **Giriş:** proje genelinde e-posta kodu (Türkçe ASYWorks şablonu, `giris@asyworks.com`), Google ve anonim oturum açık. Beat Greedy şimdilik yalnız e-posta kodunu kullanıyor; Google düğmesi `@oyun/ortak/hesap` ile eklenebilir.
6. **Testler:** `tools/servertest` yerel Supabase'e karşı koşuyor. Şema artık oyun-ortak'ta olduğu için yerel yığın oyun-ortak klasöründen başlatılır (`npm run db:start`, adres `http://127.0.0.1:55321`); sezgi'nin fonksiyonları oraya `supabase functions serve` ile ya da `oyun-test`'e karşı denenir.
7. **Günlük içerik üretimi:** `DAILY_SEED_SECRET` ile üretilen yeni günler `sezgi.daily_puzzles` / `sezgi.daily_solutions` tablolarına servis anahtarıyla yazılır. Hedef şema `sezgi` olmalı.

## Sonra (ortak paketlere geçiş)

- Profil ve kullanıcı adı → `ortak.oyuncular` (oyun başına ad, 30 gün kuralı).
- Günlük sıralama → `ortak.skorlar` + `dogrula-sezgi`.
- Denemeler → `ortak.denemeler`.
- Davet kodlu özel lig `sezgi` şemasında kalır; başka bir oyun isterse ortağa alınır.
