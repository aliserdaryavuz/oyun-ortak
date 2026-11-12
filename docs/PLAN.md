# oyun-ortak planı (taslak, 12 Kasım 2026, onay bekliyor)

Kaynaklar: `_ortak/ORTAK_MODUL.md`, `_ortak/PAZAR_OLCUTLERI.md`, `_ortak/SUPABASE_BIRLESTIRME.md`, `ISTEKLER.md` (Köy Meclisi, Koz Hesabı, Ense, Halka Kelime: 46 istek), Halka Kelime ve Beat Greedy (sezgi) Supabase kodu, 7 ayrı arka uç (koz-hesabi, ezber-bozan, ense, kargo-nobeti, sifre-burosu, sahte-masasi, sticky-ten), arac-karnesi göçleri.

## 1. Kararlar (Serdar, 12 Kasım 2026)

| Konu | Karar |
| --- | --- |
| Depo | `aliserdaryavuz/oyun-ortak`, **açık** GitHub deposu |
| Paket yöneticisi | **npm** |
| Bölge | **Frankfurt (eu-central-1)** |
| Supabase projeleri (12 Kasım, uygulandı) | `oyun-canli` = `qzxchutjzhyzzaoxzroh`, `oyun-test` = `vbygbyurswjjmiqrhvmo`, ikisi de Frankfurt. beat-greedy, arac-karnesi ve eczane-panosu projeleri verileri `_ortak/arsiv/` altına aktarılıp silindi (Serdar'ın onayıyla). Araç Defterim uygulamasının arka ucu artık yok. |
| Halka | Bugünkü şeması `oyun-canli`'da (`20261113000200_halka_baslangic.sql`, `public`, `hk_` adları); bulmacalar ve ölçüm köprüsü arşivden yüklendi. 1 Aralık'ta doğrudan `oyun-canli`'da çıkar; sonradan kullanıcı taşıma gerekmez. |
| Giriş ve e-posta (12 Kasım, uygulandı) | Google sağlayıcısı iki projede açık (Web istemcisi; Android istemcisi Play derlemesiyle eklenecek). E-posta kodu Resend SMTP ile; geçici gönderen `giris@halkakelime.com`, ortak alan adı alınınca değişir. Apple ilk iOS sürümüne yakın. Gizli değerler `C:\Users\alise\.oyun-ortak\` altında, depoda yok. |
| Ölçüm (12 Kasım, uygulandı) | PostHog AB bulutu, tek proje; proje anahtarı `docs/ENTEGRASYON.md`'de. |
| Testler | Her gönderimde GitHub Actions'ta yerel Supabase kopyasıyla; `oyun-test` bulutta önizleme ve elle deneme için. |
| E-posta alan adı | **Nötr ortak alan adı alınacak** (Cloudflare Registrar, yılda ~10–15 $). Ad Serdar'dan bekleniyor. Alınana kadar Halka'nın `halkakelime.com` Resend ayarı geçici gönderen olur. Aynı alan adı gizlilik/KVKK, hesap silme ve etkinlik takvimi sayfalarını taşır. |
| Misafir | **Supabase anonim oturumu, ilk çevrimiçi işte** (ilk skor gönderimi vb.) açılır. Google/Apple/e-posta bağlanınca aynı kullanıcı kimliği kalır. Bağlanmamış anonim hesaplar 90 gün hareketsizlikte silinir. |
| Takma ad | **Oyun başına.** Benzersizlik ve 30 günlük değiştirme sınırı oyun içinde. |
| Hesap silme | **İki seçenek:** "bu oyundaki verimi sil" ve "hesabımı tamamen sil" (önce verinin olduğu oyunlar listelenir). Uygulama içinde ve web sayfasında. |

Bu planda benim seçtiğim varsayılanlar (itiraz yoksa böyle kalır):
- Tek npm paketi `@oyun/ortak`, alt yollarla: `@oyun/ortak/kayit`, `/hesap`, `/siralama`, `/olcum` (v0.2'de `/odeme`, `/etkinlik`, `/geri-bildirim`, `/bildirim`). Tek sürüm, tek CHANGELOG.
- `@supabase/supabase-js` eş bağımlılık (peer). PostHog SDK'sı kullanılmaz: olaylar PostHog'un `batch` uç noktasına düz `fetch` ile gider. Böylece Capacitor, web ve Expo'da aynı kod çalışır.
- PostHog **AB bulutu** (`eu.i.posthog.com`), KVKK için.
- Yerel Google/Apple eklentisi pakete girmez. Oyun kendi eklentisinden aldığı kimlik jetonunu `hesap`'a verir (`signInWithIdToken`). Web'de yönlendirmeli OAuth paket içindedir.
- Testler `node --test` ile (Node 24 TypeScript'i doğrudan çalıştırır). Sunucu testleri yerel Supabase'e karşı koşar. PGlite kullanılmaz: anonim oturum, RLS rolleri ve Edge Function'lar gerçek yığında sınanır.

## 2. Envanterden çıkanlar

### Halka Kelime (v0.1'in ana kaynağı)
- Hepsi `public` şemasında ve `hk_` önekli. `schema.sql` tam kurulum; yama dosyaları büyük ölçüde onun kopyası. `push.sql` yalnız kendi dosyasında var.
- **Ortağa gidecekler:** profiller ve ad anahtarı (`hk_name_key`), başlat/ipucu/gönder akışı (`hk_start_daily`…), sıralama görünümü, `hk_throttle` istek sınırı, `hk_opens`/`hk_plays` ölçüm köprüsü, haklar, push, hesap silme, `mergeLevels`/`mergeDaily` birleştirme iskeleti.
- **Güvenlik bulguları** (Halka oturumuna iletilecek, `docs/GECIS.md`'ye yazılacak):
  1. `public/puzzles/*.json` her günün cevabını taşıyor; yarının çözümü okunup gönderilebilir.
  2. Ücretli seviyeler statik dosyada; kilit yalnız istemcide.
  3. Paket hakkı `localStorage`'a elle yazılarak açılabiliyor.
  4. Sıralama görünümü bütün `user_id`'leri açık ediyor.
  5. `hk_load_puzzles` anon'a açık; belirteç tuzsuz.
  6. `hk-push` JWT'siz çalışıyor.
- Çevrimdışı kuyruk yok; bozuk JSON'da kayıt `{}` ile açılıyor (KM-1'in anlattığı kayıp riski burada da var).

### Beat Greedy (sezgi)
- **Kademeli lig yok;** "lig" davet kodlu arkadaş grubu. Kademeli lig tasarımı ISTEKLER'den (KM-7, EN-3, HK-2, KH-4) ve koz-hesabi'nin D1 ligi başvurusundan gelir.
- **Ortağa gidecekler:**
  - `_shared/lib.ts` Edge Function iskeleti: CORS, ikinci auth denetimi, gövdeyi okumadan önce istek sınırı, 256 KB gövde kesimi, `{error, reason}` hata biçimi.
  - `rate_limits` + `hit_rate_limit`.
  - `username_allowed` küfür filtresi.
  - Silme akışı.
  - İstemci giden kutusu (yanıt alınmadan kuyruktan çıkmama; 0/5xx/429/401'de yeniden deneme).
  - Saklama cron'u.
  - Gerçek yerel Supabase'e karşı test deseni.
- **Dikkat:**
  - `guvenlik.sql`'deki `alter default privileges … revoke execute` şemasız yazılmış ve bütün veritabanını etkiler. Ortak projede şemaya bağlanmalı.
  - `profiles` anon'a tümüyle açık.
  - Takma ad değiştirmenin sınırı yok.
  - Oyuncu kendi hile bayraklarını okuyabiliyor.

### Diğer arka uçlar
- Yedi projenin yedisinde de e-posta kodu, hesap silme ve istek sınırı var. Beşinde günlük skor ve misafir/cihaz kimliği, dördünde sunucuda yeniden oynatarak doğrulama var.
- **En iyi uygulamalar ve kaynakları:**

  | Konu | Kaynak |
  | --- | --- |
  | Atomik istek sınırı | `sifre-burosu/server/rateLimit.ts` |
  | Takma ad anahtarı ve küfür listesi | `sifre-burosu/server/identity.ts` |
  | Gönderim penceresi, runId, sürüm denetimi ("ilk gönderim resmî") | `kargo-nobeti/sunucu/cekirdek.ts:426-469` |
  | Olay adı ve alan izin listesi | `ezber-bozan/server/neon.ts`, `ense/server/api/olcum.ts` |
  | Çift işlenmeyen ödeme | `sticky-ten/server/accounts.ts` (`provider, external_id` benzersiz) |
  | Bağımlılıksız FCM/APNs | `sticky-ten/server/push.ts` |

- **Sunucuda durum tutan deneme:** koz-hesabi (olay olay, iyimser kilit) ve sifre-burosu (katmanlı cevap). Genel "skor gönder" bunlara yetmez, ortak `denemeler` tablosu gerekir (KH-1).
- **Acil risk (bu planın kapsamı dışında, bilgi için):** ezber-bozan'ın canlıdaki hesap ve skor verisi Vercel `/tmp`'de duruyor ve soğuk başlangıçta siliniyor. Pakete geçiş sırasında öne alınmalı.
- sticky-ten'in gerçek zamanlı sunucusu Render'da kalır. Hesabı pakete geçince sunucu Supabase JWT'sini doğrulayıp servis rolüyle yazar (v0.2 sonrası).

## 3. Depo yapısı

```
oyun-ortak/
  package.json            @oyun/ortak; exports: ./kayit ./hesap ./siralama ./olcum
  src/kayit/ hesap/ siralama/ olcum/   istemci kodu (+ yanında *.test.ts)
  sunucu/                 Edge Function ortak kitaplığı (Deno): istek iskeleti, skor yazımı, deneme, pencere
  supabase/
    config.toml           yerel yığın (oyun-test); açık şemalar: public, ortak, halka, …
    migrations/           BÜTÜN göçler (ortak + oyun şemaları)
    functions/            ortak fonksiyonlar: hesap-sil, hesap-birlestir, dogrula-deneme
  sablon/dogrula/         oyun deposuna kopyalanan dogrula-<oyun> şablonu
  ornek/                  tanıtım sayfası (sahte "deneme" oyunuyla uçtan uca)
  tests/sunucu/           yerel Supabase'e karşı entegrasyon testleri
  docs/ PLAN.md ENTEGRASYON.md GECIS.md
  CHANGELOG.md ISTEKLER.md
```

Dağıtım: oyunlar `"@oyun/ortak": "github:aliserdaryavuz/oyun-ortak#v0.1.0"` ile bağlanır. `prepare` betiği kurulumda `tsc` ile `dist/` üretir, yani depoya derleme çıktısı girmez. Edge Function'lar ortak kitaplığı etiketli adresten içe aktarır: `https://raw.githubusercontent.com/aliserdaryavuz/oyun-ortak/v0.1.0/sunucu/mod.ts`. Bu, depo açık olduğu için çalışır.

## 4. Veritabanı (`oyun-canli`)

Bütün ortak nesneler `ortak` şemasında. Oyuna özgü tablolar oyun şemasında (`halka`, `sezgi` …). Kurallar:
- RLS her tabloda açık.
- Varsayılan yetkiler **şema bazında** kapatılır.
- Fonksiyonlar `security definer` + `set search_path = ''`.
- Gün sınırı `Europe/Istanbul` (`ortak.bugun()`).

| Tablo | Sütunlar (özet) | Kim yazar / okur |
| --- | --- | --- |
| `oyunlar` | id, ad, ayarlar jsonb (lig, ad kuralları, istek sınırları) | Göçle yazılır; istemci yalnız ayarları okur |
| `profiller` | kullanici_id → auth.users (cascade), yas_13_onay, olusturma | Kendi satırı; RPC ile |
| `oyuncular` | (oyun_id, kullanici_id), ad, ad_anahtari, ad_degisti, kademe, seviye_puani, baglama_odulu, son_gorulme | Ad yalnız `ortak.ad_degistir` RPC'siyle; herkes yalnız (ad, kademe) görür |
| `kayitlar` | (oyun_id, kullanici_id), veri jsonb (≤256 KB), surum | Yalnız kendi satırı; yazım `surum` eşleşirse (iyimser kilit) |
| `skorlar` | oyun_id, kullanici_id, tur (gunluk/etkinlik), donem (gün ya da etkinlik_id), puan, ikincil, lig_puani, ayrinti jsonb, run_id unique, bayraklar | **Yalnız servis rolü** (`dogrula-*`). Benzersiz (oyun, tur, donem, kullanıcı): ilk gönderim resmî |
| `denemeler` | oyun_id, kullanici_id, anahtar, sira, durum jsonb, bitti, zaman damgaları | Yalnız servis rolü; `sira` ile iyimser kilit (KH-1, Halka başlat/ipucu, sezgi attempts) |
| `lig_gruplari` | id, oyun_id, hafta, kademe, seviye_bandi | Servis rolü / cron |
| `lig_uyeleri` | grup_id, oyun_id, kullanici_id, hafta, puan, sonuc (cikti/kaldi/indi) | Servis rolü; okuma RPC ile |
| `hiz_sinirlari` | anahtar, pencere, sayi | Yalnız `ortak.hiz_siniri()` |

Okuma RPC'leri `kullanici_id` döndürmez; satırı `ben` bayrağıyla işaretler.
- `ortak.siralama(oyun, tur, donem)`: ilk N + oyuncunun çevresi, eşit puana aynı sıra. 50 kişinin altında dağılım satırı dönmez (KH-3).
- `ortak.lig_durumu(oyun)`: oyuncunun grubu ve sırası.

Zamanlanmış işler (pg_cron, `ortak-` önekli):
- Haftalık lig kapanışı (Pazartesi 00:05 İstanbul): ilk %20 çıkar, son %20 iner, 0 puan sıraya girmez.
- İstek sınırı temizliği.
- 90 gün hareketsiz anonim hesap silme.
- Eski skor ayrıntısının boşaltılması (puan kalır; 500 MB sınırı için).

Hesap silme:
- Her oyun şeması `<sema>.oyuncu_verisini_sil(uid)` fonksiyonu sağlar ve her tablosu `auth.users`'a cascade bağlanır (ENTEGRASYON.md kuralı).
- "Bu oyundan sil": `ortak` satırları + o oyunun fonksiyonu.
- "Tamamen sil": `auth.admin.deleteUser` + cascade.

## 5. Edge Function şablonu (`dogrula-<oyun>`)

Oyun deposunda durur, çünkü oyunun motorunu içe aktarır (Sezgi'nin bugün yaptığı gibi). Ortak iskelet `sunucu/mod.ts`'ten gelir:

```ts
import { istek } from "@oyun/ortak-sunucu";          // deno.json import map → etiketli adres
import { oynat, puanla, KURAL_SURUMU } from "../../../src/engine/index.ts";

Deno.serve(istek({ oyunId: "halka", sinir: { dakika: 30 }, govdeSiniri: 64_000 }, async (c) => {
  // c.kullanici (JWT yerelde doğrulanmış; anonim de olabilir), c.govde, c.db (servis rolü)
  if (c.govde.kuralSurumu !== KURAL_SURUMU) return c.hata(426, "surum");
  if (!c.pencereAcik(c.govde.gun, { gecSaat: 3 })) return c.hata(409, "pencere");
  const puan = puanla(oynat(await bulmaca(c, c.govde.gun), c.govde.kayit));
  return c.skorYaz({ tur: "gunluk", donem: c.govde.gun, puan, ikincil: …, ligPuani: …, runId: c.govde.runId });
}));
```

İskelet şunları sağlar:
- Yalnız POST, CORS (Capacitor kökenleri dahil, oyun başına liste).
- JWT'nin yerelde doğrulanması (`getClaims`). Sezgi'deki ikinci ağ çağrısı kalkar.
- Gövdeyi okumadan önce istek sınırı: kullanıcı başına ve oyun başına toplam tavan (fonksiyonun ayarında: `kullaniciDakika`, `oyunDakika`). Tek oyunun spam'i ortak kotayı yiyemez.
- Gövde boyu kesimi ve tek hata biçimi; ayrıntı yalnız günlükte.
- `c.deneme(anahtar)`: al / ilerlet(sira) / bitir, durum tutan oyunlar için.
- `c.skorYaz`: runId'ye karşı tekrar dayanıklı; lig atamasını da yapar.

`dogrula-deneme` (ortak depoda) bu şablonun çalışan örneği; tanıtım sayfası ve testler onu kullanır.

## 6. v0.1 paketleri

**`kayit`** (KM-1, KM-2, HK-10, EN-13)
- `kayitDeposu({ depo, anahtar, surum, goc, iceAl })`.
- İki anahtarlı yazım: yeni kayıt + son sağlam yedek. Okunamayan kayıtta yedekten açılır; ikisi de bozuksa **yazım kilitlenir**, boş kayıt eskisinin üstüne yazılmaz.
- Sürüm göçü. Eski `localStorage` anahtarından bir kez içe alma; eski anahtar yedek olarak kalır.
- Cihaz kimliği ve kapalı test etiketi (`t-<kod>`).
- Depo arayüzü `{oku, yaz, sil}`. Pakette web (`localStorage`) ve Capacitor Preferences uyarlaması var; Expo'da oyun AsyncStorage'ı verir.

**`hesap`** (KM-3, KM-4, KH-6, KH-7, EN-5–7, HK-4, HK-5)
- Anonim oturum ilk çevrimiçi işte açılır.
- Google/Apple öne çıkarılır: web'de yönlendirme, yerelde kimlik jetonu. E-posta 6 haneli kod yedekte.
- Kalıcı hesaba geçiş her yöntemde tek yoldan (uygulandı): anonim oturum kısa ömürlü devir kodu alır (`devir_kodu_al`), oyuncu girer, `hesap_devral(kod)` anonim hesabın satırlarını yeni ya da var olan hesaba taşır ve anonim hesabı siler. Kimlik çakışması ve web yönlendirmesi aynı yoldan çözülür; ayrı Edge Function gerekmez.
- Yerel ve uzak kayıt, oyunun verdiği `(yerel, uzak) => { kayit, ozet }` işleviyle soru sormadan birleştirilir.
- Takma ad (oyun başına):
  - Elle girme ya da önekli otomatik üretici (önek listesi oyundan + 4 hane).
  - Uzunluk ve harf kuralı oyundan (Halka 2–20, KM/EN 3–16).
  - Türkçe katlamalı benzersizlik anahtarı: "Işık" = "Isik".
  - TR+EN uygunsuz ad ve para/bahis süzgeci sunucuda.
  - 30 günde bir değiştirme sunucuda; otomatik ad bu hakkı harcamaz.
- 13+ yaş beyanı.
- İlk bağlamada bir kez verilen kozmetik ödül kimliği (HK-5, KH-7).
- İki biçimli silme ve web silme sayfası (ortak alan adında, Cloudflare Pages).

**`siralama`** (KM-5–7, KH-1–4, KH-3, EN-1–4, HK-1–3)
- Gönderim kuyruğu: ağsız oynanan gün sonra gönderilir. Pencere oyundan ("gün + 3 saat" ya da "aynı ISO haftası"); sınır sunucu saatiyle.
- Doğrulama yalnız `dogrula-<oyun>` ile; istemcinin bildirdiği puan kullanılmaz.
- `denemeler` ile durum tutan deneme (KH-1). Günün içeriği cevapsız verilir ve gelecek gün verilmez (KH-2); bu oyunun fonksiyonunda olur, iskelet yardım eder.
- Günlük ve etkinlik sıralaması (`tur`, `donem`), ilk N + çevre, eşit puana ortak sıra ya da ikincil ölçüt (Halka: toplam süre).
- Haftalık lig, ayarları oyundan:
  - Kademe adları, grup boyu 30–50, %20 çıkma / %20 inme, haftanın en iyi N günü.
  - Seviye bandına göre grup (KH-4).
  - Atama gelişte, kilitle; eş zamanlı katılım grubu taşırmaz. Az oyuncuda grup küçük kalır, sahte oyuncu yok.
  - Kişisel ödül çubuğu kademeleri ayardan, ilerleme lig puanından.

**`olcum`** (KM-10, KH-8, EN-11, HK-6)
- Çekirdek olay şeması: `oturum_basla`, `seviye_basla/bitir/kaybet`, `gunluk_*`, `hesap_bagla`, `satin_alma_*`, `hata`.
- Oyuna özgü uzantı olaylar izin listesiyle. Alanlar yalnız basit türlerde; kişisel veri yok.
- Ortak özellikler: oyun_id, sürüm, platform, test etiketi.
- Çevrimdışı kuyruk en çok 500 olay; dolarsa en eskisi düşer. Toplu gönderim yapılır.
- PostHog hata ya da kota döndürürse **sessizce durur**; oyun etkilenmez.
- D1/D7 PostHog'un tutunma raporundan okunur.
- Halka'nın `hk_opens`/`hk_plays` köprü verisi bir kerelik betikle tarihli olarak PostHog'a aktarılır (HK-6).

## 7. v0.2 ve sonrası

| Sürüm | Paket | İstekler |
| --- | --- | --- |
| v0.2 | `odeme` (RevenueCat; tek seferlik hak, süresiz çevrimdışı önbellek, iade webhook'u hakkı düşürür, aile paylaşımı, web'de pasif ama hak görünür; `ortak.haklar`, `(kaynak, dis_id)` benzersiz) | KM-12, KH-9, EN-10, HK-8 |
| v0.2 | Korumalı içerik: ücretli dosyalar Storage'da, yalnız hakkı olan hesaba imzalı adres | HK-8 |
| v0.2 | `etkinlik` (statik takvim JSON, opak kayıt + oyunun doğrulayıcı kancası, cihazda hesaplanan kozmetik ödülün bir kez eşitlenmesi; `ortak.etkinlik_odulleri`) | KM-8, KM-9, KH-10, EN-8, EN-9, HK-7, HK-3 ödül kısmı |
| v0.2 | `geri-bildirim` (seçim/ölçek + isteğe bağlı metin, gösterim koşulu oyundan, yalnız kapalı test; cevaplar PostHog olayı olarak gider, tablo yok) | KM-11, KH-11, EN-12, HK-9 |
| v0.2 | `bildirim` (FCM + APNs, bağımlılıksız; sticky-ten başvurusu; Halka `hk-push` buraya geçer) | ORTAK_MODUL |
| v0.3 | Şikâyet/gizleme (koz, sifre-burosu deseni); arkadaş düellosu oyuna özgü kalabilir, istek netleşince | KH-5 |
| Sonra | Davet kodlu özel lig (sezgi): başka oyun isterse ortağa alınır, o zamana kadar `sezgi` şemasında | – |

## 8. Supabase birleştirme ve yol haritası

**Adım A: depo ve yerel yığın**
1. `git init`, iskelet (`package.json`, `supabase/config.toml`), yerel Supabase (Docker) = `oyun-test`.
2. Açık GitHub deposu ve CI (GitHub Actions: `supabase start` + testler): ilk sürüm etiketinden önce, Serdar'ın onayıyla (dışa açık işlem).

**Adım B: v0.1 kodu (Serdar'ın 12 Kasım "ortak yapıya odaklan" onayıyla başladı)**
- ✓ M1: `kayit` + `olcum`.
- ✓ M2: `ortak` şeması göçleri + `hesap` (devir kodu yolu; gerçek Google/Apple jetonu yalnız `oyun-canli`'da denenebilir).
- ✓ M3: `sunucu/` iskeleti, `dogrula-deneme`, `skorlar`, `denemeler`, `siralama` günlük/etkinlik.
- ✓ M4: lig (atama, haftalık kapanış cron'u, kişisel çubuk).
- ✓ M5: tanıtım sayfası (`ornek/`), `docs/ENTEGRASYON.md`, `docs/GECIS.md`, CI. Kalan: GitHub deposu + `v0.1.0` etiketi (Serdar'ın onayıyla).
- ★ Gerekenler: ortak alan adı + Resend doğrulaması, PostHog AB projesi (ücretsiz, kartsız), Apple ile giriş için Services ID ve anahtar.

**Adım C: `oyun-canli` ve geçişler (her oyun kendi oturumunda; şema göçleri bu depoda)**
- ★ Beat Greedy Londra projesinin şema dökümü alınır ve silinir (ayrı onay). ★ Frankfurt'ta `oyun-canli` açılır, `supabase login`, göçler `db push`.
- ★ Auth: Google, Apple, SMTP (ortak alan adı), anonim oturum, yönlendirme adresleri.
- Halka (1 Aralık'tan sonra canlı kullanıcısı olacağı için veri taşıma planı `docs/GECIS.md`'de: `auth.users` + `auth.identities` dökümü, `hk_` verisinin `ortak`/`halka` şemalarına aktarımı, arac-karnesi projesinden `hk_` nesnelerinin kaldırılması):
  - `hk_` → `ortak` + `halka` şemaları.
  - `dogrula-halka` motoru doğrudan kullanır (HK-1).
  - Cevaplar statik dosyalardan çıkarılır.
  - `src/altyapi/` katmanı yazılır.
- Beat Greedy: 10 göç `sezgi` şemasına yeniden yazılır, `dogrula-sezgi`, istemci ayarı. Canlıda kullanıcı yok; veri taşıma yok.
- Diğerleri Aşama 1'e geldikçe. Öneri: ezber-bozan öne alınır (`/tmp` riski).

**Adım D: v0.2.** Halka ve Sticky Ten ile denenir.

Kabul ölçütleri (SUPABASE_BIRLESTIRME'den):
- İki oyun `oyun-canli`'da; Google, Apple ve e-posta kodu, günlük skor ve sıralama çalışıyor.
- Aynı hesap iki oyunda tanınıyor.
- Yerel yığında bütün şema baştan kuruluyor.
- Eski projelere istek gitmiyor.

## 9. Sürümleme

- Semver. `0.x`'te küçük sürüm kırıcı olabilir; `1.0`'dan sonra kırıcı değişiklik yalnız ana sürümde.
- Her etiket `CHANGELOG.md`'de "Oyunlar ne yapmalı" bölümüyle yazılır.
- Oyunlar sürümü kendileri yükseltir. Yerelde birlikte geliştirirken `npm link` kullanılır, commit'e girmez.
- Göçler sürüme bağlı değil, ileriye dönük ve geri alınmaz. Kırıcı şema değişikliği iki adımda yapılır: önce ekle, oyunlar geçince kaldır.
- Edge Function iskeleti aynı etiketle sabitlenir.
- Yayın sırası: yerel yığın → CI → `oyun-canli`.

## 10. Testler

- **İstemci (`node --test`):**
  - `kayit`: bozuk JSON, yarım yazım, dolu depolama, depolama yok, göçün bir kez çalışması, ikinci açılış.
  - Birleştirme kancası.
  - Ad üretici filtreden geçiyor.
  - Gönderim kuyruğu ve hafta sınırı.
  - `olcum` kuyruğu; kota ya da ağ hatasında sessizlik.
- **Sunucu (yerel Supabase, `tests/sunucu/`):**
  - RLS: başkasının satırı okunamıyor, `user_id` sızmıyor.
  - Ad benzersizliği (Işık/Isik), 30 gün sınırı.
  - Skoru yalnız servis rolü yazıyor; runId tekrarı tek skor.
  - Pencere dışı ve gelecek gün reddediliyor; sürüm uyuşmazlığı reddediliyor.
  - Deneme: aynı olayın iki kez gönderimi tek sayılıyor, eş zamanlı iki istekten biri reddediliyor.
  - Eşitlik ve 50 eşiği.
  - Lig: 60 eş zamanlı katılım grubu taşırmıyor; haftalık kapanışta çıkma/inme doğru.
  - Silme (oyun / tamamen) sonrası hiçbir tabloda kimlik kalmıyor.
  - Anonim → kalıcı bağlamada kimlik korunuyor.
  - `dogrula-deneme` uçtan uca.
- **Tanıtım sayfası:** giriş, ad, skor gönderimi, sıralama ve silme yerel yığında tarayıcıda elle denenir; ekran görüntüsü PR'a eklenir.
- Halka'nın 9 PGlite senaryosu Adım A'da başlangıç göçüne karşı koşturulur.

## 11. Maliyet

| Kalem | Ücret |
| --- | --- |
| Ortak alan adı | Yılda ~10–15 $ (onaylandı) |
| Diğer her şey | Ücretsiz katman |

İlk dolacak sınırlar:
- Resend: günde 100 e-posta (Google/Apple öne çıkarıldığı için uzak).
- Veritabanı 500 MB: skor ayrıntısı boşaltma ve anonim hesap temizliği bunun için.
- Anonim oturum MAU'ya sayılır. 50.000 sınırı için anonim oturum yalnız ilk çevrimiçi işte açılır.

## 12. Onay için açık konular

1. Ortak alan adının adı (alınınca SMTP ve sayfalar oraya geçer). v0.1 geliştirmesini bağlamaz.
