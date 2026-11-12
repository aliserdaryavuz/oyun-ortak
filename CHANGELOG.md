# Değişiklik günlüğü

Her sürümde "Oyunlar ne yapmalı" bölümü vardır. Sürümleme semver; `0.x`'te küçük sürüm kırıcı olabilir.

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
