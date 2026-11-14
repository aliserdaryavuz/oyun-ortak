# ARAYÜZ · asyworks.com

Yayın: Cloudflare Pages projesi `asyworks`. Bu deponun `site/` klasörü yayınlanır, derleme adımı yoktur. `main`'e her push siteyi günceller. Adresler: asyworks.com ve www.asyworks.com. Alan adı Search Console'da doğrulandı; DNS'teki `google-site-verification` TXT kaydı silinmez. Google giriş onay ekranı "ASYWorks" adıyla doğrulanmış ve yayında (2026-11-14).

ASYWorks sitesinin (`site/`) tek doğruluk kaynağı bu belge ve `site/ana.css`'tir. Oyunların arayüz belgeleriyle (ör. Beat Greedy `docs/ARAYUZ.md`) aynı düzende yazıldı. Gizlilik ve hesap silme sayfaları (`site/stil.css`) aynı renk ve yazıyı kullanır, aynı tek ekran kabuğundadır (§4.1).

## 1. Sanat yönü

- **Ad:** Atölye Rafı.
- **Tema:** Gece çalışan küçük bir oyun atölyesi. Lacivert tezgâh, üstünde kehribar bir raf; bitmiş oyunlar o rafta durur.
- **Dayandığı malzeme:** logonun kendisi. Lacivert `#17283B` tezgâh, kehribar `#F2B544` pirinç parça, fildişi `#F5F1E8` kâğıt.
- **İmza öğesi: kehribar kama.** Logodaki A'nın içindeki kehribar yamuk. Ana bölümde dört oyunun simgesinin üstünde durduğu raf olur. Her oyunun telefon görüntüsü de bir kamanın üstünde durur. Birincil düğme de bu yamuğun biçimini alır: alt kenarı üst kenarından geniştir. Gerekçe: site ekran görüntüsünde bile ASYWorks'ün A'sından tanınsın.
- **Hareket:** tek bir yüklenme anı var. Dört simge sırayla rafa iner ("hop"). Başka kendiliğinden hareket yok. `prefers-reduced-motion` açıksa simgeler yerinde durur.
- **Referanslar:**
  - *Panic* ve *Annapurna Interactive* siteleri. Alınacak: her oyunun kendi rengini ve dünyasını taşıyan geniş bant. Alınmayacak: tam ekran video ve ağır kaydırma efekti.
  - *Nintendo* oyun sayfaları. Alınacak: oyunun gerçek ekranını gösterip kısa ve somut anlatmak. Alınmayacak: kalabalık rozet ve etiket.
- **Kaçınılan şablon izleri:** eş kart ızgarası, büyük harfli üst etiketler, başlıkta tek kelimeyi renklendirmek, orta noktalı etiket dizileri, düğme metnine ok eklemek, gradyan yıkama.

## 2. Renkler

| Rol | Hex | Kullanıldığı yer |
| --- | --- | --- |
| Tezgâh | `#17283B` | Üst ve alt bant zemini |
| Derin | `#0F1D2C` | Gölge yüzeyi, A silüetinin içi |
| Kabarık | `#1F3650` | A silüeti, kenar çizgileri |
| Kâğıt | `#F5F1E8` | Sayfa zemini (açık), lacivert üstünde metin |
| Kehribar | `#F2B544` | Raf ve kama, birincil düğme, odak halkası |
| Kehribar kenar | `#B9831E` | Düğmenin basılı alt kenarı |
| Soluk (lacivert üstü) | `#A9B6C4` | İkincil metin |
| Soluk (kâğıt üstü) | `#55606D` | İkincil metin |

Oyun bantlarında her oyunun kendi rengi kullanılır (simgesinden alındı), başka yerde kullanılmaz:

| Oyun | Bant | Metin |
| --- | --- | --- |
| Hop Koala | `#FF8A1E` | `#2A1600` |
| Halka Kelime | `#E9EEF8` | `#1B2F6E` |
| Sticky Ten | `#3A2116` | `#F7E3C4` |
| Beat Greedy | `#12293D` | `#F4F0E6` |

Koyu tema (`prefers-color-scheme: dark`) yalnız kâğıt zeminini lacivert-derine çevirir; oyun bantları aynı kalır.

## 3. Yazı

| Aile | Rol | Lisans | Türkçe |
| --- | --- | --- | --- |
| Archivo, genişlik 125, kalınlık 800 | Başlık, oyun adı, birincil düğme | OFL | Tam |
| Archivo, genişlik 100, kalınlık 400 ve 600 | Metin, bağlantı | OFL | Tam |

Tek aile, iki genişlik. Geniş ve kalın kesim logodaki ASY harflerinin geniş, ağır duruşuna denk gelir. Dosyalar `site/yazi/` altında, sitenin kendi sunucusundan yüklenir (Google Fonts'a istek gitmez). Inter, Roboto ve sistem yazısı kullanılmaz.

Basamaklar (360 → 1440 px):

| Basamak | CSS | Kullanım |
| --- | --- | --- |
| Dev | `clamp(40px, 7.2vw, 92px)` | Ana başlık |
| Büyük | `clamp(30px, 4.4vw, 56px)` | Oyun adı |
| Orta | `clamp(22px, 2.4vw, 30px)` | Bölüm başlığı |
| Metin | `clamp(17px, 1.05rem + .15vw, 19px)` | Metin |
| Küçük | `15px` | Alt bilgi, ikincil |

Satır uzunluğu en çok 60 karakter.

## 4. Biçim

- Köşe yarıçapı hiyerarşiye göre değişir: oyun bandı 32 px, telefon çerçevesi 36 px, simge %22, düğme 10 px.
- Dokunma hedefi en az 44 px. Klavye odağı kehribar, 3 px.
- Sayfa kaydırılmaz (oyunlardaki tam ekran kuralı); ayrıntı §4.1.

### 4.1 Tek ekran (14 Kasım 2026)

- Kök `100dvh`, gövde `overflow: hidden`. Bölümler sekmedir: Ana sayfa, Oyunlar, Hakkında, İletişim. Sekmeler geniş ekranda üst çubukta, 700 px altında altta.
- Metin dili: ASYWorks bir stüdyo değil, oyunların yayımlandığı ad. "Stüdyo" ve "tek başıma" denmez; marka üçüncü şahısla anılır ("ASYWorks … yapar"). "Kısa oyun" gibi küçümseyen ifadeler kullanılmaz. Metinler Fable 5.2 ile sadeleştirildi (14 Kasım 2026).
- Önbellek: Cloudflare CSS ve JS dosyalarını tarayıcıda 4 saat tutar. `ana.css`, `stil.css` ya da `sekme.js` değişince sayfalardaki `?v=` değeri dosyanın yeni özetiyle değiştirilir: `git hash-object site/ana.css | cut -c1-8`.
- Sekme ve oyun seçimi yalnız CSS ile (`:target` + `:has`); JavaScript gerekmez, geri tuşu ve doğrudan bağlantı (`/#halka-kelime`) çalışır.
- Oyunlar tek tek, kendi renginde bir pencerede gösterilir. Pencere geniş ekranda iki sütun (metin, telefon), dikeyde bilgi solda telefon sağda; kısa dikey pencerede (560 px altı) başlık ve açıklama aynı satırda.
- Telefon çerçevesi ve kehribar raf SVG'dir: kalan yüksekliğe sığar, oranı bozulmaz. Yazı basamakları bölüm kutusunun boyuna göre ölçeklenir (`cqw`/`cqh`).
- Bölüm içi kaydırma yalnız son çare (360×640'tan küçük ekran, büyük yakınlaştırma); içerik kesilmez.
- Gizlilik ve hesap silme aynı kabukta; bölümleri sekme. Tablet ve bilgisayarda her sekme sığar. Telefonda uzun yasal metin panel içinde kayar (tek istisna); sayfa kaymaz.
- Kabul: 360×640, 390×844, 820×1180, 1180×820, 1440×900 (ayrıca 1024×768, 1920×1080) görünümlerinde her sekme ve her oyun için sayfa ve bölüm kaydırması 0.

## 5. Metin

- Somut ve kısa: oyunun ne olduğunu ve nasıl oynandığını söyler, övmez.
- "Reklam yok" iddiası bütün oyunlar için doğrudur (gizlilik sayfası). Yeni iddia eklenmeden önce dört oyunda da doğru olduğu kontrol edilir.
- Mağaza bağlantıları yayına çıkınca "Yakında" yazısının yerine resmî Google Play ve App Store rozetleri konur.
