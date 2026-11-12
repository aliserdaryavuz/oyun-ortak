# Halka Kelime geçişi (taslak)

Okuyucu: Halka Kelime oturumu ve Serdar. Durum: 1 Aralık 2026'da Halka bugünkü düzeniyle web'e çıkar. Bugünkü düzen, arac-karnesi'nin Frankfurt projesi `qqdf…`, `public` şeması ve `hk_` önekli nesneler. Bu geçiş daha sonra, `oyun-canli` açıldığında yapılır.

## 1. Önce kapatılacak açıklar (Halka deposunda, geçişten bağımsız)

1. `public/puzzles/*.json` her günün `answers` ve `solution` alanlarını taşıyor. Yarının çözümü okunup gönderilebiliyor. Cevaplar istemci dosyalarından çıkarılmalı; doğrulama sunucudaki halkalarla yapılır.
2. Ücretli seviyeler ve eski günler herkese açık statik dosya; kilit yalnız istemcide. Korumalı içerik v0.2'de geliyor (HK-8).
3. Paket hakkı `localStorage`'a (`halka-kelime:paket`) elle yazılarak açılabiliyor. Hak sunucudan gelmeli (v0.2 `odeme`).
4. `hk_leaderboard` ve `hk_daily_scores` bütün `user_id`'leri açık ediyor. `ortak.siralama` kimlik döndürmez.
5. `hk_load_puzzles` anon'a açık, belirteç tuzsuz. `hk-push` JWT'siz. Geçişte ikisi de kalkar.

## 2. Eşleme

| Bugün (`public`) | Sonra |
| --- | --- |
| `hk_profiles` (ad, `hk_name_key`) | `ortak.oyuncular` (ad, `ad_anahtari`). Ayar: `ad.en_az = 2`, `ad.en_cok = 20`; otomatik ad yok |
| `hk_daily_puzzles` | `halka.gunluk_bulmacalar`, yalnız servis rolü (cevaplar istemciye gitmez) |
| `hk_daily_starts` + `hk_hint_daily` | `ortak.denemeler`: anahtar `gunluk:<tarih>`, durum `{ baslangic, ipucu }` |
| `hk_daily_scores`, `hk_submit_daily` | `ortak.skorlar` + `dogrula-halka` (HK-1). `puan = rank_seconds`, `siralama.yon = "artan"`. Lig puanı HK-2 formülü (3 + hedef + ipucusuz) |
| `hk_leaderboard` | `ortak.siralama` RPC |
| `hk_level_progress` | `ortak.kayitlar` bulut kaydı; birleştirme `mergeLevels` + `mergeDaily` (oyunun işlevi) |
| `hk_plays`, `hk_opens`, `hk_errors`, `hk_retention`, `hk_funnel` | PostHog (`olcum`). Köprü verisi bir kerelik betikle tarihli aktarılır (HK-6) |
| `hk_entitlements`, `hk_push` + `hk-push` | v0.2 `odeme` ve `bildirim` |
| `hk_delete_account` | `buOyundanSil` / `tamamenSil` (+ `halka.oyuncu_verisini_sil`) |
| `hk_admin`, `hk_load_puzzles` | Kalkar. Bulmaca yükleme servis anahtarıyla, yerel betikten |
| localStorage `halka-kelime:v1`, `:seviye:v1`, `:cihaz` | `kayitDeposu({ iceAl })` ile bir kez içe alma (HK-10). Eski anahtarlar yedek kalır |

## 3. Adımlar

1. **Bu depoda:**
   - `ortak.oyunlar` satırı: `halka`; ayarlar `ad`, `hesap.baglama_odulu = "desen-porselen"`, `siralama`, `lig` (kademeler toprak/bakır/gümüş/altın/firuze).
   - `halka` şeması göçü: `gunluk_bulmacalar`, `oyuncu_verisini_sil`.
   - Etkinlik sıralaması (HK-3) `tur = "etkinlik"`, `donem = <etkinlik_id>` ile hazır.
2. **Halka deposunda:** `src/altyapi/`, `dogrula-halka` (motorun `equivalentStates` okuma kuralıyla), Google/Apple düğmeleri. `tests/sql.test.ts` senaryoları `dogrula-halka`'ya karşı yeniden yazılır.
3. **Veri taşıma (canlı kullanıcı olduğu için ayrıca onay ister):**
   - Halka kullanıcıları (`hk_profiles`'ta satırı olanlar) eski projeden dışa aktarılır: `auth.users` + `auth.identities` satırları `pg_dump --data-only`, aynı UUID'lerle. arac-karnesi'nin kendi kullanıcısı taşınmaz.
   - `hk_profiles` → `ortak.oyuncular`, `hk_daily_scores` → `ortak.skorlar` (`run_id` yeni), `hk_level_progress` → `ortak.kayitlar` (kullanıcı başına tek blob).
   - Oturumlar yeni projede geçersiz olur. Oyuncular bir kez yeniden girer; Google ile girenler aynı kimliğe düşer.
4. **Geçiş:** Önizleme derlemesi `oyun-canli`'ya bağlanır ve denenir. Sonra yayın. Bir hafta paralel izlenir.
5. **Temizlik:** arac-karnesi projesinden `hk_` nesneleri kaldırılır. Bunun için arac-karnesi oturumuna not düşülür ve Serdar onaylar.
