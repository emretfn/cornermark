# Kadraj

Kadraj, macOS için kişisel kullanıma yönelik bir ekran görüntüsü uygulamasıdır. Menü çubuğunda çalışır (Dock simgesi yoktur), tamamen yerel çalışır ve Swift Package Manager ile derlenir. macOS 14 veya üstü gerekir.

## Derleme

```sh
scripts/build-app.sh            # debug derleme, build/Kadraj.app
scripts/build-app.sh --release  # release derleme
scripts/build-app.sh --no-sign  # imzalama adımını atlar
```

Betik `swift build` çalıştırır, `build/Kadraj.app` paketini oluşturur (Info.plist, CoreGraphics ile üretilen uygulama simgesi) ve imzalar. Ardından `build/Kadraj.app` dosyasını Uygulamalar klasörüne taşıyıp açın.

### İmzalama neden önemli

macOS, Ekran Kaydı iznini uygulamanın kod imzasına bağlar. Ad-hoc imza her derlemede değiştiği için izin her seferinde sıfırlanır. Betik bu yüzden `security find-identity -v -p codesigning` çıktısındaki ilk "Apple Development" sertifikasını (SHA-1 özetiyle) kullanır. Başka bir sertifika için:

```sh
KADRAJ_SIGN_IDENTITY=<sertifika-özeti> scripts/build-app.sh
```

Sertifika yoksa betik uyarı verip ad-hoc imzaya düşer. Xcode > Settings > Accounts > Manage Certificates bölümünden ücretsiz bir Apple Development sertifikası oluşturabilirsiniz. Hardened runtime, sandbox ve noter onayı kullanılmaz.

## Ekran kaydı izni

1. Kadraj'ı açın ve ilk yakalamayı deneyin. İzin yoksa Kadraj bir açıklama penceresi gösterir.
2. "Open System Settings" düğmesi Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı bölümünü açar.
3. Listede Kadraj'ı açın.
4. Kadraj'tan çıkıp yeniden açın. macOS izni yalnızca yeniden başlatılan uygulamaya uygular.

İzin durumu Ayarlar > Permissions sekmesinde de görünür.

## Kısayollar

Varsayılanlar `Ctrl+Shift+rakam` biçimindedir ve sistem kısayollarıyla çakışmaz. Ayarlar > Shortcuts sekmesinden değiştirilebilir. Kısayol başka bir uygulama tarafından kullanılıyorsa aynı sekmede kırmızı uyarı görünür. Kısayollar Carbon `RegisterEventHotKey` ile kaydedilir, Erişilebilirlik izni gerekmez.

| Kısayol | İşlev |
| --- | --- |
| Ctrl+Shift+1 | Hepsi bir arada (alan, pencere, tam ekran) |
| Ctrl+Shift+2 | Alan yakala |
| Ctrl+Shift+3 | Pencere yakala |
| Ctrl+Shift+4 | Tam ekran yakala |
| Ctrl+Shift+5 | Önceki alanı yeniden yakala |
| Ctrl+Shift+6 | Kaydırmalı yakalama |
| Ctrl+Shift+7 | Metin yakala (OCR) |
| Ctrl+Shift+8 | Zamanlayıcılı yakalama |

## Özellikler

- **Yakalama sonrası eylemler:** Quick Access kartı göster, panoya kopyala, klasöre otomatik kaydet (`Kadraj YYYY-MM-DD at HH.MM.SS.png`), editörde aç. Her yakalama geçmişe de yazılır.
- **Quick Access:** Ekran köşesinde küçük resim kartları. Üzerine gelince Kopyala, Kaydet, Düzenle, Sabitle, OCR, Kapat düğmeleri çıkar. Kart başka bir uygulamaya PNG dosyası olarak sürüklenebilir, kenara doğru iki parmakla kaydırınca kapanır, çift tıklama düzenleyiciyi açar. Otomatik kapanma süresi ayarlanabilir ve imleç kartın üzerindeyken durur. Son kapatılan kart geri getirilebilir, tüm kartlar geçici olarak gizlenebilir. Kartlar odağı çalmaz.
- **Sabitleme (Pin):** Her zaman üstte duran, sürüklenebilen, orantılı yeniden boyutlanan pencere. Kaydırma veya sıkıştırma ile yakınlaştırma, Option+kaydırma ile saydamlık, ok tuşlarıyla 1 nokta (Shift ile 10 nokta) kaydırma. Kilit modu tıklamaları arkadaki pencereye geçirir. Kilidi menü çubuğundaki "Pinned Screenshots" listesinden açarsınız. Escape veya kapat düğmesi pencereyi kaldırır.
- **OCR:** Vision ile cihaz üzerinde metin tanıma (Türkçe dahil, dil otomatik algılanır) ve QR kod okuma. Alan seçilir, metin satır sırası korunarak panoya kopyalanır, QR içeriği de metin olarak kopyalanır.
- **Geçmiş:** Küçük resim ızgarası, tür filtresi, tarih grupları, Quick Access'e geri getirme, editörde açma (kayıtlı düzenleme varsa onu), kopyalama, Finder'da gösterme, silme. Varsayılan 30 günden eski kayıtlar açılışta ve günde bir kez silinir.
- **Düzenleyici:** Ek açıklamalar, bulanıklaştırma, kırpma, arka plan ve dışa aktarma. Kapatınca düzenlemeler geçmişteki kayda yazılır.
- **Ayarlar:** Girişte başlat, yakalama sonrası eylemler, kayıt klasörü, PNG/JPEG, ses, kısayollar, köşe/boyut/otomatik kapanma, pencere gölgesi, zamanlayıcı süresi, saklama süresi, izin durumu.
- **Finder'dan aç:** PNG, JPEG ve HEIC dosyaları "Birlikte aç" ile Kadraj'ın editöründe açılır.
- **URL şeması:** `kadraj://capture-area`, `capture-window`, `capture-fullscreen`, `all-in-one`, `previous-area`, `scrolling`, `ocr`, `timer?seconds=5`, `history`, `settings`, `restore-overlay`, `hide-overlays`, `open?path=/tam/yol/resim.png`. `open` için yol var olan bir resim dosyası olmalıdır. Bilinmeyen yollar yok sayılır ve günlüğe yazılır.

## Olmayan şeyler

- Bulut, hesap, paylaşım bağlantısı yok. Hiçbir şey makineden dışarı çıkmaz.
- Video veya GIF kaydı yok.
- Dağıtım yok: App Store, noter onayı, sandbox ve otomatik güncelleme kullanılmaz. Yalnızca bu makinede derlenip çalıştırılır.

## Geliştirme

```sh
swift build                    # her şeyi derler
swift test                     # KadrajCore testleri
swift run HarnessShell         # kabuk testleri, ekrana hiçbir pencere açmaz
```

`HarnessShell` etkinleştirme politikasını `.prohibited` yapar, pencere sıralamaz, odak almaz. Panoyu, UserDefaults'u ve geçmiş klasörünü geçici/özel nesnelerle değiştirir. Anlık görüntüleri `scratchpad/shell/` altına yazar.
