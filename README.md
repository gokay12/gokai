<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/gokai-logo-dark.svg">
    <img src="brand/gokai-logo.svg" alt="GokAI v3" width="340">
  </picture>
</p>

# GokAI — Adobe MCP Köprüsü

Ajans içindeki Mac'lere Claude ↔ Adobe (Photoshop / Illustrator / Premiere Pro /
After Effects) entegrasyonunu tek komutla kuran sistem.

## Makinede ne olması gerekiyor?

**Hiçbir şey.** Ne Homebrew, ne Python, ne Node.js, ne Xcode araçları, ne `sudo`.

| Gereksinim | Nasıl karşılanıyor |
|---|---|
| Node.js | Betik kendi özel kopyasını indirir (sisteme dokunmaz) |
| Python | Betik kendi özel `uv` + Python 3.12 kopyasını indirir — sistemdeki Python/uv kullanılmaz |
| Python / npm paketleri | **Kilit dosyalarından** birebir kurulur; Claude açılırken hiçbir şey internetten çözülmez |
| Adobe eklentileri | Betik kurar (Illustrator CEP + Photoshop `.ccx`) |

Tek gerçek gereksinim: **macOS + Creative Cloud + Claude Desktop** (ve kurulum
sırasında internet). Kurulan her şey `~/Library/Application Support/GokAI/`
içinde toplanır (~750 MB).

## Kurulum

**Temiz makine ya da mevcut kurulumu güncelleme/onarma:**
```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
```

Kurulum her şeyi önce geçici bir klasörde hazırlar, yeni MCP sunucularını
**gerçekten başlatıp dener**, ancak ondan sonra yerine koyar. İnternet yarıda
kesilirse ya da bir şey başarısız olursa çalışan mevcut kurulum olduğu gibi kalır.
Tekrar çalıştırmak zararsızdır; değişmeyen bileşenleri yeniden indirmez.

**Her şeyi silip sıfırdan** (çok eski / elle yapılmış kurulumları da temizler):
```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash -s -- --install
```

> ⚠️ **Kurulumdan önce Claude Desktop'ı Cmd+Q ile kapat.** Claude açıkken
> yapılandırma dosyası düzenlenirse Claude kendi eski kopyasını üzerine yazabiliyor
> ve kurulum sessizce geri alınıyor. Betikler bunu kontrol edip açıksa reddediyor.
> Photoshop da kapalı olmalı (eklenti açık uygulamaya kurulamaz); Illustrator
> açıksa kurulumdan sonra yeniden başlat.

## Kurulumdan sonra — makine başına tek seferlik

1. **Claude Desktop'ı aç.** (Kurulum sırasında açıksa: Cmd+Q ile tamamen kapatıp aç.)
2. **Illustrator** → yeniden başlat → **bir dosya aç** (eklenti dosya açık değilken
   başlamaz) → **Pencere › Uzantılar › Illustrator MCP Agent**.
   Panel açılınca **kendiliğinden bağlanır**; paneli açık/yerleşik bıraktığın sürece
   her Illustrator açılışında yeniden bağlanır.
3. **Photoshop** → yeniden başlat → **Eklentiler › Photoshop MCP Agent** →
   **Connect** → **Connect on Launch** ✅
   *(Beta kullanan makinelerde bu adım yok — aşağıya bak.)*
4. **Premiere Pro** (kuruluysa) → yeniden başlat → **Pencere › Uzantılar › MCP Bridge (CEP)**.
   Panel açılınca köprüyü kendisi başlatır; paneli açık/yerleşik bırak.
5. **After Effects** (kuruluysa) → yeniden başlat. Eklenti kendiliğinden başlar
   (görünmezse Mac'i bir kez yeniden başlat — macOS ayarı önbellekte kalabiliyor).
6. Doğrula: **GokAI.app** (`~/Applications`) → *"Tüm sistemler hazır"* yazmalı,
   **Tanı** bölümünde sorun görünmemeli.

## Bir makinede sorun mu var?

Önce doktoru çalıştır — hiçbir şeyi değiştirmez, neyin bozuk olduğunu söyler:
```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/doctor.sh | bash
```

Doktor şunlara bakar:

- kurulum dosyaları, Node, kilitli Python ortamı
- arka plan servisi (launchd), 3001 portunu kimin dinlediği
- Claude Desktop yapılandırması (girdiler var mı, gösterdikleri komutlar yerinde mi,
  eski "açılışta internetten çöz" tarzında mı)
- **MCP sunucularını Claude'un yaptığı gibi başlatıp el sıkışma yapar** — Claude'da
  "Server disconnected / troubleshooting" hatası çıkıyorsa nedenini burada görürsün
- Adobe eklentileri ve canlı bağlantı durumu
- Claude'un günlüklerindeki bilinen hata imzaları (tarih ve sayısıyla)

Aynı tanı durum panelinin **Tanı** bölümünde de var; proxy her açılışta bir kez
kendiliğinden çalıştırır. Eski (v1.x) kurulumlarda da çalışır.

## Photoshop Beta olan makineler

Betik bunu **kendisi algılar**, aynı komutu çalıştır, ekstra bir şey yapma.

Adobe, Beta sürümünü geçerli eklenti hedefi saymadığı için UXP eklentisi
kurulamaz. Betik bu durumda `.ccx` adımını atlar, bağlanamayacak olan
`GokAI Photoshop Plugin` sunucusunu Claude'a hiç eklemez (eskiden kalmışsa siler)
ve panelde Photoshop kartını "AppleScript · eklenti gerekmez" olarak gösterir.

Photoshop yine **tam çalışır**: `GokAI Photoshop` sunucusu AppleScript kullanır,
eklenti ve proxy istemez.

Yani Beta makinelerde **UXP Developer Tools, `.ccx`, Developer Mode ve Connect
butonu — hiçbiri gerekmiyor.**

## Kaldırma

```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash
```

`reset.sh` şunları **silmez**: Homebrew ile kurulmuş node/uv, diğer CEP/UXP
eklentilerin (AtomX vb.), GokAI dışındaki MCP sunucuların, yapılandırma yedekleri.

`--install` ile çağrıldığında, bir şey silmeden **önce** kurulumun ihtiyaç duyduğu
adreslere ulaşılabildiğini kontrol eder; internet yokken makineyi GokAI'siz bırakmaz.

## Neden artık kopmuyor (v2)

v1'de Claude her açıldığında sunucular `uv run --with …` ve `npx -y …` ile
**o anda internetten** kuruluyordu. Bunun dört ayrı sonucu vardı; hepsi Claude'da
aynı *"Server disconnected. For troubleshooting guidance…"* hatası olarak görünüyordu:

| Belirti | Neden | v2'de |
|---|---|---|
| Bir gün aniden açılmamaya başladı | `mcp 1.5.0` sabitti ama alt bağımlılıkları değil; `pydantic 2.14` çıkınca `ImportError` | Tüm paketler `mcp/requirements.lock` ile sürüm + hash kilitli |
| İnternet yokken / yavaşken açılmıyor | Açılışta PyPI ve npm'e gitmek zorundaydı (60 sn sınırı) | Açılışta internet yok; Illustrator sunucusu ~0,2 sn'de açılır |
| Arada bir Photoshop sunucusu düşüyor | Claude iki kopya başlatınca `npx` önbelleği çakışıyor (`ENOTEMPTY`) | Sunucu yerelde kurulu, `node` ile doğrudan çalışır |
| Illustrator'da Connect hiçbir şey yapmıyor | Eklenti Socket.IO'yu CDN'den yüklüyordu | Socket.IO eklentinin içinde |

Bağlantının kendisi için eklenenler:

- **Proxy kapalıysa MCP sunucusu onu kendisi başlatır** (launchd; servis bir
  temizlik uygulamasınca devre dışı bırakılmışsa doğrudan).
- **Eklentiler süresiz yeniden bağlanır.** Proxy yeniden başlasa ya da Mac uykudan
  uyansa da elle Connect gerekmez. Komut sürerken bağlantı anlık koparsa yanıt
  kaybolmaz, yeniden bağlanınca iletilir.
- **Makine meşgulken komut düşmez.** Render ya da büyük dosya sırasında proxy
  birkaç saniye yanıt veremezse komut bekler ve proxy toparlanınca tamamlanır.
  (adb-mcp bağlanmak için yalnızca 1 sn bekliyordu; sağlam proxy "bozuk" sayılıyordu.)
  Komut yalnızca *hiç gönderilmediyse* yeniden denenir — aynı işlem iki kez çalışmaz.
- **Eklenti bağlı değilse komut 20 sn asılı kalmaz;** Claude'a nedenini söyleyen
  bir hata hemen döner ("Illustrator açık değil", "eklenti bağlı değil", "uygulama
  yanıt vermiyor — açık bir iletişim kutusu olabilir").
- Uzun işlemler için zaman aşımı 20 → 55 sn; ping toleransı 20 → 45 sn.
- Yanıt gelir gelmez Claude'a döner; bağlantının kapanması yanıtı bekletmez
  (adb-mcp'de kapanış takılırsa başarılı komut bile bir dakikadan fazla asılı kalabiliyordu).
- adb-mcp bozuk bir yazı tipinde `stdout`'a yazıp MCP bağlantısını bozabiliyordu;
  başlatıcı bunu `stderr`'e yönlendirir.
- Hatalı bir paket ya da beklenmeyen bir istisna proxy'yi düşüremez.
- Proxy yalnızca bu makineden erişilir (`127.0.0.1` / `::1`); ağdaki başka bir
  cihaz ya da tarayıcıda açık bir web sayfası Adobe uygulamasına komut gönderemez,
  proxy'yi yeniden başlatamaz.

## Panelde ne var

- **Kişisel selamlama** — saate göre *Günaydın / Merhaba / İyi akşamlar / İyi geceler*,
  makine sahibinin adıyla (macOS hesap adından okunur).
- **Canlı durum kartları** — her Adobe uygulaması ve sistem bileşeni için
  ("Illustrator kapalı" ile "eklenti bağlı değil" ayrı gösterilir).
- **Tanı** — doktorun bulduğu sorunlar ve düzeltme komutu (kopyala düğmesiyle).
- **Çift tıkla → aç** — Photoshop, Illustrator ve Claude Desktop kartlarına çift
  tıklayınca uygulama açılır.
- **Yeniden başlat** düğmesi — proxy'yi sıfırlar; eklentiler kendiliğinden geri bağlanır.

> Uygulama açma ve yeniden başlatma istekleri yalnızca panelin kendi kaynağından
> kabul edilir; yalnızca sabit beyaz listedeki üç uygulama açılabilir.

## Bileşenler

| Dosya | Ne işe yarar |
|---|---|
| `install.sh` | Kurulum: hazırla → dene → yerine koy → launchd + Claude config + Adobe eklentileri + GokAI.app → doktorla doğrula |
| `reset.sh` | Önceki tüm kurulumları temizler; `--install` ile hemen temiz kurulum yapar |
| `doctor.sh` | Tek satırlık tanı (yalnızca okur) |
| `gokai-doctor.js` | Tanının kendisi; doctor.sh, install.sh ve proxy (`/doctor`) aynı kodu kullanır |
| `gokai-proxy.js` | adb-mcp proxy'sinin GokAI sürümü: aynı protokol + sağlamlaştırma + `/status`, `/doctor` + panel |
| `public/` | Durum paneli (http://localhost:3001) ve sekme ikonu |
| `brand/` | Logo ve uygulama ikonunun kaynakları (SVG); `gokai.icns` ve `icon_1024.png` `brand/gokai-icon.svg` dosyasından üretildi |
| `mcp/gokai_mcp.py` | adb-mcp sunucularının başlatıcısı (proxy'yi ayağa kaldırır, hata iletilerini düzeltir) |
| `mcp/requirements.lock` | Kilitli Python ortamı (sürüm + hash) |
| `cep/` | Illustrator eklentisinin GokAI sürümü (adb-mcp'nin `index.html` + `main.js` dosyalarının yerine geçer) |
| `photoshop-mcp/` | Sabit sürümlü Photoshop MCP sunucusu (`package.json` + `package-lock.json`) |
| `video-mcp/` | Sabit sürümlü Premiere Pro ve After Effects MCP sunucuları (`package.json` + `package-lock.json`) |
| `tests/` | Test takımları (`bash tests/run.sh`) — kurulum, proxy, başlatıcı, eklenti |

Makinedeki yerleşim (`~/Library/Application Support/GokAI/`):
`node/` · `uv/` · `python/` · `venv/` · `adb-mcp/` · `photoshop-mcp/` · `proxy/` ·
`mcp/` · `install.json`

## Claude Desktop'a eklenen MCP sunucuları

| Girdi | Nasıl çalışır | Not |
|---|---|---|
| GokAI Photoshop | `node …/photoshop-mcp/…/dist/index.js` | Eklenti gerektirmez, AppleScript ile çalışır |
| GokAI Photoshop Plugin | `venv/bin/python -I mcp/gokai_mcp.py photoshop` | UXP eklentisi + proxy gerekir — **Beta makinelerde eklenmez** |
| GokAI Illustrator | `venv/bin/python -I mcp/gokai_mcp.py illustrator` | CEP eklentisi + proxy gerekir |
| GokAI Premiere Pro | `node …/video-mcp/…/adobe-premiere-pro-mcp/dist/index.js` | Yalnızca Premiere kuruluysa. "MCP Bridge (CEP)" paneli, `/tmp/premiere-mcp-bridge` klasörü üzerinden |
| GokAI After Effects | `node …/video-mcp/…/@engine-room/after-effects-mcp/bin/server.js` | Yalnızca After Effects kuruluysa. "AE MCP Bridge" paneli kendi yerel bağlantısını kurar (GokAI proxy'si kullanılmaz) |

Hiçbiri `uv run` ya da `npx` kullanmaz. `-I`, Python'u kullanıcının
`PYTHONPATH` / site-packages ayarlarından yalıtır.

## Sürümleri yükseltme (bakımcı için)

Her şey bilinçli olarak sabit; "en yenisi" hiçbir yerde kullanılmıyor. Yükseltirken:

- **Python paketleri** — `mcp/requirements.in` / `mcp/constraints.txt` düzenle,
  kilidi yeniden üret (komut `requirements.in` dosyasının başında). `mcp` 1.5.0'da
  kalıyorsa `pydantic<2.14` sınırı kalmalı.
- **photoshop-mcp / Premiere Pro / After Effects** — `photoshop-mcp/` ya da
  `video-mcp/` içindeki `package.json` sürümünü değiştir, o klasörde
  `npm install --package-lock-only` çalıştır. After Effects paneli kurulurken
  içine `ws` modülü kopyalanır (paketin kendi `setup_panel` aracı gibi); yeni
  sürümde panel düzeni değiştiyse install.sh'taki After Effects adımına bak.
- **adb-mcp** — `install.sh` içindeki `ADB_MCP_COMMIT`. Upstream'in
  `cep/com.mikechambers.ai/main.js` ya da `index.html` dosyası değiştiyse kurulum
  bilerek durur: `cep/` altındaki GokAI sürümlerini yeni upstream ile karşılaştır,
  sonra `CEP_UPSTREAM_*_SHA256` değerlerini güncelle.
- **Node / uv** — `install.sh` başındaki sürüm ve `sha256` değerleri (iki mimari).
- **GokAI sürümü** — `install.sh` (`GOKAI_VERSION`), `gokai-proxy.js` (`VERSION`),
  `gokai-doctor.js` (`DOCTOR_VERSION`) ve `package.json` aynı olmalı. Logoda "GokAI"
  sabittir, yanındaki rozet ana sürümü gösterir: paneldeki rozet sürümü kendisi okur;
  ana sürüm değişince (v3 → v4) yalnızca `brand/gokai-logo*.svg` içindeki `v3`
  yazısını güncelle.

**Yayınlamadan önce testleri çalıştır.** Sahte bir ev klasörüne test modunda kurup
kurulum senaryolarını (internet kesintisi, yarıda kesilme, bozuk Claude ayarı…),
proxy/başlatıcı/eklenti bağlantı davranışını ve internetsiz açılışı dener; gerçek
kuruluma dokunmaz:
```bash
GOKAI_SANDBOX_HOME=/tmp/gokai-test bash tests/run.sh
```
Yalnızca kurulumu elle denemek için:
`HOME=/tmp/gokai-test GOKAI_TEST_MODE=1 GOKAI_PORT=3907 bash install.sh`

## Sorun giderme

Önce doktoru çalıştır (yukarıda). Sık görülenler:

- **Claude'da "Server disconnected / troubleshooting"** → Eski (v1) kurulum.
  Claude'u kapatıp kurulum komutunu çalıştır.
- **Panel açılmıyor** → Bilgisayarı yeniden başlat (launchd proxy'yi otomatik başlatır).
  Log: `~/Library/Logs/gokai-proxy.log`. Claude'daki bir GokAI aracını kullanmak da
  proxy'yi başlatır.
- **Kart "Eklenti bağlı değil"de kalıyor** → İlgili uygulamada eklenti paneli açık mı?
  Illustrator'da önce bir dosya açık olmalı.
- **Illustrator'da "Illustrator MCP Agent" menüde yok** → Illustrator 2024 (28) ve
  üzeri gerekir; kurulumdan sonra Illustrator'ı yeniden başlat.
- **Claude araçları görmüyor** → Claude Desktop Cmd+Q ile tamamen kapatılıp açıldı mı?
- **Photoshop eklentisi (UXP) kurulmadı** (normal Photoshop'lu makine) → Kurulum
  nedenini en sonda yazar; doktor da gösterir. Sık nedenler:
  - *Photoshop açıktı* → kapat, kurulum komutunu tekrar çalıştır (bu kez saniyeler sürer).
  - *Photoshop eski* → eklenti Photoshop 2025 (v26) ve üzerinde yüklenir.
  - *Durum kodu -411* → Adobe'nin kurucusu o Photoshop'u tanımıyor: Creative Cloud
    uygulamasını aç, oturum aç, Photoshop'u oradan güncelle; sonra tekrar çalıştır.
  - Olmuyorsa elle: `~/Library/Application Support/GokAI/Photoshop_MCP_Agent.ccx`
    dosyasına çift tıkla, Creative Cloud açılınca **Yükle**'ye bas.

  Eklenti kurulana kadar `GokAI Photoshop` (AppleScript) sunucusu yine çalışır.
- **Photoshop araçları "izin verilmedi" (not authorized / -1743) diyor** → İlk kullanımda
  macOS *"Claude, Adobe Photoshop'u denetlemek istiyor"* diye sorar; reddedildiyse
  **Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon › Claude › Adobe Photoshop**
  anahtarını aç. (Bu izin doktorun göremediği tek şeydir.)
- **Kurulum "Photoshop açık" / "Claude Desktop açık" diyor** → İlgili uygulamayı
  kapatıp betiği tekrar çalıştır. Bu kontrol bilinçli: açık uygulamalar kurulumu
  sessizce geri alabiliyor.
- **Kurulum "indirilemedi" diyor** → İnternet / VPN / güvenlik yazılımı. Mevcut
  kuruluma dokunulmamıştır; düzeltip aynı komutu tekrar çalıştır.
  Ayrıntı: `~/Library/Logs/gokai-install.log`.
- **Kurulum "Claude yapılandırma dosyası bozuk" diyor** → Betik bozuk dosyanın
  üzerine yazmaz (diğer MCP sunucuların silinmesin). Dosyayı düzelt ya da aynı
  klasördeki bir `*.gokai-backup-*` yedeğini geri yükle.

## Bilinen sınırlar

- **InDesign yok.** adb-mcp InDesign UXP eklentisi içeriyor ama `.ccx` olarak
  paketlenmiş resmi bir sürümü yok; UXP Developer Tools ile elle yüklendiğinde
  InDesign her açıldığında tekrar `Load` gerektiriyor. 10+ makine için
  sürdürülebilir olmadığından kapsam dışı bırakıldı.
- Photoshop Beta'da UXP eklentisi kurulamaz (yukarıda açıklandı) — AppleScript
  sunucusu bu boşluğu tamamen dolduruyor.
- Photoshop UXP eklentisi **Photoshop 2025 (v26) ve üzerini** ister. Adobe'nin
  kurucusu (UPIA) başarısız olduğunda da başarılı gibi çıkar; kurulum bu yüzden
  yazdığı durum kodunu okuyup nedenini gösterir.
- Illustrator eklentisi yalnızca **paneli açıkken** çalışır (CEP sınırı). Paneli
  kapatırsan bağlantı kopar; yeniden açınca kendiliğinden bağlanır.
- Photoshop UXP eklentisi (`.ccx`) adb-mcp'nin hazır paketidir; bağlantı
  iyileştirmeleri Illustrator eklentisinde ve proxy/başlatıcı tarafındadır.
- 55 saniyeden uzun süren tek bir işlem zaman aşımına uğrar (MCP istemcilerinde
  yaygın olan 60 sn'lik istek sınırının altında tutuldu); işlem uygulamada yine de
  tamamlanmış olabilir.
- Proxy portu sabit: **3001** (eklentilerin içinde yazılı).

## Teşekkürler & Lisanslar

GokAI, açık kaynak projelerin üzerine kurulmuş bir kurulum/panel katmanıdır —
asıl işi yapan onlar:

- **[adb-mcp](https://github.com/mikechambers/adb-mcp)** — Mike Chambers (MIT).
  Photoshop / Illustrator MCP sunucuları ve UXP/CEP eklentileri.
  `gokai-proxy.js` içindeki proxy protokolü bu projenin `adb-proxy-socket`
  bileşeninden, `cep/main.js` ise `cep/com.mikechambers.ai/main.js` dosyasından
  türetilmiştir; orijinal lisans bildirimleri korunmaktadır.
- **[adobe_premiere_pro_mcp](https://github.com/hetpatel-11/adobe_premiere_pro_mcp)** —
  hetpatel-11 (MIT). Premiere Pro MCP sunucusu ve "MCP Bridge (CEP)" paneli
  (`adobe-premiere-pro-mcp` npm paketi olarak kurulur).
- **[after-effects-mcp](https://github.com/Engine-Room-Games/after-effects-mcp)** —
  Engine Room (MIT). After Effects MCP sunucusu ve "AE MCP Bridge" paneli
  (`@engine-room/after-effects-mcp` npm paketi olarak kurulur).
- **[photoshop-mcp](https://github.com/alisaitteke/photoshop-mcp)** — Ali Sait Teke (MIT).
  Eklentisiz, AppleScript tabanlı Photoshop MCP sunucusu
  (`@alisaitteke/photoshop-mcp` npm paketi olarak kurulur, kodu bu repoda yer almaz).

Bu repo MIT lisanslıdır — bkz. [LICENSE](LICENSE).
