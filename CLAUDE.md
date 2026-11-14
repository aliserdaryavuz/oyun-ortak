# oyun-ortak

Serdar'ın bütün mobil oyunlarının ortak kütüphanesi ve ortak arka ucu (hesap, sıralama, etkinlik, ödeme, ölçüm, geri bildirim, kayıt, bildirim).

Önce oku: `C:\Projeler\oyunlar\_ortak\ORTAK_MODUL.md` (mimari, paketler, kurallar, yapım sırası, maliyet) ve `C:\Projeler\oyunlar\_ortak\PAZAR_OLCUTLERI.md`.

Çalışma dili Türkçe; kod tanımlayıcıları İngilizce olabilir, yorum ve belgeler Türkçe.

## İlk oturumda
1. `C:\Projeler\oyunlar\_ortak\SUPABASE_BIRLESTIRME.md` planını oku. `C:\Projeler\oyunlar\halka-kelime` ve `C:\Projeler\oyunlar\sezgi` içindeki Supabase şemalarını, Edge Function'ları ve istemci tarafındaki hesap/sıralama kodunu incele; diğer projelerdeki ayrı arka uçlara (koz-hesabi/cloudflare, ezber-bozan/server, ense-nasil-olsun/server, kargo-nobeti/sunucu, sifre-burosu/server, sahte-masasi/api, sticky-ten/server) göz at ve ortak gereksinimleri çıkar.
2. Kararları Serdar'a seçenekli sorularla sor (depo açık mı gizli mi, paket yöneticisi, Supabase bölgesi, e-posta gönderen alan adı, `oyun-canli` yeni mi açılsın yoksa Halka Kelime projesi mi dönüştürülsün, Beat Greedy'nin eski projesi test mi olsun silinsin mi). Varsayımla karar verme.
3. `docs/PLAN.md` yaz (Supabase birleştirme adımları dahil): v0.1 (kayit, hesap, siralama, olcum), v0.2 (odeme, etkinlik, geri-bildirim), şema, Edge Function şablonu (`dogrula-<oyun>`), sürümleme, testler.
4. Onay alınca v0.1'i yaz; tanıtım sayfası ve testlerle doğrula; Halka Kelime'ye geçiş adımlarını `docs/GECIS.md`'ye yaz.

## Kurallar
- Oyuna özgü arayüz ve kural kodu burada olmaz.
- Gizli anahtar depoya girmez.
- Oyunlardan gelen istekler `ISTEKLER.md`'de toplanır.

## Kesin kararlar
- Yapay zekâ / ücretli API çağrısı yok.
- Web barındırma Cloudflare Pages; Vercel kullanılmaz. Gerçek zamanlı sunucu yalnız Sticky Ten'de (Render).
- Supabase: `oyun-canli` + `oyun-test`; göçler yalnız bu depoda.
- Google ve Apple ile giriş her oyunda zorunlu ve öne çıkarılır; e-posta kodu yedek.
- PostHog ücretsiz, kart yok; kota dolarsa ölçüm sessizce durur.
- Derleme ve testler yerelde; GitHub Actions kullanılmaz (gizli depolarda dakika kotası, ödeme yöntemi yok). iOS derlemesi Codemagic ücretsiz katmanında. Tek istisna bu deponun `test.yml`'i: depo açık, dakikası sayılmaz.
- `docs/ENTEGRASYON.md`: oyunların pakete geçiş kuralları (envanter → eşleme → `src/altyapi/` → eski altyapıyı kaldırma).
