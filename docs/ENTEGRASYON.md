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
| Ödeme, etkinlik, geri bildirim, bildirim | v0.2 |

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
- GitHub Actions ikisini de her gönderimde çalıştırır.

Yeni bir RPC eklendiğinde `tests/sunucu/yetki.test.ts` içindeki izin listesine bilerek eklenir.

Yerelde geliştiren için not: Edge çalıştırıcısı fonksiyon kodunu önbellekte tutar. Kod değişince `docker restart supabase_edge_runtime_oyun-ortak` gerekir.
