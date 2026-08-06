# GokAI — Adobe MCP Köprüsü

Ajans içindeki Mac'lere Claude ↔ Adobe (Photoshop / Illustrator)
entegrasyonunu tek komutla kuran sistem.

## Makinede ne olması gerekiyor?

**Hiçbir şey.** Ne Homebrew, ne Python, ne Node.js, ne Xcode araçları.

| Gereksinim | Nasıl karşılanıyor |
|---|---|
| Node.js | Betik kendi özel kopyasını indirir (sisteme dokunmaz, sudo istemez) |
| Python | `uv` kendi Python'unu indirir — macOS'un eski 3.9'u kullanılmaz |
| uv | Yoksa betik kurar (Homebrew'e gerek yok, tek dosya) |
| Adobe eklentileri | Betik kurar (Illustrator CEP + Photoshop `.ccx`) |

Tek gerçek gereksinim: **macOS + Creative Cloud uygulamaları + Claude Desktop**.
Kurulan her şey `~/Library/Application Support/GokAI/` içinde toplanır,
`reset.sh` ile izsiz kaldırılır.

## Bileşenler

| Dosya | Ne işe yarar |
|---|---|
| `install.sh` | Tek satır kurulum: Node (özel kopya) + uv + adb-mcp + proxy + launchd + Claude config + GokAI.app |
| `gokai-proxy.js` | adb-mcp proxy'sinin GokAI sürümü: aynı protokol + `/status` API + web paneli + `/restart` |
| `public/index.html` | Durum paneli (http://localhost:3001) |
| `reset.sh` | **Eski/bozuk kurulumları tamamen temizler** (elle kurulanlar dahil) |
| `uninstall.sh` | Her şeyi geri alır |

## Dağıtım (senin yapacakların — bir kere)

1. GitHub'da `gokai` adında bir repo aç (public).
2. Bu klasördeki dosyaları push et.
3. Arkadaşlarına şu tek satırı gönder:

```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
```

## Daha önce kurulum yapılmış makineler

Eski bir sürüm ya da elle kurulum varsa **önce sıfırla**, sonra kur:

```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash -s -- --install
```

Bu komut önce her şeyi temizler, ardından temiz kurulumu kendisi başlatır.
Sadece temizlemek için `-s -- --install` kısmını çıkar.

`reset.sh` şunları **silmez**: Homebrew ile kurulmuş node/uv, senin diğer
CEP/UXP eklentilerin (AtomX vb.), GokAI ile ilgisi olmayan MCP sunucuların,
yapılandırma yedekleri. Adobe uygulamaları veya Claude açıksa çalışmayı reddeder
(zorlamak için `--force`).

## Photoshop Beta olan makineler

Betik bunu **kendisi algılar** — yapman gereken bir şey yok, aynı komutu çalıştır.

Adobe, Beta sürümünü geçerli eklenti hedefi saymadığı için UXP eklentisi
kurulamaz. Betik bu durumda:
- `.ccx` kurulum adımını atlar
- UXP tabanlı `GokAI Photoshop Plugin` sunucusunu Claude'a **hiç eklemez**
  (varsa eski girdiyi de siler)
- Panelde Photoshop kartını gizler

Photoshop yine tam çalışır: **GokAI Photoshop** sunucusu AppleScript kullanır,
eklenti ve proxy istemez. Photoshop Beta 27.10 üzerinde doğrulandı —
`photoshop_ping` → *"Successfully connected"*, **90 araç** kullanılabilir
(katman/maske/seçim, filtreler, Generative Fill, 15 hazır tarif, `get_preview`).

Yani Beta makinelerde **UXP Developer Tools, `.ccx`, Developer Mode ve Connect
butonu — hiçbiri gerekmiyor.**

## Kurulumdan sonra (her makinede)

- Claude Desktop **tamamen** kapatılıp açılmalı (Cmd+Q).
Kurulum betiği **her iki Adobe eklentisini de kendisi kurar**. Sana kalan tek şey
her uygulamada bir kez panel açıp Connect'e basmak:

- **Illustrator** → yeniden başlat → bir dosya aç → **Pencere › Uzantılar ›
  Illustrator MCP Agent** → **Connect** → **Connect automatically on launch** ✅
- **Photoshop** → yeniden başlat → **Eklentiler › Photoshop MCP Agent** →
  **Connect** → **Connect on Launch** ✅

Her ikisi de kalıcıdır — bir daha uğraşmazsın.

> Kurulum sırasında Photoshop adımında **sarı uyarı** çıktıysa (Photoshop Beta'da
> olur), o makinede eklenti elle kurulmalı: UXP Developer Tools › **Add Plugin** ›
> `~/Library/Application Support/GokAI/adb-mcp/uxp/ps/manifest.json` › **Load**.
> Bu durumda Photoshop her açıldığında tekrar `Load` gerekir.
- Durum paneli: **GokAI.app** (~/Applications) veya `http://localhost:3001`

## Claude Desktop'a eklenen MCP sunucuları

| Girdi | Kaynak | Not |
|---|---|---|
| GokAI Photoshop | `@alisaitteke/photoshop-mcp` (npx) | Eklenti gerektirmez, AppleScript ile çalışır |
| GokAI Photoshop Plugin | adb-mcp `ps-mcp.py` | UXP eklentisi + proxy gerekir |
| GokAI Illustrator | adb-mcp `ai-mcp.py` | CEP eklentisi + proxy gerekir |

> **Önemli:** adb-mcp girdilerinde `mcp[cli]==1.5.0` sabitlemesi bilinçli.
> Paketin yeni sürümlerinde `mcp.server.fastmcp` modülü kaldırıldığı için
> pin olmadan sunucular açılmaz. Kaldırma!

## UXP/CEP eklenti kurulumu (senin yapacakların — her makinede)

Kurulum betiği MCP sunucularını ve proxy'yi halleder; Adobe eklentileri elle kurulur.

**Illustrator (CEP)** — betik bunu otomatik yapar, sadece Illustrator'ı yeniden başlat:
`~/Library/Application Support/Adobe/CEP/extensions` içine sembolik bağ + `PlayerDebugMode`.
Panel: **Pencere › Uzantılar › Illustrator MCP Agent** (önce bir dosya açık olmalı).

**Photoshop (UXP)** — UXP Developer Tools ile:
1. Photoshop'ta **Ayarlar › Eklentiler › Geliştirici Modunu Etkinleştir** → uygulamayı yeniden başlat
2. UXP Developer Tools → **Add Plugin** →
   `~/Library/Application Support/GokAI/adb-mcp/uxp/ps/manifest.json`
3. **Load** → uygulamada **Eklentiler › … MCP Agent** panelini aç → **Connect**
4. Panelde **Connect on Launch**'ı işaretle

> **Sıra önemli:** Panel, UDT'den `Load` yapılmadan *önce* açıldıysa Connect yanıt vermez.
> Önce Load, sonra paneli aç.

> **Dikkat:** UXP eklentileri `.ccx` olarak kurulmadıkça uygulama her yeniden
> başladığında UDT'den tekrar `Load` edilmelidir.

## Sorun giderme

- **Panel açılmıyor** → Bilgisayarı yeniden başlat (launchd proxy'yi otomatik başlatır).
  Log: `~/Library/Logs/gokai-proxy.error.log`
- **Kart "Bekleniyor"da kalıyor** → İlgili Adobe uygulamasında eklenti paneli açık mı,
  Connect'e basılmış mı? (Illustrator'da önce bir dosya açık olmalı.)
- **Connect'e basınca hiçbir şey olmuyor** → Panel, UDT'den `Load` yapılmadan önce
  açılmış demektir. Paneli kapat, UDT'de `Load` durumunu doğrula, paneli yeniden aç.
- **`Connection error: timeout`** (UDT › Debug › Console) → Eklenti manifest'inde
  ağ izni hatalı: `requiredPermissions.network.domains` değeri `"all"`
  (dizi değil, düz string) olmalı.
- **Claude araçları görmüyor** → Claude Desktop Cmd+Q ile tamamen kapatılıp açıldı mı?

## Bilinen sınırlar

- Photoshop UXP eklentisi `.ccx` olarak kurulmadıysa (UXP Developer Tools ile
  yüklendiyse) Photoshop her açıldığında yeniden `Load` edilmelidir.
  Illustrator (CEP) bundan etkilenmez — kalıcıdır.
- **InDesign desteklenmiyor:** adb-mcp'nin InDesign UXP eklentisi upstream'de hatalı
  bir manifest ağ izniyle geliyor (`domains` dizi olarak) ve proxy'ye bağlanamıyor
  (`Connection error: timeout`). Upstream düzelirse tekrar eklenebilir.
- Proxy portu sabit: 3001.

## Teşekkürler & Lisanslar

GokAI, iki harika açık kaynak projenin üzerine kurulmuş bir kurulum/panel katmanıdır —
asıl işi yapan onlar:

- **[adb-mcp](https://github.com/mikechambers/adb-mcp)** — Mike Chambers (MIT).
  Photoshop / Illustrator MCP sunucuları ve UXP/CEP eklentileri.
  `gokai-proxy.js` içindeki proxy protokolü bu projenin `adb-proxy-socket`
  bileşeninden türetilmiştir; orijinal lisans bildirimi dosyada korunmaktadır.
  Kurulum sırasında proje kaynak kodu GitHub'dan indirilir.
- **[photoshop-mcp](https://github.com/alisaitteke/photoshop-mcp)** — Ali Sait Teke (MIT).
  Eklentisiz, AppleScript tabanlı 89 araçlı Photoshop MCP sunucusu
  (`@alisaitteke/photoshop-mcp` npm paketi olarak çalıştırılır, bu repoda kodu yer almaz).

Bu repo MIT lisanslıdır — bkz. [LICENSE](LICENSE).
