<div align="center">
  <h1>Mole</h1>
  <p><em>Mac'inizi derinlemesine temizleyin ve optimize edin.</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+GclQS9ZnxyI2ODQ1"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>Türkçe</strong>
</p>

<p align="center">
  <img src="https://gw.alipayobjects.com/zos/k/ro/ZzF8e8.png" alt="Mole - 95.50GB freed" width="1000" />
</p>

> **Not:** Bu, [Mole](https://github.com/tw93/mole)'un Türk kullanıcılar için yerelleştirilmiş fork'udur. Tüm kredi orijinal yazara aittir.

## Özellikler

- **Hepsi bir arada araç seti**: CleanMyMac, AppCleaner, DaisyDisk ve iStat Menus'ü **tek bir binary** içinde birleştirir
- **Derin temizlik**: Önbellekleri, günlükleri, tarayıcı artıklarını ve sahipsiz uygulama verilerini kaldırarak **gigabytes'larca alan açar**
- **Akıllı kaldırıcı**: Uygulamaları launch agent, tercih dosyaları ve **gizli kalıntılarıyla** birlikte kaldırır
- **Disk içgörüleri**: Kullanımı görselleştirir, büyük dosyaları bulur, **önbellekleri yeniden oluşturur** ve sistem servislerini yeniler
- **Canlı izleme**: Gerçek zamanlı CPU, GPU, bellek, disk ve ağ istatistiklerini gösterir

## Hızlı Başlangıç

**Homebrew ile kurulum**

```bash
brew install mole
```

**Veya script ile**

```bash
# İsteğe bağlı argümanlar: -s latest ana branch kodu için, -s 1.17.0 belirli sürüm için
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

> Not: Mole, macOS için geliştirilmiştir. Deneysel bir Windows sürümü, erken benimseyenler için [windows branch](https://github.com/tw93/Mole/tree/windows)'inde mevcuttur.

**Çalıştırma**

```bash
mo                           # Etkileşimli menü
mo clean                     # Derin temizlik + zaten kaldırılmış uygulama artıkları
mo uninstall                 # Kurulu uygulamaları + artıklarını kaldır
mo optimize                  # Önbellekleri ve servisleri yenile
mo analyze                   # Görsel disk gezgini
mo status                    # Canlı sistem sağlığı paneli
mo purge                     # Proje derleme artifaktlarını temizle
mo installer                 # Yükleyici dosyalarını bul ve kaldır

mo touchid                   # Sudo için Touch ID yapılandır
mo completion                # Shell sekme tamamlamayı kur
mo update                    # Mole'u güncelle
mo update --nightly          # En son yayımlanmamış ana build'e güncelle (yalnızca script kurulumu)
mo remove                    # Mole'u sistemden kaldır
mo --help                    # Yardımı göster
mo --version                 # Kurulu sürümü göster
```

**Güvenli önizleme**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo purge --dry-run

# Şunlarla da çalışır: optimize, installer, remove, completion, touchid enable
mo clean --dry-run --debug   # Önizleme + ayrıntılı günlükler
mo optimize --whitelist      # Korunan optimizasyon kurallarını yönet
mo clean --whitelist         # Korunan önbellekleri yönet
mo purge --paths             # Proje tarama dizinlerini yapılandır
mo analyze /Volumes          # Yalnızca harici sürücüleri analiz et
```

## Güvenlik ve Emniyet Tasarımı

Mole yerel bir sistem bakım aracıdır ve bazı komutlar yıkıcı yerel işlemler gerçekleştirebilir.

Mole, önce güvenlik ilkesini benimser: yol doğrulama, korumalı dizin kuralları, muhafazakâr temizlik sınırları ve daha yüksek riskli işlemler için açık onay. Risk veya belirsizlik yüksek olduğunda, Mole silme kapsamını genişletmek yerine atlar, reddeder veya daha güçlü onay ister.

`mo analyze`, dosyaları doğrudan silmek yerine Finder aracılığıyla Çöp Kutusu'na taşıdığından geçici temizlik için daha güvenlidir.

Raporlama yönergeleri, güvenlik sınırları ve mevcut sınırlamalar için [SECURITY.md](SECURITY.md) ve [SECURITY_AUDIT.md](SECURITY_AUDIT.md) belgelerini inceleyin.

## İpuçları

- Video eğitimi: PAPAYA 電腦教室'e teşekkürler — [Mole eğitim videosunu](https://www.youtube.com/watch?v=UEe9-w4CcQ0) izleyin.
- Güvenlik ve günlükler: `clean`, `uninstall`, `purge`, `installer` ve `remove` yıkıcıdır. Önce `--dry-run` ile inceleyin, gerektiğinde `--debug` ekleyin. Dosya işlemleri `~/Library/Logs/mole/operations.log` dosyasına kaydedilir. `MO_NO_OPLOG=1` ile devre dışı bırakın. [SECURITY.md](SECURITY.md) ve [SECURITY_AUDIT.md](SECURITY_AUDIT.md) belgelerini inceleyin.
- Uygulama artıkları: Uygulama zaten kaldırılmışsa `mo clean`, hâlâ kuruluysa `mo uninstall` kullanın.
- Gezinti: Mole, ok tuşlarını ve Vim bağlamalarını `h/j/k/l` destekler.

## Ayrıntılı Özellikler

### Derin Sistem Temizliği

```bash
$ mo clean

Önbellek dizinleri taranıyor...

  ✓ Kullanıcı uygulama önbelleği                              45.2GB
  ✓ Tarayıcı önbelleği (Chrome, Safari, Firefox)              10.5GB
  ✓ Geliştirici araçları (Xcode, Node.js, npm)               23.3GB
  ✓ Sistem günlükleri ve geçici dosyalar                       3.8GB
  ✓ Uygulamaya özel önbellek (Spotify, Dropbox, Slack)         8.4GB
  ✓ Çöp Kutusu                                                12.3GB

====================================================================
Boşaltılan alan: 95.5GB | Şu anki boş alan: 223.5GB
====================================================================
```

Not: `mo clean` → Geliştirici araçları bölümünde Mole, kullanılmayan CoreSimulator `Volumes/Cryptex` girdilerini kaldırır ve `IN_USE` öğelerini atlar.

### Akıllı Uygulama Kaldırıcı

```bash
$ mo uninstall

Kaldırılacak Uygulamaları Seçin
═══════════════════════════
▶ ☑ Photoshop 2024            (4.2G) | Eski
  ☐ IntelliJ IDEA             (2.8G) | Yeni
  ☐ Premiere Pro              (3.4G) | Yeni

Kaldırılıyor: Photoshop 2024

  ✓ Uygulama kaldırıldı
  ✓ 12 konumdaki 52 ilgili dosya temizlendi
    - Uygulama Desteği, Önbellekler, Tercihler
    - Günlükler, WebKit depolama, Çerezler
    - Uzantılar, Eklentiler, Launch daemon'ları

Not: macOS 15 ve sonrasında, Yerel Ağ izin girdileri uygulama kaldırmanın ötesinde kalabilir. Mole, kaldırılan bir uygulama Yerel Ağ kullanımı beyan ettiğinde uyarır; ancak bu sıfırlama global olup Recovery modunu gerektirdiğinden `/Volumes/Data/Library/Preferences/com.apple.networkextension*.plist` dosyasını otomatik olarak sıfırlamaz.

====================================================================
Boşaltılan alan: 12.8GB
====================================================================
```

### Sistem Optimizasyonu

```bash
$ mo optimize

Sistem: 5/32 GB RAM | 333/460 GB Disk (%72) | Çalışma süresi 6g

  ✓ Sistem veritabanlarını yeniden oluştur ve önbellekleri temizle
  ✓ Ağ servislerini sıfırla
  ✓ Finder ve Dock'u yenile
  ✓ Tanılama ve çökme günlüklerini temizle
  ✓ Swap dosyalarını kaldır ve dynamic pager'ı yeniden başlat
  ✓ Launch services'i ve Spotlight dizinini yeniden oluştur

====================================================================
Sistem optimizasyonu tamamlandı
====================================================================

Belirli optimizasyonları dışlamak için `mo optimize --whitelist` kullanın.
```

### Disk Alanı Analizörü

> Not: Mole, varsayılan olarak daha hızlı başlangıç için `/Volumes` altındaki harici sürücüleri atlar. İncelemek için `mo analyze /Volumes` veya belirli bir bağlama yolu çalıştırın.

```bash
$ mo analyze

Diski Analiz Et  ~/Documents  |  Toplam: 156.8GB

 ▶  1. ███████████████████  %48.2  |  📁 Library                     75.4GB  >6ay
    2. ██████████░░░░░░░░░  %22.1  |  📁 Downloads                   34.6GB
    3. ████░░░░░░░░░░░░░░░  %14.3  |  📁 Movies                      22.4GB
    4. ███░░░░░░░░░░░░░░░░  %10.8  |  📁 Documents                   16.9GB
    5. ██░░░░░░░░░░░░░░░░░   %5.2  |  📄 backup_2023.zip              8.2GB

  ↑↓←→ Gezin  |  O Aç  |  F Göster  |  ⌫ Sil  |  L Büyük dosyalar  |  Q Çıkış
```

### Canlı Sistem Durumu

Sağlık puanı, donanım bilgisi ve performans metrikleriyle gerçek zamanlı panel.

```bash
$ mo status

Mole Durum  Sağlık ● 92  MacBook Pro · M4 Pro · 32GB · macOS 14.5

⚙ CPU                                    ▦ Bellek
Toplam  ████████████░░░░░░░  %45.2       Kullanılan  ███████████░░░░░░░  %58.4
Yük     0.82 / 1.05 / 1.23 (8 çekirdek)  Toplam      14.2 / 24.0 GB
Çek. 1  ███████████████░░░░  %78.3       Boş         ████████░░░░░░░░░░  %41.6
Çek. 2  ████████████░░░░░░░  %62.1       Kullanılabilir  9.8 GB

▤ Disk                                   ⚡ Güç
Kullanılan  █████████████░░░░░░  %67.2   Seviye  ██████████████████  %100
Boş         156.3 GB                     Durum   Şarj edildi
Okuma       ▮▯▯▯▯  2.1 MB/s             Sağlık  Normal · 423 döngü
Yazma       ▮▮▮▯▯  18.3 MB/s            Sıcaklık  58°C · 1200 RPM

⇅ Ağ                                     ▶ İşlemler
İndirme  ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s    Code       ▮▮▮▮▯  %42.1
Yükleme  ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s    Chrome     ▮▮▮▯▯  %28.3
Proxy    HTTP · 192.168.1.100            Terminal   ▮▯▯▯▯  %12.5
```

Sağlık puanı; CPU, bellek, disk, sıcaklık ve G/Ç yüküne dayalıdır ve renk kodlu aralıklara sahiptir.

Kısayollar: `mo status` içinde kediyi açıp kapatmak için `k`, çıkmak için `q` tuşuna basın; tercih kaydedilir.

Etkinleştirildiğinde, `mo status` yapılandırılan CPU eşiğinin üzerinde kalan işlemler için sürekli bir pencerede salt okunur uyarı başlığı gösterir. Ayarlamak veya devre dışı bırakmak için `--proc-cpu-threshold`, `--proc-cpu-window` veya `--proc-cpu-alerts=false` kullanın.

#### Makine Tarafından Okunabilir Çıktı

Hem `mo analyze` hem de `mo status`, komut dosyası oluşturma ve otomasyon için `--json` bayrağını destekler.

`mo status`, çıktısı pipe edildiğinde (terminal değil) otomatik olarak algılar ve JSON'a geçer.

```bash
# JSON olarak disk analizi
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "overview": false,
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true },
    ...
  ],
  "large_files": [
    { "name": "backup.zip", "path": "...", "size": 8796093022 }
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

# JSON olarak sistem durumu
$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8, ... },
  "memory": { "total": 25769803776, "used": 15049334784, "used_percent": 58.4 },
  "disks": [ ... ],
  "uptime": "3g 12s 45d",
  ...
}

# Pipe edildiğinde otomatik algılanan JSON
$ mo status | jq '.health_score'
92
```

### Proje Artifakt Temizliği

Disk alanı açmak için `node_modules`, `target`, `.build`, `build` ve `dist` gibi eski derleme artifaktlarını temizleyin.

```bash
mo purge

Temizlenecek Kategorileri Seçin - 18.5GB (8 seçili)

➤ ● my-react-app       3.2GB | node_modules
  ● old-project        2.8GB | node_modules
  ● rust-app           4.1GB | target
  ● next-blog          1.9GB | node_modules
  ○ current-work       856MB | node_modules  | Yeni
  ● django-api         2.3GB | venv
  ● vue-dashboard      1.7GB | node_modules
  ● backend-service    2.5GB | node_modules
```

> Not: macOS'ta `fd` kurulumu önerilir.
> `brew install fd`

> Güvenlik: Bu işlem, seçili artifaktları kalıcı olarak siler. Onaylamadan önce dikkatlice inceleyin. 7 günden yeni projeler işaretlenir ve varsayılan olarak seçili değildir.

<details>
<summary><strong>Özel Tarama Yolları</strong></summary>

Tarama dizinlerini yapılandırmak için `mo purge --paths` çalıştırın veya `~/.config/mole/purge_paths` dosyasını doğrudan düzenleyin:

```shell
~/Documents/Projelerim
~/Work/MusteriA
~/Work/MusteriB
```

Özel yollar yapılandırıldığında, Mole yalnızca bu dizinleri tarar. Aksi hâlde `~/Projects`, `~/GitHub` ve `~/dev` gibi varsayılanları kullanır.

</details>

### Yükleyici Temizliği

İndirmeler, Masaüstü, Homebrew önbellekleri, iCloud ve Mail genelinde büyük yükleyici dosyalarını bulun ve kaldırın. Her dosya kaynağına göre etiketlenir.

```bash
mo installer

Kaldırılacak Yükleyicileri Seçin - 3.8GB (5 seçili)

➤ ● Photoshop_2024.dmg     1.2GB | İndirmeler
  ● IntelliJ_IDEA.dmg       850.6MB | İndirmeler
  ● Illustrator_Setup.pkg   920.4MB | İndirmeler
  ● PyCharm_Pro.dmg         640.5MB | Homebrew
  ● Acrobat_Reader.dmg      220.4MB | İndirmeler
  ○ AppCode_Legacy.zip      410.6MB | İndirmeler
```

## Hızlı Başlatıcılar

Mole komutlarını Raycast veya Alfred'den başlatın:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

5 komut ekler: `Mole Clean`, `Mole Uninstall`, `Mole Optimize`, `Mole Analyze`, `Mole Status`.

### Raycast Kurulumu

Script çalıştırıldıktan sonra Raycast'te şu adımları tamamlayın:

1. Raycast Ayarlarını açın (⌘ + ,)
2. **Uzantılar** → **Script Komutları**'na gidin
3. **"Script Dizini Ekle"** (veya **"+"**) seçeneğine tıklayın
4. Şu yolu ekleyin: `~/Library/Application Support/Raycast/script-commands`
5. Raycast'te **"Script Dizinlerini Yenile"** seçeneğini arayın ve çalıştırın
6. Hazır! Komutları kullanmak için `Mole Clean`, `clean`, `Mole Optimize` veya `Mole Status` arayın

> **Not**: Script komutları oluşturur, ancak Raycast yine de tek seferlik manuel script dizini kurulumu gerektirir.

### Terminal Algılama

Mole, terminal uygulamanızı otomatik olarak algılar. iTerm2'nin bilinen uyumluluk sorunları vardır. [Kaku](https://github.com/tw93/Kaku)'yu şiddetle tavsiye ederiz. Diğer iyi seçenekler: Alacritty, kitty, WezTerm, Ghostty ve Warp. Geçersiz kılmak için `MO_LAUNCHER_APP=<isim>` ayarlayın.

## 🇹🇷 Dil Algılama

Bu fork, macOS sistem dil ayarınıza göre **otomatik olarak** Türkçe veya İngilizce arayüz sunar.

### Nasıl Çalışır?

Dil algılama iki katmanda gerçekleşir:

**1. Shell Katmanı (`lib/core/tr.sh`)**

Mole başladığında `lib/core/common.sh` tarafından otomatik olarak kaynak alınan `tr.sh`, `_detect_turkish_system()` fonksiyonunu çalıştırır:

```bash
# macOS sistem dilini AppleLanguages anahtarından okur
primary_lang=$(defaults read -g AppleLanguages 2>/dev/null \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [[ "$primary_lang" == tr || "$primary_lang" == tr-* ]]; then
    export MOLE_IS_TURKISH_SYSTEM="true"
else
    export MOLE_IS_TURKISH_SYSTEM="false"
fi
```

Algılama tamamlandıktan sonra tüm UI metinleri `${TR_DEGISKEN:-İngilizce geri dönüş}` kalıbıyla sunulur.

**2. Go İkili Katmanı (`mo analyze`, `mo status`)**

Go ile yazılmış bileşenler, shell tarafından export edilen `MOLE_IS_TURKISH_SYSTEM` ortam değişkenini okur (`cmd/analyze/i18n.go`, `cmd/status/i18n.go`):

```go
func isTurkish() bool {
    return os.Getenv("MOLE_IS_TURKISH_SYSTEM") == "true"
}

func t(en, tr string) string {
    if isTurkish() { return tr }
    return en
}
```

### Türkçeye Geçiş

**Sistem Ayarları üzerinden (kalıcı):**
1. **Sistem Ayarları** → **Genel** → **Dil ve Bölge**
2. Dil listesine **Türkçe** ekleyin ve birinci sıraya taşıyın
3. Oturumu yeniden açın

**Terminal üzerinden (kalıcı):**
```bash
defaults write -g AppleLanguages -array "tr-TR"
```

**Tek oturum için zorla Türkçe:**
```bash
MOLE_IS_TURKISH_SYSTEM=true mo
```

**Tek komut için zorla Türkçe:**
```bash
MOLE_IS_TURKISH_SYSTEM=true mo clean
MOLE_IS_TURKISH_SYSTEM=true mo status
```

## Topluluk Sevgisi

Mole'u inşa etmeye yardımcı olan herkese teşekkürler. Onları takip edin. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" width="1000" />
</a>

<br/><br/>
Mole'u X'te paylaşan kullanıcılardan gerçek geri bildirimler.

<img src="https://gw.alipayobjects.com/zos/k/dl/lovemole.jpeg" alt="Mole hakkında topluluk geri bildirimleri" width="1000" />

## Destek

- Mole size yardımcı olduysa, arkadaşlarınızla [paylaşın](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) veya yıldız verin.
- Fikir veya hata mı buldunuz? Bir issue veya PR açın, en iyi yapay zeka modelinizle katkıda bulunmaktan çekinmeyin.
- Geliştiricinin TangYuan ve Coke adında iki kedisi var. Mole hayatınızı güzelleştiriyorsa, onlara <a href="https://miaoyan.app/cats.html?name=Mole" target="_blank">konserve mama 🥩</a> ısmarlayabilirsiniz.

<a href="https://miaoyan.app/cats.html?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/MiaoYan@main/assets/sponsors.svg" width="1000" loading="lazy" /></a>

## Bu Fork Hakkında

Bu proje, orijinal [Mole](https://github.com/tw93/mole) projesinin Türkçe yerelleştirilmiş fork'udur.

**Yapılan değişiklikler:**
- `lib/core/tr.sh`: Merkezi Türkçe çeviri sistemi (shell katmanı)
- `lib/core/common.sh`: `tr.sh`'ı otomatik kaynak olarak ekler
- `cmd/analyze/i18n.go`: Go analiz bileşeni için dil algılama ve çeviri fonksiyonları
- `cmd/status/i18n.go`: Go durum bileşeni için dil algılama ve çeviri fonksiyonları
- Otomatik dil algılama (`MOLE_IS_TURKISH_SYSTEM` env var üzerinden shell↔Go köprüsü)
- Tüm kullanıcı arayüzü metinlerinin Türkçeye çevirisi (`${TR_KEY:-English fallback}` kalıbı)
- Go TUI bileşenleri (`mo analyze`, `mo status`) tam Türkçe desteği
- Bu Türkçe README dosyası

**Orijinal proje:** https://github.com/tw93/mole  
**Lisans:** MIT — Orijinal lisans korunmuştur

## Lisans

MIT Lisansı. Mole'u kullanmaktan ve katkıda bulunmaktan çekinmeyin.
