# Cornermark tasarım sistemi

Cornermark, adını seçim karesinin köşe işaretlerinden alır. Arayüz bir vizör gibi davranır: içerik öndedir, kabuk geri çekilir, renk yalnızca odak anlarında görünür.

Kaynak kod `Sources/CornermarkDesign` içindedir. Kontrast ve tutarlılık denetimleri `swift run HarnessDesign` ile çalışır ve örnek sayfayı aynı komut üretir.

## İlkeler

1. **Kabuk nötr, ekran görüntüsü renkli.** Kullanıcının içeriğiyle yarışan renkli yüzey olmaz. Grafit nötrler arayüzün yüzde 90'ını taşır.
2. **Tek vurgu, tek anlam.** Vurgu rengi yalnızca seçili aracı ve görünümdeki tek birincil eylemi gösterir. Gezinme, örneğin Ayarlar kenar çubuğu, nötr kalır.
3. **Yerel davranış, özel görünüm.** Sistem fontu, klavye odak halkası, azaltılmış hareket, saydamlık ve artırılmış kontrast ayarları korunur.
4. **Sık yapılan iş anında olur.** Kısayolla açılan yakalama katmanı animasyon almaz. Hareket yalnızca seyrek anlara ve basma geri bildirimine aittir.

## Uygulama simgesi

Grafit zemin üzerinde limon rengi bir vizör: dört köşe. Çizgiler `accentSolid` tonundadır, bu yüzden simge arayüzdeki tek vurguyla aynı rengi taşır. Simgede harf yoktur.

`scripts/make-icon.swift` simgeyi her boyut için ayrı çizer. 48 pikselin altında çizgiler kalınlaşır. İnce açık kenar, zeminin koyu duvar kâğıdında kaybolmasını önler. Menü çubuğu simgesi aynı şekli taşıyan `viewfinder` SF Symbol'üdür.

## Katmanlar

| Katman | Örnek | Kim kullanır |
| --- | --- | --- |
| İlkel | `Palette.neutralLight[11]` | Yalnızca `CornermarkDesign` içi, dışarıya kapalıdır (`internal`) |
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

Kod tabanında üç durum gerçekten görünür: kısayol çakışması, eksik izin ve süren kaydın göstergesi için `danger`, etkin izin için `success`, kaydırma uyarısı ve ses vermeyen mikrofon için `warning`. `warning` limon vurgudan en az 15 derece uzak kalmak için turuncuya kaymıştır (h 55).

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
| `bgControl` | n3 | n5 | Kontrol zemini |
| `bgControlHover` | n4 | n6 | Üzerine gelme |
| `bgControlActive` | n5 | n7 | Basılı veya seçili |
| `bgControlThumb` | n1 | n7 | Seçim izinin kabarık başparmağı |
| `bgInverse` | n12 | n12 | Açık kutu gibi nötr, güçlü işaret |
| `bgInverseHover` | n11 | n11 | Üzerine gelme |
| `onInverse` | n1 | n2 | Üzerindeki işaret |
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
| `Size.controlXLarge` | 44 | Büyük Hızlı Erişim kartının düğmeleri |
| `Size.iconSmall`, `icon`, `iconLarge`, `iconXLarge` | 12, 14, 16, 20 | SF Symbol nokta boyutu |

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

Web tarafındaki karşılıklar: token CSS değişkeni, bileşen `NSView` veya `NSButton` alt sınıfı, props `init` parametresi, Storybook ise `swift run HarnessDesign` çıktısıdır. Bileşenler `Sources/CornermarkDesign/Components` içindedir ve yalnızca token kullanır.

| Bileşen | Varyant ve seçenek | Nerede |
| --- | --- | --- |
| `Button` | `primary`, `secondary`, `ghost`, `danger`, `dangerGhost`; `small`, `regular`, `large`; isteğe bağlı ikon | Capture, Done, Cancel, ayar eylemleri |
| `IconButton` | `small`, `regular`, `large`; `isSelected`; `selection: .accent`, `.neutral`, `.inverse` (rayın açık bölümü) veya `.tile` (kapalıyken de karolu anahtar); `slashesGlyph`; `tone: .plain`, `.overlay` (yuvarlak, görüntü üstünde) veya `.round` (yuvarlak, `bgControl`, oynatma) | Araç çubukları, Hızlı Erişim eylemleri, editör rayı, oynatma, kayıt kaynakları |
| `TextInput` | `small`, `regular`; `monospaced` | Boyut alanları, formlar |
| `Surface` | `hud`, `raised`, `floating`, `panel` | Çubuk, kart, panel zemini |
| `Segments` | `tiles`: ayrı karolar, seçili karo vurgulu, simgeli veya yazılı, `selectOne` ya da `momentary`, gruplar arası ayraç; `track`: tek iz ve kayan nötr başparmak (`NSSegmentedControl` alt sınıfı) | Editör araçları (`tiles`); video editörünün her seçim satırı (`track`) |
| `Slider` | `track`: ince iz ve yuvarlak tutamaç, küçük boy; `field`: 28 noktalık dolu alan, değer içinde yazar, ön ayarlar çentiktir; nötr dolgu (`NSSlider` alt sınıfı) | Görüntü editöründe kalınlık, dolgu, köşe (`track`); video editörünün her kaydırıcısı (`field`) |
| `Select` | Alan ve kendi menüsü; seçili öğede sağda onay; öğe görseli (renk örneği) ve ayraç (`NSPopUpButton` alt sınıfı) | Video editöründe Mode, Color, Ratio, Resolution; kayıt panelinde oran |
| `Checkbox` | Açık, kapalı, 16 nokta, açıkken grafit `bgInverse` (`NSButton` alt sınıfı) | Panel ve ayar seçenekleri |
| `SidebarItem` | Simge ve başlık, `isSelected` (nötr `bgControlActive`) | Ayarlar kenar çubuğu |
| `ImageWell` | Görsel, köşe yarıçapı | Hızlı Erişim, Geçmiş |
| `PositionGrid` | Dokuz hücreli konum seçici; her hücre bir radyo düğmesi, seçili hücre `Segments` seçim renklerini taşır | Video editöründe kamera ve tuş rozeti konumu |
| `Separator` | `horizontal`, `vertical` | Gruplar arası çizgi |
| `Badge` | `neutral`, `accent`, `danger`, `warning`, `success`; ikon ve metin birlikte | Durum bildirimi |
| `KeyCaps` | Her tuş birleşimi için bir kapak: `bgControl` zemin, `border` kenar, `Radius.xs`, `label` font (sistem fontu tuş simgelerini kendi boyunda çizer), `textPrimary`; yalnızca okunur | Ayarlar'daki video editörü kısayol listesi |
| `Label` | `DS.Text` stili ve renk rolü | Her metin |

Yüzen pencereler (Hızlı Erişim kartı gibi) saydam pencere, `Surface(.panel)` ve sistemin pencere gölgesini kullanır. Gölge için kenar payı açılmaz, çünkü pay kartın çevresindeki tıklamaları yutar. Elle çizilen `Elevation`, yakalama katmanı gibi tek pencerede çizilen yüzeyler içindir.

**Durum modeli.** Etkileşim tek bir `InteractionState` değeridir: `normal`, `hover`, `pressed`, `disabled`. Bileşen görünümünü bu duruma göre tablodan okur, ayrı boolean tutmaz.

| Varyant | normal | hover | pressed | disabled |
| --- | --- | --- | --- | --- |
| `primary` | `accentSolid`, `onAccent` | `accentSolidHover`, `onAccent` | hover ve ölçek 0.96 | `bgControl`, `textDisabled` |
| `secondary` | `bgControl`, `textPrimary` | `bgControlHover`, `textPrimary` | `bgControlActive` ve ölçek 0.96 | `bgControl`, `textDisabled` |
| `ghost` | zemin yok, `textSecondary` | `bgControlHover`, `textPrimary` | `bgControlActive` ve ölçek 0.96 | zemin yok, `textDisabled` |
| `danger` | `dangerSolid`, `onDanger` | `dangerSolid`, `onDanger` | ölçek 0.96 | `bgControl`, `textDisabled` |
| `dangerGhost` | zemin yok, `dangerText` | `dangerSubtle`, `dangerText` | `dangerSubtle` ve ölçek 0.96 | zemin yok, `textDisabled` |

Editörün araç çubuğu `NSToolbar` öğesi değil, başlık çubuğunun altında duran kendi satırıdır, çünkü macOS 26 her araç çubuğu öğesine kaldırılamayan bir cam kapsül çizer. Ekran görüntüsü üstündeki seçim çerçevesi ve tutamaçlar `selectionStroke` ile `selectionHalo` kullanır, vurgu rengi kullanmaz.

Video editöründe ve kayıt panelinde seçim `Select` ile yapılır, sistem menüsüyle değil. Sistem menüsü kabuğun tokenlarını taşımaz: koyu kayıt panelinde bile açık açılabilir, seçili öğeyi solda bir işaretle gösterir ve tetikleyicinin üstüne biner, böylece panelin geri kalanıyla aynı dili konuşmaz. `Select`, `NSPopUpButton` alt sınıfı olarak kalır; öğeler, etiketler, hedef/eylem ve VoiceOver'ın değerli açılır düğme rolü değişmez, yalnızca tetikleyiciyi kendisi çizer ve sistem menüsü yerine kendi menüsünü açar. Ayarlar penceresi tercih bölmesi olduğu için stok açılır menüyü, renk kuyusu (`NSColorWell`) da sistem renk seçicisini korur. Kaydırıcı dolgusu nötrdür, çünkü vurgu yalnızca seçili durum ve birincil eylem içindir. Editörde görünümün tek birincil eylemi `Copy` düğmesidir.

**Seçim alanı.** `Select` tetikleyicisi 28 noktalık `bgControl` alandır: solda seçili öğenin `label` fontuyla adı ve varsa renk örneği, sağda `chevron.down`. Üzerine gelince `bgControlHover`, menü açıkken `bgControlActive` olur. Menü alanın altında, sol kenarı hizalı açılır ve en az alan kadar geniştir: opak `bgRaised`, `separator` kenar, `Radius.lg`, 6 noktalık iç boşluk ve sistemin pencere gölgesi, menü çubuğu paneliyle aynı. Satırlar 28 noktadır, vurgulanan satır `bgControl` ve `Radius.sm` alır, seçili öğe `bodyStrong` yazar ve sağda `textPrimary` onay taşır; ayraçlar ince `separator` çizgisidir. Ekranın altında yer yoksa menü alanın üstünde açılır ve her zaman görünür ekranın içinde, tam noktalarda durur. Menü tetikleyicinin görünümünü alır, bu yüzden her zaman koyu kayıt panelinde koyu açılır, ve katmanın üstünde kalır. Menü pencere olarak anahtar olmaz; açıkken her tuş ve tıklama önce ona gelir. Space, Return ya da bir ok tuşu menüyü açar (kayıt panelinde Return başlatma tuşu olarak kalır); oklar, Home ve End vurguyu taşır, harfler o harfle başlayan öğeye atlar, Return ya da Space seçer, Esc ve Tab kapatır. Menünün dışına tıklamak kapatır, alana tıklamak yalnızca kapatır. Basılı tutup bir öğenin üstünde bırakmak da seçer. Video editöründe Space her yerde oynatır, ama odaktaki bir `Select` Space'i kendisi alır, tıpkı yazı alanı gibi. VoiceOver alanı değeriyle bir açılır düğme olarak okur ve açıkken genişlemiş der; menü öğeleri menü öğesi olarak okunur. Fareyle açılış 0.20 sn `easeOut` ile opaklık ve alanın kenarından yüzde 96'dan büyümedir, azaltılmış harekette yalnızca opaklık; klavye ve VoiceOver menüyü animasyonsuz açar, kapanış her zaman anındadır, çünkü seçim sık yapılır.

**Seçim izi.** `track` bütün seçenekleri 28 noktalık tek bir `bgControl` izde, `Radius.md` ile taşır. Seçili seçeneğin arkasında 2 nokta içeride `bgControlThumb` bir başparmak durur: `Radius.sm`, `Elevation.raised` gölgesi; seçili yazı `textPrimary`, diğerleri `textSecondary`, üzerine gelinen `textPrimary`. Vurgu kullanılmaz, çünkü vurgu araca ve Export'a aittir. Fareyle seçilince başparmak eski yerinden yenisine 0.20 sn `easeOut` ile kayar ve genişliği yeni seçeneğe uyar; tuşla, kodla ya da azaltılmış harekette anında yer değiştirir. Basılan seçeneğin yazısı yüzde 96'ya iner. Kapalı bir izde başparmak gölgesiz `bgControlActive` olarak kalır, böylece kapalıyken de neyin seçildiği okunur.

**Alan kaydırıcı.** `field` bir düğme kadar yüksektir: `bgControl` zemin, değere kadar `bgControlActive` dolgu, dolgunun ucunda 2 noktalık bir işaret ve sağ uçta `readout` fontuyla değer. Alanın her yerine basmak değeri oraya getirir ve sürükleme oradan sürer, çünkü nişan alınacak bir tutamaç yoktur. Ön ayarlar alanın altında kısa `borderStrong` çentiklerdir ve sürükleme aralığın yüzde 2'si kadar yakından geçince çentiğe oturur; adımlı kaydırıcı (Quality) yalnızca adımlarına iner. Değer yerinden oynamaz; dolgunun işareti değere ulaşınca metnin üstünde ve altında kısa çizgiler bırakır, böylece sayı her doluluktta temiz okunur. İşaret dururken `textSecondary`, üzerine gelince, sürüklerken ve odakta `textPrimary` olur ve basılıyken uzar. Ok tuşları aralığın yirmide birini ya da bir adımı, Shift beş katını kaydırır; Home ve End uçlara gider. VoiceOver alanı yazdığı değerle bir kaydırıcı olarak okur. Sürükleme sık yapılır, bu yüzden alan animasyon almaz.

Seçili `IconButton`: `accentSubtle` zemin, `accentBorder` kenar, `accentText` ikon. Basma geri bildirimi anında çizilir, azaltılmış harekette ölçek uygulanmaz. Klavye odağında `focusRing` halkası çizilir. Bileşenler pencere aktif değilken griye dönmez ve ilk tıklamayı kabul eder, çünkü yakalama katmanı aktif olmayan bir paneldir.

## Ekran kalıpları

**Kırpma.** Vizör karesi gibi çizilir: köşelerde L biçimli köşebentler, kenar ortalarında kısa çubuklar, ince çerçeve. Üçte bir ızgarası yalnızca sürüklerken görünür. Boyut kutunun sol üstünde yazar, sığmazsa dışına çıkar. Oranlar çubukta doğrudan görünür. Kırpma sırasında görünümün birincil eylemi `Apply` olur, `Copy` ikincile döner.

**Yan panel.** Bütün içerik tek sağ kenarda biter. Panel sıkıdır: kontrol satırları 28 nokta, satır araları 8 noktadır; gruplar arası en az iki katıdır: ayraçlı gruplarda ayracın iki yanında 12, ayraçsızda 16 nokta ve açıklamalar tek satır `caption` olur. Açıklamanın tamamı kontrolün ipucunda ve VoiceOver yardımında durur. Etiket sütunu 64 noktadır, kontrol kalan genişliği doldurur. Bölümler arasında kenardan kenara ayraç bulunur. Arka plan seçimi tek bir ızgaradır, küçük görseller yalnızca dolguyu gösterir.

**Ayarlar.** Sistem sekmeleri yerine solda kenar çubuğu, sağda kaydırılabilir içerik. Ayarlar gruplu kartlardadır: başlık solda, kontrol sağda, satırlar arasında ayraç. Açıklamalar başlığın altında küçük yazılır.

**Geçmiş.** Üstte filtre, altta eylem çubuğu. Her görsel aynı boyda bir kuyuda durur, böylece farklı oranlar düzensiz görünmez. Seçim yalnızca kuyunun çevresinde vurgu halkasıdır, kartı doldurmaz.

**Hızlı Erişim düğmeleri.** Kartla birlikte büyür: küçük kartta 28, ortada 36, büyükte 44. Köşe düğmeleri bir adım küçüktür.

**Görüntü kuyusu.** Oranı değişken görseller `ImageWell` içinde çizilir: `bgSunken` zemin, `Radius.md`, sığdırılmış görsel, `imageOutline`. Hızlı Erişim ve Geçmiş bunu kullanır.

**Kayıt paneli.** Kayıt, yakalama katmanında alan seçimiyle başlar. Araç çubuğunun yerini dört satırlı bir `hud` paneli alır ve seçim sığdığı sürece panel seçimin ortasında durur, sığmazsa araç çubuğu gibi seçimin altına geçer. Üst satır seçenekler düğmesiyle (`slider.horizontal.3`) başlar. Düğme Recording bölmesinin sık değişen ayarlarını sistem menüsünde açar: başlıklar altında Quality, Frame Rate ve Countdown, ayraçtan sonra Show Cursor, Dim Outside the Area ve iki dışarıda bırakma seçeneği. Sistem menüsü seçilir, çünkü katmanın odağını bozmadan açılıp kapanır ve yerel davranıştır; menü düğmenin sağ tık menüsüdür de. Ardından hedef (Area, Window, Fullscreen), boyut alanları ve oran menüsü gelir. Orta satır kaydın resim dışında neyi alacağını seçen beş `IconButton` anahtarıdır: Microphone, System audio, Camera, Click highlights ve Keystrokes. Anahtarlar Audio, Camera ve Recording ayar bölmeleriyle aynı tercihleri yazar; tıklama ve tuş ayrı ayarlardır, ama ikisi de Input Monitoring'i aynı tek istekle sorar. Anahtar iki durumda da karosunu korur, böylece kapalısı başka bir kontrol gibi görünmez. Kapalı anahtar düz `bgControl` karoda `textSecondary` eğik çizgili simge taşır; açık anahtar bir adım açık `bgControlActive` karo, `borderStrong` kenar, `textPrimary` dolu simge ve sağ alt köşeden taşan `bgInverse` dairede `onInverse` küçük bir onay taşır. Simge karonun ortasında kalır. Klavyenin eğik çizgili simgesi olmadığı için anahtar çizgiyi dolgusuz `keyboard` simgesinin üstüne kendisi çizer ve sistemin eğik çizgili simgeleri gibi karonun rengiyle oyar. Böylece durum yalnızca renkle anlatılmaz ve vurgu hedefe ve tek birincil eyleme kalır. Panelin her kontrolünün ipucu vardır; anahtarın ipucu ne yaptığını ve durumunu yazar, örneğin Show keystrokes (on). VoiceOver her birini adı ve durumuyla bir onay kutusu olarak okur, yardımı ne yaptığını yazar. Anahtar ancak sonraki kayıt o kaynağı gerçekten alacaksa açık görünür: ayarda istenmiş ve izin verilmiş. macOS henüz sormadıysa anahtarı açmak izni o anda bir kez ister. Mikrofon ve kamera sorusu beklerken katman ekrandan çekilir, çünkü ekran koruyucu düzeyindeki katman sistemin sorusunu örterdi; yanıt gelince katman aynı seçimle ve klavyeyle geri gelir. Bekleyen anahtar tıklama almaz, ipucu ve VoiceOver yardımı izin beklendiğini söyler ve not Waiting for permission. Answer the macOS prompt to go on. yazar. Input Monitoring için macOS yanıt göndermez ve izin ancak Cornermark yeniden açılınca geçerli olur, bu yüzden katman soru gelmeden önce kapanır. Reddedilen kaynak kapalı kalır ve ayara da kapalı yazılır, anahtarların sağındaki en çok iki satırlık `caption` notu izni System Settings'te nereden açacağını söyler. Engel notu `textPrimary`, ipucu (Record GIF ses almaz) `textSecondary` kullanır. Anahtar ve not animasyon almaz, çünkü panel sık açılır. Başlatma düğmeleri iki satırdadır. Hemen paylaşılan iki sonuç, tek `primary` eylem Record MP4 ve nötr Record GIF, bir satırı paylaşır. İnce bir ayraçtan sonra nötr Record Project kendi satırında durur, çünkü sonucu düzenlenen bir projedir; satırın sonunda yardım düğmesi (`questionmark.circle`) vardır. Yardım katmanın üstünde küçük bir pencere açar: başlık, proje kaydını anlatan iki cümle, editörün kendi parçalarından çizilmiş bir resim (zoom çerçevesi, imleç, tıklama halkası, kamera balonu, zoom, klip ve ses şeritleri; gerçek ekran görüntüsü yoktur) ve tek `primary` Close düğmesi. Pencere görünüme uyar, açıkken klavyeyi alır, Return ve Escape kapatır ve klavye katmana geri döner. Adlar sonucu söyler: hemen paylaşılan bir MP4, editörde değişen ve dışa aktarılan bir proje, bir GIF. Her düğmenin ipucu ve VoiceOver yardımı ne kaydettiğini tek cümleyle yazar. Her düğme başlığının genişliğini korur, artan yer eşit paylaşılır, böylece panel orta boy bir seçimin içine sığar. Her düğme kısayolunu başlıktan sonra `readout` fontuyla yazar: Return, Shift-Return ve Option-Return. Fullscreen, ekranı dolduran bir seçimdir ve bir başlatma düğmesi bekler. Window bir tıklamayla seçilir ve beklerken boyut alanları salt okunurdur. Hedef yokken başlatma düğmeleri devre dışıdır. Seçim, ekran ve pencere kenarlarına 8 noktadan yapışır, Command yapışmayı kapatır. Option seçimi merkezden büyütür. Panel boyutu gösterdiği için kayıtta seçim rozeti çizilmez.

**GIF.** Record GIF, video gibi çekilir ve aynı kontrolleri kullanır. Kayıt bitince video, imleç resmin içinde, saniyede 15 kare ve en uzun kenarı en çok 960 piksel olan, sonsuz dönen bir GIF'e çevrilir. Duraklatılan kısım GIF'e girmez. Hızlı Erişim kartı ve Geçmiş, GIF'i `photo.stack.fill` simgesi ve "GIF" sözcüğüyle gösterir, Convert to GIF düğmesi `photo.stack` taşır, yalnızca renge ya da süreye dayanmaz. Bitmiş bir Record MP4 kaydı, kartındaki Convert to GIF düğmesiyle ya da Geçmiş'in eylem çubuğundaki Convert to GIF ile GIF'e çevrilir. GIF videonun yanına aynı adla yazılır, video değişmez. Record Project projesinde bu düğme yoktur, çünkü projenin imleci videonun resminde değildir.

**Kayıt kontrolleri.** Kayıt sürerken tek satırlık bir çubuk durur: geçen süreyi taşıyan durdurma düğmesi, mikrofon kaydediliyorsa mikrofon yuvası, ayraç, Pause veya Resume, Restart, Delete ve sürükleme tutamacı. Mikrofon yuvası `mic.fill` simgesi ve ince bir seviye çubuğu taşır. Çubuk desibel ölçeklidir (-60 dBFS ile tam ölçek arası), izi `borderStrong`, dolgusu `bgInverse`'tir, çünkü seviye bir okumadır, seçim değildir. Anında yükselir, 0,6 saniyede iner. Mikrofon 3 saniye ses vermezse yuva aynı genişlikte `warning` tonlu `Badge`'e döner: `mic.slash.fill` ve "No sound". Böylece düğmeler kıpırdamaz, durum yalnızca renkle anlatılmaz ve VoiceOver bunu bir kez duyurur. Klavyeyle ulaşılan menü panelinin kayıt bölümü aynı anda ne yapılacağını yazar. Çubuk her zaman koyu `bgHud` yüzeydir, köşesi `Radius.lg`, iç boşluğu 4'tür. Durdurma düğmesi `ghost` bir düğmedir ve işaretiyle süresi durumu birlikte anlatır: kayıtta `dangerText` durdurma işareti (`stop.circle`, tek renkte dolu daire düz bir kayıt noktası gibi okunduğu için içi boş) ve `textPrimary` süre, duraklatınca `textSecondary` durdurma işareti, sönük süre ve Pause'un yerinde Resume, geri sayımda `xmark.circle` ve Cancel. Süreye tıklamak kaydı durdurur; ipucu Stop recording, VoiceOver bunu süreyle birlikte söyler. `dangerSolid` değil `dangerText` kullanılır, çünkü çubuk her içeriğin üstünde 3:1'i korumalıdır. Süre tablo rakamlıdır ve bir saatin altındaki her değere yetecek genişlikte durur, böylece düğmeler kıpırdamaz. Restart çekimi atar, bu yüzden ilk tıklamada yerini `dangerGhost` Discard take düğmesine bırakır ve 3 saniye içinde ikinci tıklama ister. Delete (`trash`) kaydı bitirir ve hiçbir dosya ya da Geçmiş kaydı bırakmaz; o da ilk tıklamada yerini `dangerGhost` Delete recording düğmesine bırakır ve 3 saniye içinde ikinci tıklama ister. Aynı anda tek onay bekler. Her kontrolün ipucu vardır. Çubuk alanın altında ortalanır, yer yoksa üstüne, o da yoksa alanın alt kenarının içine geçer ve görünür çerçevenin dışına taşmaz. Arka planından ve sondaki altı noktalı tutamaçtan sürüklenir, bırakıldığı yer uygulama açık kaldıkça sonraki kayıtta kullanılır. Odak almaz, uygulamayı öne çıkarmaz ve `sharingType` kapalıdır, bu yüzden videoya ve hiçbir ekran görüntüsüne girmez. Klavyeyle Pause, Resume, Discard and Restart ve Delete Recording menü panelindedir.

Çubuk, geri sayım kartı ve karartma 0.20 sn `easeOut` ile girer: opaklık ve yüzde 96'dan büyüme, azaltılmış harekette yalnızca opaklık. Çıkış 0.15 sn yalnızca opaklıktır. Kayıt noktası yanıp sönmez. Geri sayım yakalama zamanlayıcısının kartını kullanır ve alanın ortasında durur. Kayıt başlarken ve biterken ses çalınmaz: ileride sistem sesi kaydedildiğinde bir başlama sesi videoya girerdi. Geri bildirim görseldir: geri sayım, çubuğun girişi ve menü çubuğundaki simgenin kırmızı kayıt noktasına dönmesi.

Alan kaydında alanın dışı `bgScrim` ile kararır ve alan `selectionStroke` ile `selectionHalo` çizgisiyle çevrilir. Çizgi alanın dışındadır, kaydedilen piksele değmez. Karartma tıklama almaz, Dock'un üstünde ve menü çubuğunun altında durur, böylece menü çubuğundaki süre okunur kalır. Menü çubuğu simgesi kayıt sürerken kayıt noktasına ve süreye, duraklatınca pause simgesine döner.

**Kamera balonu.** Kamera açıksa kayıt sürerken kendi penceresinde, alanın içinde ve kameranın videodaki yerinde durur: daire, kare veya dikdörtgen (4:3), üç boy (alanın kısa kenarının yüzde 22, 30 ve 42'si), dört köşe, köşeden kısa kenarın yüzde 4'ü kadar içeride. Varsayılan orta boy, sol alt köşede, aynalanmış dairedir. Kare ve dikdörtgenin köşesi yüksekliğin yüzde 16'sıdır. Pencere `sharingType` kapalıdır, kontrol çubuğu gibi hiçbir kayda ve ekran görüntüsüne girmez: Record MP4 ve Record GIF kamerayı kaydedicinin kendisi resme çizer, Record Project ayrı `camera.mp4` yazar, dışa aktarma ve önizleme onu projeden aynı çizerle çizer. Balona tıklamak kamerayı alanın tamamına büyütür, ikinci tıklama geri getirir; ekranda 0.30 sn `easeInOut`, videoda 0.30 sn smootherstep, azaltılmış harekette ekranda anında. Sürüklenen balon bırakıldığı yere en yakın köşeye oturur ve sonraki kayıt o köşede başlar. Üzerine gelince tek `bgHud` rozet tıklamanın ne yapacağını simgeyle söyler, video temiz kalır. Balon odak almaz, bu yüzden klavyeyle büyütme menü panelinde Fill with Camera satırıdır. Balonun ince kenarı ve gölgesi videoya da girdiği için token değil sabit değerdir. Balondaki görüntü içeriktir, token kullanmaz. Kayıt dört köşeden birinde başlar; video editöründe balon 3×3 ızgaranın dokuz hücresinden birine taşınır ve kenara değdiği yerde aynı yüzde 4'lük payı korur.

**Ses.** Ayarlar'daki Audio bölmesi mikrofonu, aygıtını, seviye çubuğunu, mono seçeneğini ve sistem sesini taşır. Mikrofon erişimi Input Monitoring satırıyla aynı kalıptadır: izin verildiyse `success` nokta ve "Allowed", sorulmadıysa ve mikrofon açıksa tek `primary` eylem Request Access, reddedildiyse Open System Settings. Seviye çubuğu yalnızca bölme açıkken, mikrofon açık ve izinliyken dinler. Bağlı olmayan seçili aygıt seçili kalır ve satır kaydın varsayılan girişi kullandığını yazar.

**Video editörü.** Solda simge rayı ve seçili bölümün paneli, ortada önizleme ve altında oynatma satırı, en altta pencere genişliğinde zaman çizelgesi durur: cetvel, zoom şeridi ve küçük resimli klip şeridi. Oynatma satırının solunda süre `readout` fontuyla yazar; başa git, 36 noktalık yuvarlak `bgControl` oynat düğmesi ve sona git önizlemenin tam ortasında, oynattığı resmin altında durur; sağda klip düzenlemeleri, ince bir ayraçtan sonra ses ve tam ekran. Raydaki açık bölüm ters grafit bir karodur: `bgInverse` zemin, `onInverse` simge, üzerine gelince `bgInverseHover`. Bir bakışta okunur ve yine nötrdür, çünkü ray gezinmedir ve vurgu almaz. Zoom şeridi 40 noktadır. Her zoom `Radius.sm` bir bloktur ve içinde zoomun profili çizilir: içeri hareket, bekleme ve dışarı hareket. Hareketler projenin `zoomAnimation` süresi kadar, zaman çizelgesinin ölçeğinde ve dışa aktarmanın smootherstep eğrisiyle çizilir, böylece blok kameranın ne zaman ve ne kadar sürede yaklaştığını gösterir; çizgi seçiliyken `accentText`, değilken `textSecondary`'dir. Seviye `readout`, mod (Follow Cursor, Manual) `caption` ile içeri hareketin bittiği yerden başlar ve dışarı hareketten önce biter; sığmayan önce mod, sonra simge düşer. Uçlarda 3 × 16 noktalık tutamaçlar kenarın tutulabildiğini gösterir. Zoom şeridi boşken genişliği boyunca kesik çizgili bir çerçeve ve ortasında Click or drag to add a zoom yazar; üzerine gelince bu satır zoomun gideceği yeri gösteren hayalete döner. Oynatma başı güçlü nötr `bgInverse` çizgidir, çünkü bir anı gösterir, seçim değildir. Önizlemedeki görüntü ve imleç içeriktir, token kullanmaz, böylece dışa aktarılanla aynı kalır. İmleç paneli boyutu kaydırıcıyla, stili (White, Black, Dot) ve hareketi (Natural, Smooth) `Segments` ile seçer; gizleme seçenekleri bir ayraçla ayrılır. Show cursor kapalıyken diğer ayarlar devre dışı kalır ama seçili stil ve hareket nötr `bgControlActive` ile okunur kalır. İmlecin solup geri gelmesi videonun içeriğidir, arayüz hareketi değildir: dinlenince 0.30 sn, yazınca 0.15 sn içinde söner ve kıpırdamadan 0.15 sn önce tamamen geri gelir. Boşluk tuşu her yerde oynatır ve durdurur, animasyon almaz. Sesi olmayan kayıtta hoparlör devre dışıdır ve nedenini söyler, seviye kaydırıcısı görünmez. Tam ekran önizleme koyu yüzeydir: pencere `.darkAqua` alır, yalnızca görüntü ve oynatma satırı kalır. Background bölümü görüntü düzenleyicisinin döşeme ızgarasını kullanır: None, iki satır gradyan (Show more ile yirmisi), Add image ile duvar kâğıtları ve düz renkler. Döşemeler önizlemenin ve dışa aktarmanın ressamıyla çizilir. Padding, Shadow ve Corners panelin altında sabit durur, döşemeler kayar; arka plan yokken kaydırıcılar kapalıdır ve nedeni yazar. Camera, Keystrokes ve Audio bölümleri aynı panel kalıbını kullanır: 64 noktalık etiket sütunu, sağ kenarda biten seçim satırları (yazılı `Segments` her karoya metin genişliği artı kalan yerden eşit pay verir) ve konum için 3×3 `PositionGrid`. Anahtarı kapalı bölümün ayarları griye döner, seçili seçenek gri karosunu korur, böylece kapalıyken de ne seçildiği okunur. Kaydın içermediği bölüm, kayıttan önce hangi ayarın açılacağını söyleyen bir not gösterir. Ses seviyesi doğrusal kazançtır ve yüzde olarak `readout` fontuyla yazar. Önizleme projenin sesini yalnızca ekranda duran editörde çalar; harness ve betikli örnek sessizdir. Kaydedilmemiş bir düzenleme varsa Export'un solunda `label` fontu ve `textSecondary` ile "Edited" yazar, kapatma düğmesinde de nokta görünür; Command-S'ten sonra "Saved" yazar. Durum sözcükle anlatılır, renk ya da hareket kullanılmaz, çünkü kaydetme kısayolla sık yapılır. Kapatmak düzenlemeleri sormadan kaydeder; yazılamazsa pencere açık kalır ve HUD Save As'i önerir. Dosyadan açılan videonun imleç, tuş, tıklama ve kamera izi yoktur: Cursor, Clicks, Camera ve Keystrokes bölümleri ayar yerine nedenini yazar; zoomlar yine çalışır. Videonun kendi sesi Audio bölümünde bir notla anılır ve dışa aktarmanın ilk karışımı olarak kalır; mikrofon ile sistem sesi satırları yalnızca kaydın taşıdığı parçaları gösterir. Aynı sabit grubun başında Ratio menüsü durur: Auto, ayraçla geniş ve kare oranlar (1:1, 5:4, 4:3, 3:2, 16:9), dikey oranlar (4:5, 3:4, 9:16) ve Custom. Custom, oranı veren iki sayı alanı açar; değer Return ya da alandan çıkınca bir geri alma adımı olur, sınırı aşan sayı 1:4 ile 4:1 arasına çekilir ve alan kullanılan değeri gösterir. Oran videoyu kayıt ve dolgusunun çevresinde büyütür, kaydı ortalar, hiçbir yerini kesmez; dışa aktarma boyutları kısa kenardan oranla hesaplanır, böylece 9:16'da 1080, 1080 × 1920 olur. Arka plan yokken oranın kalan alanı siyah şeritlerdir, çünkü video saydam olamaz; şeritler içeriktir, görünüme uymaz ve panel bunu yazar. Oran değişimi animasyon almaz, sık yapılan bir düzenlemedir. Clicks bölümü basma efektini (Press effect) ve halkayı (Ripple) iki onay kutusuyla açar; halkanın rengi açılır menüde halkanın kendi mürekkebiyle, boyutu, stili ve hareketi (Grow, Still) `Segments` ile seçilir. Halka kaydın ayarıyla başlar, imleç gizliyken de tıklamayı gösterir ve çizilen imlecin tıklama anındaki yerinde durur. Basma ve halka da videonun içeriğidir: imleç 0.05 sn'de yüzde 80'e iner ve 0.18 sn'de geri büyür, halka 0.4 sn yaşar. Zoom kırpması imleci, halkaları ve tuş rozetini birlikte taşır, kamera balonu çerçevede sabit kalır; halka ve rozet önizlemede ayrı katmanlarda, dışa aktarmada bir kez çizilir. Manual zoomun paneli Mode menüsünün altında kaydın zoomun ortasındaki karesini küçük bir resim olarak gösterir: zoomun gördüğü yer `selectionStroke` ve `selectionHalo` çizgili bir çerçevedir, dışı `bgScrim` ile kararır, çünkü çerçeve her kayıtta okunmalıdır. Çerçeve sürüklenir, resmin başka bir yerine tıklamak çerçevenin ortasını oraya taşır, odaklı resimde ok tuşları resmin yüzde 1'i, Shift ile yüzde 10'u kadar kaydırır ve çerçeve resmin kenarında durur. Bir sürükleme ya da art arda ok basışları tek geri alma adımıdır. Çerçeve doğrudan işlemdir, animasyon almaz. Zoom panelindeki Animation Settings düğmesi (zoomun sağ tık menüsünde de vardır) ayar sütununun üstünde, düğmeyle aynı hizada bir `floating` yüzey açar, böylece önizleme bütün kalır. Ayarlar projenin bütün zoomlarına uygulanır, çünkü bir zoomdan ötekine geçiş ve bölünen bir zoomun sürüklenmesi iki tarafın aynı hareketi paylaşmasına dayanır: Duration her içeri ve dışarı hareketin süresidir (0,30 ile 1,50 sn, varsayılan 0,78), Follow Cursor için Hold area imlecin kamerayı oynatmadan dolaştığı görüş payıdır (yüzde 0 ile 80, varsayılan 50) ve Catch-up kameranın imlece yüzde 95 yetişme süresidir (0,30 ile 1,50 sn, varsayılan 0,68). Değerler `readout` fontuyla yazar; Reset to Defaults bir değer değişince açılır; Done ve Esc kapatır, odak düğmeye döner. Yüzey 0.20 sn `easeOut` ile düğmenin köşesinden yüzde 96'dan büyüyerek girer, azaltılmış harekette yalnızca opaklık; çıkış 0.15 sn opaklıktır. Export paneli açılınca kapanır, böylece aynı anda tek yüzey yüzer. Bu değerler videonun içeriğidir, token kullanmaz.

**Video editörü kısayolları.** Editörün her tuşu tek bir tablodadır (`EditorShortcuts`): editör penceresi, odaktaki zaman çizelgesi, zoom şeridi ve manuel zoomun hedef çerçevesi tuşu bu tablodan okur, ana menünün Save, Save As, Export, Export Current Frame as Image, Undo, Redo ve Open Video öğeleri de tuşlarını oradan alır. Ayarlar > Shortcuts, her yerde çalışan düzenlenebilir kısayolların altında bu tabloyu salt okunur dört grup olarak listeler: oynatma, klipler, zoomlar, proje ve dışa aktarma. Her satır komutun adını, gerekiyorsa nerede çalıştığını ve Shift'in ne eklediğini `caption` ile, tuşları sağda `KeyCaps` ile gösterir. Liste kayıt düğmesi değildir, çünkü bu tuşlar yalnızca editör öndeyken çalışır ve değiştirilmez; tuş kapakları kaydedicinin vurgulu kenarını taşımaz, böylece düzenlenebilir olanla karışmaz. Tuşlar animasyon almaz.

**Dışa aktarma.** Editörün tek birincil eylemi Export'tur ve başlık çubuğunun altındaki satırın sağ ucunda durur. Basınca altından pencere içinde bir `floating` yüzey açılır: Resolution menüsü (özgün boyut ve ondan küçük standart boyutlar, kısa kenarla adlandırılır, büyütme yok), üç adımlı Quality kaydırıcısı (Low, Medium, High), tahmini dosya boyutu ve yazılacak dosyanın boyutu, kare hızı, süresi ve kodeki. Panel açıkken birincil eylem panelin Export düğmesidir, başlıktaki Export ikincile döner, böylece görünümde yine tek dolu vurgu düğmesi kalır. Return dışa aktarır, Esc kapatır, odak panele girer ve kapanınca Export'a döner. Tahmin, kaydın kendi dosya boyutundan gelir ve seçilen bit hızıyla sınırlanır, çünkü durgun bir ekran her kalitede az bit ister. Dışa aktarırken aynı panel "Exporting video" başlığı, ilerleme çubuğu, yüzde ve Cancel gösterir. Çubuk nötrdür: iz `bgControlActive`, dolgu `bgInverse`, çünkü ilerleme bir durumdur, seçim ya da eylem değildir. Panel 0.20 sn `easeOut` ile opaklık ve düğmenin köşesinden yüzde 96'dan büyüyerek girer, azaltılmış harekette yalnızca opaklık; çıkış 0.15 sn opaklıktır. Bitince panel kapanır ve dışa aktarılan video Hızlı Erişim'de Copy, Save, Play ve Close ile, süresi ve dosya boyutuyla görünür. Dosya Save'e kadar Geçmiş'in kendi klasöründe durur ve kayıt silinince onunla gider.

**Kareyi dışa aktarma.** File > Export Current Frame as Image (Shift-Command-E) oynatma başındaki kareyi dışa aktarmanın çizeriyle (`ExportFrameRenderer`) ve kaynağı dışa aktarmanın okuduğu gibi okuyarak çizer: arka plan, zoom, imleç, halkalar, rozet ve kamera aynıdır, kare keskindir, çünkü durağan resmin deklanşörü yoktur. Boyut, dışa aktarmanın özgün boyutudur, yani tuvalin kaydın piksel yoğunluğundaki boyutu. Sonuç bir ekran görüntüsü gibi davranır: PNG olarak Geçmiş'e girer, sonra After capture ayarına göre Hızlı Erişim kartı, pano ya da kayıt klasörü. Panel ya da ilerleme göstermez; geri bildirim kartın kendisidir. Hiçbir şey yüklenmez, kare Mac'te kalır.

**Menü paneli.** Menü çubuğu simgesi sistem menüsünü değil, 300 noktalık kendi panelini açar. Yakalama kipleri ve Kayıt 3×3 nötr karodur: simge, kısa ad ve `readout` fontuyla kısayol. Karolar ve son yakalamaların küçük görselleri aynı 6 noktalık aralıkla aynı sütunlara oturur. Kayıt sürerken Kayıt karosu aynı kısayolla Stop olur. Kullanıcı bir kısayolu kapattıysa karoda yazı olmaz. Panelin tek vurgusu güncelleme satırıdır: `accentWash` zemin ve tek `primary` Update düğmesi. Güncelleme yokken panelde vurgu yoktur. Son yakalamalar en çok üç küçük görseldir, en yenisi başta, geçmiş boşsa bölüm hiç yer almaz. Satırın üzerine gelme dolgusu `bgControl` ve `Radius.sm` kullanır. Panelin köşesi `Radius.lg`, kenar boşluğu 6'dır, bu yüzden satır köşesi panel köşesiyle eşmerkezlidir. Zemin opak `bgRaised`, kenarı `separator` çizgisidir, gölgeyi pencere verir. Malzeme kullanılmadığı için artırılmış kontrast ve azaltılmış saydamlık ek iş istemez. Güncelleme satırının metni `textPrimary` kullanır, çünkü `textSecondary` koyu `accentWash` üzerinde 4,5:1'in altında kalır.

Panel sık açılır, bu yüzden açılış ve kapanışında animasyon yoktur. Klavyeyi alır ama uygulamayı öne çıkarmaz, öndeki uygulama odağını korur. Ok tuşları, Return, Space ve Escape çalışır. Odak halkası ilk ok tuşuna kadar görünmez, böylece fare kullanan biri halka görmez. Bir eylem seçilince panel önce kapanır, eylem sonraki turda çalışır ve panel `sharingType` kapalı olduğu için hiçbir ekran görüntüsüne girmez.

## Kurallar

- Bileşen dosyasında ham renk, ham font boyutu veya ham köşe değeri bulunmaz. Bir rol eksikse token eklenir.
- Görünümde tek bir dolu vurgu butonu olur, eşdeğerleri nötr kalır.
- Durum yalnızca renkle anlatılmaz, yanında ikon veya etiket bulunur.
- Kullanıcının çizim paleti (`CornermarkCore`) içeriktir ve bu sistemin dışındadır.
- Dışa aktarılan görsele giren değerler token kullanmaz, çünkü görünüm değişince dışa aktarım değişmemelidir.
