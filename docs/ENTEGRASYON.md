# Entegrasyon: bir oyun oyun-ortak'a nasıl bağlanır

Okuyucu: oyun deposunda çalışan oturum (Aşama 1'e gelmiş oyun). Önce `_ortak/ORTAK_MODUL.md`'deki "Mevcut kod ne olacak" bölümünü oku.

## Sıra

1. **Envanter.** Oyundaki altyapı kodunu ve servisleri listele: hesap/giriş, skor, sıralama, yedek, ölçüm, push, ödeme; Vercel API, Neon, Upstash, Worker, kendi sunucu.
2. **Eşleme.** Her parçanın paketteki karşılığını yaz (aşağıdaki tablo). Karşılığı olmayanı bu depodaki `ISTEKLER.md`'ye ekle: oyun, paket, istek, neden, kabul ölçütü. Oyuna özgü kodu ISTEKLER'e kopyalama.
3. **Sunucu tarafı (bu depoda, istekle).** Oyunun `ortak.oyunlar` satırı ve varsa oyun şeması bu deponun `supabase/migrations/` klasörüne göç olarak eklenir. Oyun deposu veritabanına göç yazmaz.
4. **`src/altyapi/`.** İnce uyarlama katmanını yaz. Oyun kodu paketi yalnız buradan çağırır.
5. **`dogrula-<oyun>`.** `sablon/dogrula/` klasörünü oyun deposunda `supabase/functions/dogrula-<oyun>/` altına kopyala, motoru bağla.
6. **Testler** geçince eski altyapıyı ve servisleri kaldır. Vercel bağlantısını kopar, Cloudflare Pages'e taşı.
7. Canlı kullanıcısı olan oyunda veri taşıma planı ayrı yazılır (Halka için `docs/GECIS.md`).

## Eşleme tablosu

| Eski | Paketteki karşılığı |
| --- | --- |
| localStorage kaydı, JSON dosya kaydı | `@oyun/ortak/kayit` → `kayitDeposu` (iki anahtarlı yazım, yedekten açma, `iceAl` ile eski anahtardan bir kez içe alma) |
| Cihaz kimliği, test kodu (`?t=`) | `cihazKimligi(depo, testKodu)` |
| E-posta kodu, kendi oturum jetonu | `@oyun/ortak/hesap` (Supabase Auth: anonim → Google/Apple/e-posta kodu) |
| Misafir ilerlemesini hesaba bağlama | Devir otomatik; yerel kayıt `bulutKaydi().birlestir(yerel, oyununBirlestirmeIslevi)` |
| Takma ad, küfür filtresi, 30 gün | `adDegistir`, `otomatikAd()` (sunucu üretir); kurallar ve önekler `ortak.oyunlar.ayarlar.ad` |
| Bulut yedeği / eşitleme blob'u | `bulutKaydi()` (≤256 KB, iyimser kilit) |
| Skor gönderimi, yeniden oynatma, runId | `@oyun/ortak/siralama` → `gonder(govde)` (çevrimdışı kuyruk) + `dogrula-<oyun>` |
| Sunucuda durum tutan deneme | `c.deneme(anahtar)` (örnek: `supabase/functions/dogrula-deneme`, `olay` dalı) |
| Günlük sıralama, ilk N + çevre | `tablo("gunluk", gun)` |
| Haftalık lig, kademe | `lig()`; ayarlar `ortak.oyunlar.ayarlar.lig`; kapanış pg_cron |
| Olay kaydı (Neon, D1, Supabase tablosu) | `@oyun/ortak/olcum` → PostHog (AB); oyuna özgü olaylar `uzantiOlaylar` |
| Hesap silme | `buOyundanSil()` ve `tamamenSil()`; web sayfası da ikisini sunar |
| Satın alma, "paket açık mı" kilidi, geri yükleme | `@oyun/ortak/odeme` (RevenueCat; aşağıda "Ödeme") |
| Ücretli dosyaların herkese açık durması | `korumali` kovası + `odeme.korumaliIndir(hak, dosya)` |
| Etkinlik takvimi, sezon, albüm ödülleri | `@oyun/ortak/etkinlik` (takvim opak; ödül eşitleme) |
| Kapalı test anketi | `@oyun/ortak/geri-bildirim` (karar + ölçüme gönderim; arayüz oyunda) |
| Günlük hatırlatma | `@oyun/ortak/bildirim` (yerel bildirim; sunucu push sonra) |

## Kurulum

```jsonc
// package.json
"dependencies": {
  "@oyun/ortak": "github:aliserdaryavuz/oyun-ortak#v0.1.0",
  "@supabase/supabase-js": "^2.119.0"
}
```

Yerelde iki depoyu birlikte geliştirirken `npm link ../_ortak/oyun-ortak` kullanılabilir. Bu bağlantı commit'e girmez.

Ortak değerler (hepsi herkese açık, uygulamaya gömülür):

| | `oyun-canli` (yayın) | `oyun-test` (önizleme) |
| --- | --- | --- |
| Supabase adresi | `https://qzxchutjzhyzzaoxzroh.supabase.co` | `https://vbygbyurswjjmiqrhvmo.supabase.co` |
| Anon / publishable anahtar | `npx supabase projects api-keys --remote=qzxchutjzhyzzaoxzroh` | `npx supabase projects api-keys --remote=vbygbyurswjjmiqrhvmo` |
| PostHog (AB, tek proje) | `phc_xLYVrxm9z6jsgXrGDpbUAKBypFX9qv5mhwVctX4QQia9` | Aynı anahtar; test olayları cihaz kimliğindeki `t-<kod>` ile ayrılır |

Tek ayar dosyası `src/oyun.config.ts`. Supabase adresi ve anon anahtarı gizli değildir, ama ortam değişkeninden gelir. Böylece önizleme `oyun-test`'e, yayın `oyun-canli`'ya bağlanır.

```ts
export const oyunConfig = {
  oyunId: "halka",
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL,
  supabaseAnon: import.meta.env.VITE_SUPABASE_ANON_KEY,
  posthogAnahtar: import.meta.env.VITE_POSTHOG_KEY ?? "", // boşsa ölçüm kapalı
  uzantiOlaylar: ["league_joined", "album_card"],
} as const;
```

Örnek `src/altyapi/index.ts` (Capacitor + web):

```ts
import { createClient } from "@supabase/supabase-js";
import { Preferences } from "@capacitor/preferences";
import { Capacitor } from "@capacitor/core";
import { capacitorDepo, webDepo, cihazKimligi, kayitDeposu } from "@oyun/ortak/kayit";
import { hesapBaslat } from "@oyun/ortak/hesap";
import { siralamaBaslat } from "@oyun/ortak/siralama";
import { olcumBaslat } from "@oyun/ortak/olcum";
import { oyunConfig as k } from "../oyun.config";

const depo = Capacitor.isNativePlatform() ? capacitorDepo(Preferences) : webDepo();
export const supabase = createClient(k.supabaseUrl, k.supabaseAnon);
export const hesap = hesapBaslat({ supabase, oyunId: k.oyunId, depo });
export const siralama = siralamaBaslat({ supabase, oyunId: k.oyunId, depo });
export const kayit = kayitDeposu({ depo, anahtar: `${k.oyunId}:kayit`, surum: 1, bos: () => ({}) /* , iceAl */ });
export const olcum = olcumBaslat({
  oyunId: k.oyunId, surum: __SURUM__, platform: Capacitor.getPlatform() as "web" | "android" | "ios",
  anahtar: k.posthogAnahtar, cihaz: await cihazKimligi(depo, new URLSearchParams(location.search).get("t")),
  depo, uzantiOlaylar: k.uzantiOlaylar,
});
```

Expo (Beat Greedy): depo, AsyncStorage'dan `{ oku: getItem, yaz: setItem, sil: removeItem }` ile verilir. Geri kalanı aynıdır.

### Giriş

- **Android/iOS:** yerel Google/Apple eklentisinden kimlik jetonu alınır, `hesap.idTokenIleGir("google" | "apple", token, nonce)` çağrılır. Eklenti oyunun bağımlılığıdır, paketin değil.
- **Web:** `hesap.webIleGir("google", donusAdresi)`. Dönüşte, açılışta `hesap.webDonusunuTamamla()` çağrılır.
- **E-posta kodu (yedek):** `epostaKoduGonder`, ardından `epostaKoduIleGir`.
- **Ortak akış:**
  1. Oyuncu misafir başlar. `anonimGir()` ilk çevrimiçi işte çağrılır; `siralama.gonder` bunu kendisi yapar.
  2. Girişten sonra `bulutKaydi().birlestir(yerel, birlestir)` çağrılır ve dönen `ozet` oyuncuya gösterilir.
  3. Ardından `baglamaOdulu()` çağrılır.
- Google ve Apple düğmeleri öne çıkarılır; e-posta kodu "başka yol" altında durur (kesin karar).

#### Giriş düğmeleri: marka kuralları (zorunlu)

Bu düğmeler oyunun paletine boyanmaz ve logoları değiştirilmez. Kurallara uymayan düğme Google OAuth doğrulamasında ve mağaza incelemesinde geri çevrilme nedeni olur. Düğme bileşeni oyunda yaşar, paket arayüz çizmez. Örnek uygulama: sezgi `apps/mobile/src/ui/GoogleButton.tsx`.

**Google** ([Google Identity marka kuralları](https://developers.google.com/identity/branding-guidelines)):

| | Koyu tema | Açık tema |
|---|---|---|
| Zemin | `#131314` | `#FFFFFF` |
| 1 px kenar | `#8E918F` | `#747775` |
| Yazı | `#E3E3E3` | `#1F1F1F` |

- Standart dört renkli "G" kullanılır (`#EA4335`, `#4285F4`, `#FBBC05`, `#34A853`). Logo 20 px boyunda olur ve yazıdan 10 px önde durur.
- Yazı Roboto Medium 14 olur. Roboto yalnız bu düğme için yüklenir.
- Köşe yarıçapı 4 px. Yükseklik en az 40; dokunma hedefi için 44 önerilir.
- Metin "Google ile devam et" ya da "Continue with Google" olur.

**Apple** ([Sign in with Apple HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)):

- Üç biçimden biri kullanılır: siyah, beyaz ya da beyaz zemin üstüne siyah kenarlı. Başka renk kullanılmaz.
- Apple logosu ve "Apple ile devam et" ya da "Continue with Apple" metni kullanılır. iOS'ta sistemin `ASAuthorizationAppleIDButton` düğmesi tercih edilir.
- Düğme Google düğmesiyle aynı boyda olur ve ondan daha az öne çıkarılmaz. App Store 4.8 kuralı gereği, iOS'ta Google girişi sunan oyun Apple girişini de sunar.

## v0.2 paketleri

### Ödeme (`@oyun/ortak/odeme`)

Kurulum, oyun başına bir kez:
1. **Bu depoda göç:** ürün → hak eşlemesi. Örnek: `insert into ortak.urunler values ('halka_paket_tam', 'halka', 'paket_tam');`
2. **RevenueCat:** projeye oyunun uygulamasını (Play/App Store) ekle. Entitlement kimliği = haktaki ad (`paket_tam`), ürün kimliği = mağaza ürün kimliği. RevenueCat'in uygulama kimliklerini (`app_…`, Play ve App Store ayrı) oyunun ayarına yaz: `ayarlar.odeme.revenuecat_uygulamalari = ["app_…"]`. TRANSFER (başka hesapta geri yükleme) yalnız bu eşlemeyle ve yalnız o oyunun haklarını taşır.
3. **RevenueCat → Integrations → Webhooks:**
   - Adres: `https://qzxchutjzhyzzaoxzroh.supabase.co/functions/v1/odeme-webhook`
   - Authorization header: `C:\Users\alise\.oyun-ortak\odeme-webhook.env` dosyasındaki değer. Bütün oyunlar aynı webhook'u kullanır.
4. **Oyunda:** RevenueCat eklentisini `Magaza` arayüzüne saran birkaç satır.

```ts
import { Purchases } from "@revenuecat/purchases-capacitor";
const ent = (c: CustomerInfo) => Object.keys(c.entitlements.active);
const magaza: Magaza = {
  kullaniciAta: async (id) => void (await Purchases.logIn({ appUserID: id })),
  haklar: async () => ent((await Purchases.getCustomerInfo()).customerInfo),
  satinAl: async (urun) => {
    const { products } = await Purchases.getProducts({ productIdentifiers: [urun], type: PRODUCT_CATEGORY.NON_SUBSCRIPTION });
    return ent((await Purchases.purchaseStoreProduct({ product: products[0]! })).customerInfo);
  },
  geriYukle: async () => ent((await Purchases.restorePurchases()).customerInfo),
};
export const odeme = odemeBaslat({ supabase, oyunId, depo, magaza: Capacitor.isNativePlatform() ? magaza : undefined });
```

Kullanım:
- **Açılışta** `await odeme.hakVar("paket_tam")` (önbellekten, ağ beklemez), ardından `odeme.yenile()`.
- **Satın alma:** `odeme.satinAl("halka_paket_tam")`. Web'de `web_satis_yok` hatası verir.
- **Geri yükleme:** `odeme.geriYukle()`.

Davranış:
- **Hak süresizdir:** ağsız açılışta da açık kalır.
- **İade:** RevenueCat iadeyi bildirince sunucuda `iade` olur; bir sonraki `yenile()` hakkı düşürür. Mağaza hâlâ veriyorsa (aile paylaşımı) hak kalır.
- **Web:** hesapta hak varsa görünür, satın alma yapılamaz.
- **Korumalı içerik (HK-8):**
  - Ücretli dosyalar `korumali/<oyun>/<hak>/...` yoluna servis anahtarıyla yüklenir; yükleme betiği oyun deposundadır.
  - Oyun dosyayı `odeme.korumaliIndir("paket_tam", "zor-001.json")` ile alır.
  - Hakkı olmayan hesap indiremez. İnen dosyayı çevrimdışı için saklamak oyunun işidir.

### Etkinlik (`@oyun/ortak/etkinlik`)

- **Takvim:** oyunun Pages sitesinde statik JSON. Örnek: `public/etkinlik/takvim.json` (HK-7, EN-8).
- **Kurulum:** `etkinlikBaslat({ oyunId, adres, depo, dogrula, supabase })`. `dogrula`, ham JSON'dan geçerli takvimi döner ve geçmeyen kayıtları atar (KM-8).
- **Okuma:** `takvim()` ağ yoksa son geçerli takvimi verir. Yardımcılar: `suren(liste)`, `yaklasan(liste)`, `kalanSure(oge)`. Hepsi İstanbul günüyle çalışır, öğelerde `baslangic`/`bitis` (YYYY-MM-DD, dahil) beklenir.
- **Ödül:** `odulKazan("rozet-usta", "usta-2026-11")` cihazda hemen kaydeder; oturum varsa sunucuya bir kez yazar.
- **Eşitleme:** açılışta ve girişten sonra `esitle()`; başka cihazda kazanılanları getirir. Ödül kimliği `^[a-z0-9_:.-]{1,64}$`.
- **Sıralama ödülü (HK-3, "ilk %10"):** `select ortak.siralama_odulu_ver('halka', 'etkinlik', '<etkinlik_id>', 'sira:<odul>', 0.1)`. Oyunun cron işi ya da elle çalıştırılır; eşitler dahil. Kimlik `sira:` ile başlar; bu önekli ödülleri istemci kendine yazamaz.

### Geri bildirim (`@oyun/ortak/geri-bildirim`)

- **Kurulum:** `geriBildirimBaslat({ depo, olcum, anketler, etkin })`. `etkin` kapalı test sürümünde `true` olur; ör. `testKodu(cihaz) != null` ya da derleme bayrağı.
- **Akış:**
  1. Oyun olayları `say("cozum")` ile sayılır.
  2. Uygun anda `siradaki()` anket döner. Oyun anketi kendi arayüzüyle gösterir ve `gosterildi(id)` çağırır.
  3. Cevaplar `cevapla(id, cevaplar)` ile verilir.
- **Koşul:** `{ sayac: { ad: "cozum", esik: 5 } }` ve/veya `{ gun: 7 }` (ilk açılıştan bu yana).
- **Gönderim:** cevaplar PostHog'a `geri_bildirim` olayı olarak gider. Serbest metin 200 karakterde kesilir; kişisel veri istenmez.

### Şikâyet (`hesap.sikayetEt`, v0.3)

- **Kullanım:** `hesap.sikayetEt(ad, "ad" | "hile" | "diger")`. Sıralama ya da lig satırındaki adla çağrılır; oyuncu kimliği istemciye hiç verilmez.
- **Kim şikâyet edebilir:** yalnız kalıcı hesaplar (Google, Apple ya da e-posta), günde en çok 20 şikâyet. Anonim hesaplar şikâyet edemez.
- **Ad şikâyeti:** farklı kalıcı hesaplardan gelen şikâyet sayısı eşiğe ulaşınca hedefin adı sıfırlanır.
  - Eşik oyunun ayarında: `ayarlar.sikayet.ad_esigi`, varsayılan 3.
  - Yalnız o oyunda en az `ayarlar.sikayet.en_az_gun` (varsayılan 2) gündür oynayan kalıcı hesapların şikâyeti sayılır; daha yeni hesapların şikâyeti kaydedilir ama sayılmaz.
  - Yalnız şu anki ada yapılan şikâyetler sayılır; oyuncu adını değiştirirse eski şikâyetler düşer.
  - Misafirken alınan şikâyetler hesap bağlanınca yeni hesaba taşınır.
  - Sıralama adsız oyuncuyu gösterirken oyun "Oyuncu" yazar.
  - Oyuncu hemen yeni ad seçebilir; 30 gün sınırı sıfırlanır.
- **`hile` ve `diger`:** yalnız kaydedilir. İnceleme Supabase panelinden `ortak.sikayetler` tablosuyla yapılır.
- **Arkadaş düellosu (KH-5'in diğer yarısı):** oyuna özgü kaldı; Koz Hesabı kendi şemasında yapar.

### Kendi sunucusu olan oyun (`@oyun/ortak/sunucu-node`, v0.4)

Sticky Ten gibi gerçek zamanlı sunucusu olan oyunlar için (ST-4).

**Jeton doğrulama:**
```ts
const dogrula = jetonDogrulayici({ url: SUPABASE_URL, anahtar: SUPABASE_ANON_KEY });
const oyuncu = await dogrula(jeton);
```
- Dönüş `{ id, anonim, eposta, bitis }` ya da `null`.
- İmza, süre, `aud` ve `role` denetlenir.
- Socket.IO'da `io.use(...)` içinde `soket.handshake.auth.jeton` ile kullanılır.
- Bağlantı açıkken yenilenen jetonu istemci olayla yeniden gönderir.

**Yazma:**
- `servisIstemcisi({ url, servisAnahtari, sema: "sticky" })` servis rolüyle yazar.
- Servis anahtarı yalnız sunucunun ortam değişkenindedir; istemciye gitmez.

**Sticky Ten (`sticky` şeması):**

| Fonksiyon | Yaptığı |
| --- | --- |
| `sticky.oyun_sonu(oyuncular, gun, ciftler)` | Oyun sonucunu tek işlemde yazar: istatistik, rating, rating günlüğü ve ikili sayaç |
| `sticky.siralama(donem)` | `gun` / `hafta` / `ay` / `tum`; herkese açık, kimlik döndürmez |
| `sticky.haftalik_odul()` | Pazartesi 00:01 İstanbul cron'u; `sira:hafta-ilk10:<hafta>` ve `sira:hafta-ilk3:<hafta>` |
| `sticky.takip_et` / `sticky.takibi_birak` / `sticky.takip_ettiklerim` | Takip, en çok 100 |

- Kullanıcı adı `ortak.oyuncular('sticky')`'de tutulur.
- Deluxe `ortak.haklar` (ürün `sticky_deluxe`, hak `deluxe`).

### Bildirim (`@oyun/ortak/bildirim`)

- **Kurulum:** `bildirimBaslat({ yerel, depo })`. `yerel`, oyunun yerel bildirim eklentisini (ör. `@capacitor/local-notifications`) saran üç işlev: `izinIste`, `planla`, `iptal`.
- **Açıp kapatma:** `ayarla({ acik, saat, dakika, baslik, metin })`. Açarken izin ister.
- **Günlük akış:** günün oyunu bitince `oynandi()` bugünkü hatırlatmayı atlar. Açılışta `yenile()` 7 günlük pencereyi kaydırır.
- **Sunucu push (FCM/APNs):** Firebase projesi açılınca eklenecek.

## Sunucu kuralları (oyun şeması göçleri için)

- Oyun şeması adı oyun kimliğidir (`halka`, `sezgi`). Şema `supabase/config.toml` içindeki `api.schemas` listesine ve canlıda panelde "Exposed schemas" listesine eklenir.
- Kullanıcıya bağlı her tablo `references auth.users on delete cascade` taşır ("Hesabımı tamamen sil" buna dayanır).
- Oyun `<sema>.oyuncu_verisini_sil(uuid)` fonksiyonunu sağlar ve adını `ayarlar.hesap.silme_fonksiyonu`'na yazar ("Bu oyundaki verimi sil").
- RLS her tabloda açık. İstemci tabloya değil, `security definer` + `set search_path = ''` RPC'ye gider.
- **Her göç kendi sonunda** `revoke execute on all functions in schema <sema> from public;` içerir. Postgres her fonksiyona PUBLIC yetkisi verir ve şema bazındaki varsayılan yetki bunu geri alamaz. İstemciye açılacak fonksiyon adıyla `grant` edilir.
- Skoru yalnız `dogrula-<oyun>` (servis rolü) yazar. İstemcinin bildirdiği puan kullanılmaz; cevaplı içerik istemciye gönderilmez.
- Cron işleri `<oyun>-` önekiyle adlandırılır.

### `ortak.oyunlar.ayarlar`

```jsonc
{
  "ad":       { "en_az": 3, "en_cok": 16, "degistirme_gun": 30, "yasakli": ["koz"], "onekler": ["Çırak", "Kalfa"] },
  "hesap":    { "baglama_odulu": "desen-porselen", "silme_fonksiyonu": "halka.oyuncu_verisini_sil" },
  "siralama": { "yon": "azalan", "esitlik": "ortak", "dagilim_esigi": 50 },
  "lig":      { "kademeler": ["Çırak", "Kalfa", "Usta", "Başusta", "Üstat"], "grup_boyu": 50,
                "cikis_orani": 0.2, "inis_orani": 0.2, "en_iyi_gun": 5, "esitlik": "ortak", "bant_genisligi": 0 }
}
```

Alanların anlamı:

| Alan | Anlamı |
| --- | --- |
| `siralama.yon` | `"artan"`: küçük puan önde (süre gibi) |
| `siralama.esitlik` | `"ikincil"`: eşit puanda `ikincil` küçük olan önde. `"ortak"`: eşitler aynı sırayı paylaşır |
| `lig` | Yazılmazsa oyunun ligi yoktur |
| `lig.bant_genisligi` | `> 0` ise gruplar `seviye_puani`'na göre ayrılır (KH-4) |
| `ad.yasakli` | Oyuna özgü ek yasaklı sözler |
| `ad.onekler` | Otomatik ad önekleri; yazılmazsa "Oyuncu" |

İstek sınırı fonksiyonun içinde verilir: `istek({ oyunId, kullaniciDakika, oyunDakika })`. Kullanıcı sınırı oyunun bütün doğrulama fonksiyonları için ortaktır.

## `dogrula-<oyun>`

- `sablon/dogrula/index.ts` ve `deno.json` kopyalanır. İçe aktarma etiketli adresten yapılır (`.../oyun-ortak/v0.1.0/sunucu/mod.ts`).
- Gövde sözleşmesi oyunun ISTEKLER satırındakidir (KM-6, EN-1, HK-1).
- Durum tutan oyunlarda yeniden gönderimi tanımak için olay günlüğü durumda tutulur. Eski sırayla gelen olay günlükteki olayla aynıysa "tekrar" sayılır, farklıysa 409 döner.
- Yayın:
  1. Yerel yığında dene.
  2. Oyun deposundan `npx supabase functions deploy dogrula-<oyun> --project-ref <oyun-canli>`.

## Testler

Bu depo:
- `npm test`: istemci, sunucusuz.
- `npm run test:sunucu`: yerel Supabase'e karşı.
- İkisi de yerelde, gönderimden önce koşulur. Oyun depolarında GitHub Actions kullanılmaz (2026-11-14 kararı; gizli depolarda dakika kotası var). Yalnız açık oyun-ortak deposunun `test.yml`'i kalır.

Yeni bir RPC eklendiğinde `tests/sunucu/yetki.test.ts` içindeki izin listesine bilerek eklenir.

Yerelde geliştiren için not: Edge çalıştırıcısı fonksiyon kodunu önbellekte tutar. Kod değişince `docker restart supabase_edge_runtime_oyun-ortak` gerekir.
