# Kadraj tasarım sistemi

Kadraj, fotoğraf makinesindeki vizör karesinin adını taşır. Arayüz de vizör gibi davranır: içerik öndedir, kabuk geri çekilir, renk yalnızca odak anlarında görünür.

Kaynak kod `Sources/KadrajDesign` içindedir. Kontrast ve tutarlılık denetimleri `swift run HarnessDesign` ile çalışır ve örnek sayfayı aynı komut üretir.

## İlkeler

1. **Kabuk nötr, ekran görüntüsü renkli.** Kullanıcının içeriğiyle yarışan renkli yüzey olmaz. Grafit nötrler arayüzün yüzde 90'ını taşır.
2. **Tek vurgu, tek anlam.** Vurgu rengi yalnızca seçili durumu ve görünümdeki tek birincil eylemi gösterir.
3. **Yerel davranış, özel görünüm.** Sistem fontu, klavye odak halkası, azaltılmış hareket, saydamlık ve artırılmış kontrast ayarları korunur.
4. **Sık yapılan iş anında olur.** Kısayolla açılan yakalama katmanı animasyon almaz. Hareket yalnızca seyrek anlara ve basma geri bildirimine aittir.

## Katmanlar

| Katman | Örnek | Kim kullanır |
| --- | --- | --- |
| İlkel | `Palette.neutralLight[11]` | Yalnızca `KadrajDesign` içi, dışarıya kapalıdır (`internal`) |
| Anlamsal | `DS.Color.textSecondary` | Bütün bileşenler |

Görünüm değişimi anlamsal katmanda çözülür. Yakalama katmanı gibi her zaman koyu olan yüzeyler pencereye `.darkAqua` atar ve aynı tokenları kullanır, bu yüzden ayrı bir HUD renk ailesi yoktur.

## Renk

Değerler OKLCH ile tanımlanır ve sRGB'ye çevrilirken gamut dışına çıkan renklerin kroması düşürülür. Rampalar Radix modelini izler: her adımın bir görevi vardır, açık ve koyu rampalar ayrı ayrı tasarlanır, biri diğerinin tersi değildir.

### Nötr rampa, ton 85, kroma 0.004 ile 0.005

| Adım | Görev | Açık L | Koyu L |
| --- | --- | --- | --- |
| 1 | Pencere ve sayfa | 0.985 | 0.17 |
| 2 | Hafif yüzey | 0.97 | 0.20 |
| 3 | Bileşen zemini | 0.945 | 0.235 |
| 4 | Bileşen üzerine gelme | 0.92 | 0.265 |
| 5 | Bileşen basılı veya seçili | 0.895 | 0.295 |
| 6 | Ayraç | 0.865 | 0.33 |
| 7 | Kenarlık | 0.82 | 0.39 |
| 8 | Güçlü kenarlık (3:1 hedefi) | 0.62 | 0.56 |
| 9 | Dolu nötr | 0.60 | 0.58 |
| 10 | Devre dışı metin | 0.62 | 0.50 |
| 11 | İkincil metin | 0.46 | 0.79 |
| 12 | Birincil metin | 0.22 | 0.95 |

### Vurgu: Odak

Vizördeki odak karesinin limon sarısı. Dolu dolgu açık tonda kaldığı için üzerindeki metin koyudur, beyaz değildir.

| Rol | Açık (L, C, h) | Koyu (L, C, h) |
| --- | --- | --- |
| subtle | 0.955, 0.04, 105 | 0.27, 0.05, 105 |
| border | 0.80, 0.09, 105 | 0.47, 0.09, 105 |
| solid | 0.90, 0.18, 105 | 0.90, 0.18, 105 |
| solidHover | 0.86, 0.18, 105 | 0.86, 0.18, 105 |
| text | 0.50, 0.13, 105 | 0.90, 0.11, 105 |
| mark | text ile aynı | solid ile aynı |
| wash | solid, yüzde 22 | solid, yüzde 22 |
| onSolid | 0.20, 0.01, 105 | 0.20, 0.01, 105 |

`accentSolid` açık zeminde 3:1 altında kalır, bu yüzden tek başına işaret olamaz ve her zaman `onAccent` etiketi taşır. Halka, onay işareti ve kaydırıcı dolgusu gibi etiketsiz işaretler `accentMark` kullanır (3:1). Ekran içeriğinin üstüne binen vurgu, örneğin pencere vurgusu, `accentWash` dolgusu ve `selectionHalo` çizgili `accentSolid` kenar kullanır, çünkü her içerikte görünmesi gerekir.

### Durum renkleri

Kod tabanında üç durum gerçekten görünür: kısayol çakışması ve eksik izin için `danger`, etkin izin için `success`, kaydırma uyarısı için `warning`. `warning` limon vurgudan en az 15 derece uzak kalmak için turuncuya kaymıştır (h 55).

| Rol | danger açık | danger koyu | warning açık | warning koyu | success açık | success koyu |
| --- | --- | --- | --- | --- | --- | --- |
| subtle | .955 .025 25 | .27 .06 25 | .955 .04 55 | .27 .05 55 | .955 .03 150 | .26 .05 150 |
| border | .82 .09 25 | .45 .12 25 | .82 .10 55 | .47 .10 55 | .82 .09 150 | .45 .09 150 |
| solid | .55 .20 25 | .58 .19 25 | .72 .17 55 | .76 .16 55 | .52 .13 150 | .55 .14 150 |
| text | .50 .17 25 | .76 .13 25 | .50 .13 55 | .80 .13 55 | .46 .11 150 | .80 .14 150 |

`danger.solid` ve `success.solid` üzerine beyaz, `warning.solid` üzerine koyu metin gelir.

### Anlamsal roller

| Token | Açık | Koyu | Görev |
| --- | --- | --- | --- |
| `bgWindow` | n1 | n2 | Pencere zemini |
| `bgSurface` | n2 | n3 | Panel, kart, kenar çubuğu |
| `bgRaised` | n1 | n4 | Menü, açılır panel |
| `bgSunken` | n3 | n1 | Girdi, kuyu |
| `bgCanvas` | n4 | n1 | Ekran görüntüsünün arkasındaki alan |
| `bgControl` | n3 | n4 | Kontrol zemini |
| `bgControlHover` | n4 | n5 | Üzerine gelme |
| `bgControlActive` | n5 | n6 | Basılı veya seçili |
| `bgHud` | n2 koyu, yüzde 88 | aynı | Ekranın üstünde yüzen araç çubuğu |
| `bgScrim` | siyah, yüzde 45 | aynı | Yakalamada seçim dışı karartma |
| `textPrimary` | n12 | n12 | Birincil metin |
| `textSecondary` | n11 | n11 | İkincil metin |
| `textDisabled` | n10 | n10 | Devre dışı metin |
| `separator` | n6 | n6 | İçeriği bölen çizgi |
| `borderSubtle` | n6 | n6 | Sessiz kenar |
| `border` | n7 | n7 | Kontrol kenarı |
| `borderStrong` | n8 | n8 | Girdi sınırı, 3:1 |
| `focusRing` | sistem | sistem | `keyboardFocusIndicatorColor` |
| `imageOutline` | siyah yüzde 10 | beyaz yüzde 10 | Ekran görüntüsü kenarı |
| `selectionStroke` | beyaz | beyaz | Seçim çerçevesi |
| `selectionHalo` | siyah yüzde 45 | aynı | Her içerikte görünsün diye çerçevenin dış çizgisi |

Artırılmış kontrastta `textSecondary` n12'ye, `border` n8'e, `borderSubtle` ve `separator` n7'ye geçer. Azaltılmış saydamlıkta `bgHud` opak olur.

## Tipografi

Sistem fontu kullanılır: SF Pro boyuta göre optik kesim ve harf aralığını kendisi ayarlar, bu yüzden elle izleme yoktur. Büyük harfli başlık da yoktur, çünkü Türkçe i/İ dönüşümünü bozar ve doğal yazım daha sakindir.

| Token | Boyut / satır | Ağırlık | Görev |
| --- | --- | --- | --- |
| `title` | 20 / 26 | semibold | Pencere ve boş durum başlığı |
| `heading` | 15 / 20 | semibold | Bölüm başlığı |
| `body` | 13 / 18 | regular | Gövde |
| `bodyStrong` | 13 / 18 | medium | Vurgulu gövde, buton |
| `label` | 12 / 16 | medium | Kontrol etiketi |
| `caption` | 11 / 14 | regular | Yardımcı metin |
| `captionStrong` | 11 / 14 | semibold | Küçük grup başlığı |
| `readout` | 11 / 14 | medium, SF Mono | Boyut, koordinat, yakınlaştırma |
| `readoutLarge` | 20 / 26 | semibold, SF Mono | Kaydırmalı yakalamada yükseklik |
| `numeral` | 96 / 96 | semibold, rounded | Geri sayım |

## Boşluk ve boyut

Dört tabanlı ölçek, sıkı araç çubukları için 2 ve 6 eklenmiştir: `Space.s2, s4, s6, s8, s12, s16, s24, s32`.

| Token | Değer | Görev |
| --- | --- | --- |
| `Size.controlSmall` | 22 | Özellik çubuğu kontrolleri |
| `Size.control` | 28 | Standart kontrol, araç düğmesi |
| `Size.controlLarge` | 36 | Yakalama araç çubuğu düğmesi |
| `Size.iconSmall`, `icon`, `iconLarge` | 12, 14, 16 | SF Symbol nokta boyutu |

## Köşe

| Token | Değer | Görev |
| --- | --- | --- |
| `Radius.xs` | 4 | Küçük rozet, kısayol tuşu |
| `Radius.sm` | 6 | Küçük kontrol |
| `Radius.md` | 8 | Kontrol, araç düğmesi |
| `Radius.lg` | 12 | HUD çubuğu (8 + 4 dolgu), küçük kart |
| `Radius.xl` | 16 | Panel, Hızlı Erişim kartı |

İç içe yüzeylerde `Radius.concentric(inner:padding:)` kullanılır: dış = iç + dolgu.

## Yükselti

Gölge derinlik içindir, kenarlık yapı içindir. Her seviye bir gölge çifti ve üst kenarda ışık çizgisi taşır.

| Token | Temas gölgesi | Ortam gölgesi | Üst ışık | Görev |
| --- | --- | --- | --- | --- |
| `Elevation.raised` | y1 b2, yüzde 12 | y2 b6, yüzde 10 | yok | Menü, küçük kart |
| `Elevation.hud` | y1 b3, yüzde 30 | y8 b24, yüzde 35 | beyaz yüzde 10 | Yakalama çubuğu, HUD |
| `Elevation.floating` | y2 b4, yüzde 25 | y12 b32, yüzde 40 | beyaz yüzde 12 | Hızlı Erişim kartı, iğne |

## Hareket

| Token | Değer | Görev |
| --- | --- | --- |
| `Motion.Duration.press` | 0.10 sn | Basma geri bildirimi |
| `Motion.Duration.fast` | 0.15 sn | Üzerine gelme, renk, çıkış |
| `Motion.Duration.base` | 0.20 sn | Açılır panel, ipucu |
| `Motion.Duration.slow` | 0.30 sn | Hızlı Erişim girişi, üst sınır |
| `Motion.Curve.easeOut` | 0.23, 1, 0.32, 1 | Giriş ve çıkış |
| `Motion.Curve.easeInOut` | 0.77, 0, 0.175, 1 | Ekranda yer değiştirme |
| `Motion.pressScale` | 0.96 | Basılı düğme |
| `Motion.enterScale` | 0.96 | Giriş başlangıcı, sıfırdan büyüme yok |

Sürüklemeyle devam eden hareket yay kullanır: sönüm 1.0, tepki 0.3. Fırlatma varsa sönüm 0.8. `Motion.isReduced` doğruysa konum ve ölçek hareketi yerine yalnızca opaklık kullanılır.

## Bileşenler

Web tarafındaki karşılıklar: token CSS değişkeni, bileşen `NSView` veya `NSButton` alt sınıfı, props `init` parametresi, Storybook ise `swift run HarnessDesign` çıktısıdır. Bileşenler `Sources/KadrajDesign/Components` içindedir ve yalnızca token kullanır.

| Bileşen | Varyant ve seçenek | Nerede |
| --- | --- | --- |
| `Button` | `primary`, `secondary`, `ghost`, `danger`; `small`, `regular`, `large`; isteğe bağlı ikon | Capture, Done, Cancel, ayar eylemleri |
| `IconButton` | `small`, `regular`, `large`; `isSelected`; `tone: .plain` veya `.overlay` (yuvarlak, görüntü üstünde) | Araç çubukları, Hızlı Erişim eylemleri |
| `TextInput` | `small`, `regular`; `monospaced` | Boyut alanları, formlar |
| `Surface` | `hud`, `raised`, `floating`, `panel` | Çubuk, kart, panel zemini |
| `Segments` | Simgeli veya yazılı; `selectOne` ya da `momentary`; gruplar arası ayraç (`NSSegmentedControl` alt sınıfı) | Editör araçları, stil seçimi |
| `Slider` | Küçük boy, nötr dolgu (`NSSlider` alt sınıfı) | Kalınlık, dolgu, köşe |
| `Checkbox` | Açık, kapalı (`NSButton` alt sınıfı) | Panel seçenekleri |
| `Separator` | `horizontal`, `vertical` | Gruplar arası çizgi |
| `Badge` | `neutral`, `accent`, `danger`, `warning`, `success`; ikon ve metin birlikte | Durum bildirimi |
| `Label` | `DS.Text` stili ve renk rolü | Her metin |

Yüzen pencereler (Hızlı Erişim kartı gibi) saydam pencere, `Surface(.panel)` ve sistemin pencere gölgesini kullanır. Gölge için kenar payı açılmaz, çünkü pay kartın çevresindeki tıklamaları yutar. Elle çizilen `Elevation`, yakalama katmanı gibi tek pencerede çizilen yüzeyler içindir.

**Durum modeli.** Etkileşim tek bir `InteractionState` değeridir: `normal`, `hover`, `pressed`, `disabled`. Bileşen görünümünü bu duruma göre tablodan okur, ayrı boolean tutmaz.

| Varyant | normal | hover | pressed | disabled |
| --- | --- | --- | --- | --- |
| `primary` | `accentSolid`, `onAccent` | `accentSolidHover`, `onAccent` | hover ve ölçek 0.96 | `bgControl`, `textDisabled` |
| `secondary` | `bgControl`, `textPrimary` | `bgControlHover`, `textPrimary` | `bgControlActive` ve ölçek 0.96 | `bgControl`, `textDisabled` |
| `ghost` | zemin yok, `textSecondary` | `bgControlHover`, `textPrimary` | `bgControlActive` ve ölçek 0.96 | zemin yok, `textDisabled` |
| `danger` | `dangerSolid`, `onDanger` | `dangerSolid`, `onDanger` | ölçek 0.96 | `bgControl`, `textDisabled` |

Editörün araç çubuğu `NSToolbar` öğesi değil, başlık çubuğunun altında duran kendi satırıdır, çünkü macOS 26 her araç çubuğu öğesine kaldırılamayan bir cam kapsül çizer. Ekran görüntüsü üstündeki seçim çerçevesi ve tutamaçlar `selectionStroke` ile `selectionHalo` kullanır, vurgu rengi kullanmaz.

Stok açılır menü (`NSPopUpButton`) ve renk kuyusu (`NSColorWell`) kalır, çünkü sistem menüsü ve renk seçicisi yerel davranıştır. Kaydırıcı dolgusu nötrdür, çünkü vurgu yalnızca seçili durum ve birincil eylem içindir. Editörde görünümün tek birincil eylemi `Copy` düğmesidir.

Seçili `IconButton`: `accentSubtle` zemin, `accentBorder` kenar, `accentText` ikon. Basma geri bildirimi anında çizilir, azaltılmış harekette ölçek uygulanmaz. Klavye odağında `focusRing` halkası çizilir. Bileşenler pencere aktif değilken griye dönmez ve ilk tıklamayı kabul eder, çünkü yakalama katmanı aktif olmayan bir paneldir.

## Ekran kalıpları

**Kırpma.** Vizör karesi gibi çizilir: köşelerde L biçimli köşebentler, kenar ortalarında kısa çubuklar, ince çerçeve. Üçte bir ızgarası yalnızca sürüklerken görünür. Boyut kutunun sol üstünde yazar, sığmazsa dışına çıkar. Oranlar çubukta doğrudan görünür. Kırpma sırasında görünümün birincil eylemi `Apply` olur, `Copy` ikincile döner.

**Yan panel.** Bütün içerik tek sağ kenarda biter. Etiket sütunu 64 noktadır, kontrol kalan genişliği doldurur. Bölümler arasında kenardan kenara ayraç bulunur. Arka plan seçimi tek bir ızgaradır, küçük görseller yalnızca dolguyu gösterir.

## Kurallar

- Bileşen dosyasında ham renk, ham font boyutu veya ham köşe değeri bulunmaz. Bir rol eksikse token eklenir.
- Görünümde tek bir dolu vurgu butonu olur, eşdeğerleri nötr kalır.
- Durum yalnızca renkle anlatılmaz, yanında ikon veya etiket bulunur.
- Kullanıcının çizim paleti (`KadrajCore`) içeriktir ve bu sistemin dışındadır.
- Dışa aktarılan görsele giren değerler token kullanmaz, çünkü görünüm değişince dışa aktarım değişmemelidir.
