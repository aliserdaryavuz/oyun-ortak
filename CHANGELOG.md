# Değişiklik günlüğü

Her sürümde "Oyunlar ne yapmalı" bölümü vardır. Sürümleme semver; `0.x`'te küçük sürüm kırıcı olabilir.

## v0.5.0 (14 Kasım 2026)

- `bildirim`: haftalık ek bildirim: `ekPlanla`, `ekAyarla`, `ekAcik`, saf `haftalikSecim` (haftada en çok bir, en çok 4 hafta, isteğe bağlı oynanan günde atla).
- `hesap`: ortak giriş ekranı değerleri: `girisSecenekleri({ platform, apple, misafir })`, `GIRIS_RENKLERI`, `GIRIS_OLCULERI`, `GIRIS_METINLERI`, `GOOGLE_G_SVG`, `APPLE_LOGO_SVG`.
- Sunucu (göçler `20261120000300`…`20261120001000`):
  - Misafir (anonim) oturum ad seçemez, bulut kaydı ve ödül yazamaz (`kalici_hesap_gerekli`); `otomatik_ad` açık. Ödül tavanı oyun başına kullanıcı başına 1000.
  - Hesap devrinde ipucu sayısı düşmez (çoklu küme birleşimi).
  - Sticky: `sticky.rating_uygula` (ST-6), `sticky.siralama(… p_kullanici)` (ST-7).
  - Cihaz bildirim anahtarları `ortak.bildirim_anahtarlari` (ST-8).
  - Halka: HK-17 temizlik, HK-19, HK-20, Web Push kaldırıldı; Beat Greedy profil adı misafire kapalı.

### Oyunlar ne yapmalı
- **Kırıcı:** misafirde `adDegistir`, `bulutKaydi().birlestir` ve ödül eşitlemesi artık hata verir ya da sessizce bekler; bunları yalnız kalıcı hesapta çağırın (misafir `otomatikAd` kullanır). Dört oyun bugün zaten böyle.
- Giriş ekranını `girisSecenekleri` ve `GIRIS_*` değerleriyle hizalayın (`docs/ENTEGRASYON.md` "Giriş ekranı").
- Haftalık bildirimi kendi kodunda kuran oyun `ekPlanla`/`ekAyarla`'ya geçebilir.

## v0.4.0 (13 Kasım 2026)

- Yeni giriş: `@oyun/ortak/sunucu-node` (`jetonDogrulayici`, `servisIstemcisi`): kendi Node sunucusu olan oyunlar için Supabase jeton doğrulama ve servis rolüyle yazma (ST-4).
- Sticky Ten şeması (`20261116000100_sticky.sql`): istatistik, rating, rating günlüğü, ikili sayaç, masa devri; `sticky.oyun_sonu` tek işlem (ST-1); `sticky.siralama` dönemlik sıralama ve `sticky.haftalik_odul` (ST-2); takip (ST-3, oyuna özgü). `ortak.oyunlar('sticky')`, ürün `sticky_deluxe`.

### Oyunlar ne yapmalı
- Kırıcı değişiklik yok. Kendi sunucusu olan oyun `docs/ENTEGRASYON.md` → "Kendi sunucusu olan oyun".

## v0.3.1 (13 Kasım 2026)

Şikâyet düzeltmeleri (`20261115000200_sikayet_duzelt.sql`): yalnız şu anki ada yapılan şikâyetler sayılır; şikâyetçi o oyunda en az `ayarlar.sikayet.en_az_gun` (2) gündür oynamış olmalı; misafirken alınan şikâyetler devirde yeni hesaba taşınır. İstemci API'si değişmedi.

## v0.3.0 (13 Kasım 2026)

- Şikâyet: `hesap.sikayetEt(ad, neden)`; göç `20261115000100_ortak_v03_sikayet.sql` (`ortak.sikayetler`, `ortak.sikayet_et`). Ad şikâyeti eşiğe ulaşınca ad sıfırlanır.
- Halka'nın ortak kaydı (`20261115000000_halka_ortak.sql`): `ortak.oyunlar('halka')`, ürün `paket_tam`, `halka.oyuncu_verisini_sil`.
- Beat Greedy şeması (`20261114000100_sezgi.sql`, `20261114000200_sezgi_silme.sql`); bkz. `docs/GECIS_SEZGI.md`.

### Oyunlar ne yapmalı
- Bağımlılığı `#v0.3.0`'a yükselt; kırıcı değişiklik yok.
- Sıralama ve lig satırlarına "Şikâyet et" seçeneği eklenebilir. Adı sıfırlanan oyuncu `ben().ad === null` görür; oyun ondan yeni ad seçmesini ister.

## v0.2.0 (13 Kasım 2026)

Yeni paketler: `odeme`, `etkinlik`, `geri-bildirim`, `bildirim`. Göç `20261114000000_ortak_v02.sql`: `ortak.urunler`, `ortak.haklar`, `ortak.oduller`, `korumali` depolama kovası; `odeme-webhook` Edge Function (RevenueCat).

### Oyunlar ne yapmalı
- Bağımlılığı `#v0.2.0`'a yükselt. v0.1 API'sinde kırıcı değişiklik yok.
- Satın alma: ürün eşlemesi için bu depoya göç isteği yaz (`ISTEKLER.md`); `docs/ENTEGRASYON.md` → "Ödeme".
- Web için Google girişinde `googleDugmesi` kullan (oyuncu Supabase adresini görmez); yönlendirmeli `webIleGir` yedek.

## v0.1.0 (12 Kasım 2026)

İlk sürüm: `kayit`, `olcum`, `hesap`, `siralama` + `ortak` şeması + Edge Function iskeleti.

### Oyunlar ne yapmalı
- `docs/ENTEGRASYON.md` adımlarını izle; oyun şeması ve `ortak.oyunlar` satırı için bu depoya göç isteği yaz (`ISTEKLER.md`).
- `dogrula-<oyun>` için `sablon/dogrula/` klasörünü kopyala.
