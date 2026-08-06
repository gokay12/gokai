# GokAI — Adobe MCP Köprüsü

Ajans içindeki Mac'lere Claude ↔ Adobe (Photoshop / Illustrator) entegrasyonunu
tek komutla kuran sistem.

## Makinede ne olması gerekiyor?

**Hiçbir şey.** Ne Homebrew, ne Python, ne Node.js, ne Xcode araçları, ne `sudo`.

| Gereksinim | Nasıl karşılanıyor |
|---|---|
| Node.js | Betik kendi özel kopyasını indirir (sisteme dokunmaz) |
| Python | `uv` kendi Python'unu indirir — macOS'un eski 3.9'u kullanılmaz |
| uv | Yoksa betik kurar (tek dosya, Homebrew'e gerek yok) |
| Adobe eklentileri | Betik kurar (Illustrator CEP + Photoshop `.ccx`) |

Tek gerçek gereksinim: **macOS + Creative Cloud + Claude Desktop**.
Kurulan her şey `~/Library/Application Support/GokAI/` içinde toplanır.

## Kurulum

**Temiz makine:**
```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
```

**Daha önce kurulum yapılmış makine** (eski sürüm, elle kurulum, bozuk kurulum):
```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash -s -- --install
```

> Emin değilsen ikincisini kullan — temiz makinede de sorunsuz çalışır.

> ⚠️ **Kurulumdan önce Claude Desktop'ı Cmd+Q ile kapat.** Claude açıkken
> yapılandırma dosyası düzenlenirse Claude kendi eski kopyasını üzerine yazabiliyor
> ve kurulum sessizce geri alınıyor. Betikler bunu kontrol edip açıksa reddediyor.
> Photoshop ve Illustrator da kapalı olmalı (eklentiler açık uygulamaya kurulamaz).

## Kurulumdan sonra — makine başına tek seferlik

1. **Claude Desktop'ı Cmd+Q ile tamamen kapat, yeniden aç.** (Pencereyi kapatmak yetmez.)
2. **Illustrator** → yeniden başlat → **bir dosya aç** (eklenti dosya açık değilken
   başlamaz) → **Pencere › Uzantılar › Illustrator MCP Agent** → **Connect** →
   **Connect automatically on launch** ✅
3. **Photoshop** → yeniden başlat → **Eklentiler › Photoshop MCP Agent** →
   **Connect** → **Connect on Launch** ✅
   *(Beta kullanan makinelerde bu adım yok — aşağıya bak.)*
4. Doğrula: **GokAI.app** (`~/Applications`) → *"Tüm sistemler hazır"* yazmalı.

Her ikisi de kalıcıdır — bir daha uğraşmazsın.

## Photoshop Beta olan makineler

Betik bunu **kendisi algılar**, aynı komutu çalıştır, ekstra bir şey yapma.

Adobe, Beta sürümünü geçerli eklenti hedefi saymadığı için UXP eklentisi
kurulamaz. Betik bu durumda `.ccx` adımını atlar, bağlanamayacak olan
`GokAI Photoshop Plugin` sunucusunu Claude'a hiç eklemez (eskiden kalmışsa siler)
ve panelde Photoshop kartını gizler.

Photoshop yine **tam çalışır**: `GokAI Photoshop` sunucusu AppleScript kullanır,
eklenti ve proxy istemez. Photoshop Beta 27.10'da doğrulandı — `photoshop_ping`
→ *"Successfully connected"*, **90 araç** kullanılabilir (katman/maske/seçim,
filtreler, Generative Fill, 15 hazır tarif, `get_preview`).

Yani Beta makinelerde **UXP Developer Tools, `.ccx`, Developer Mode ve Connect
butonu — hiçbiri gerekmiyor.**

## Kaldırma

```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash
```

`reset.sh` şunları **silmez**: Homebrew ile kurulmuş node/uv, diğer CEP/UXP
eklentilerin (AtomX vb.), GokAI dışındaki MCP sunucuların, yapılandırma yedekleri.

## Bileşenler

| Dosya | Ne işe yarar |
|---|---|
| `install.sh` | Kurulum: Node + uv + adb-mcp + proxy + launchd + Claude config + Adobe eklentileri + GokAI.app |
| `reset.sh` | Önceki tüm kurulumları temizler; `--install` ile hemen temiz kurulum yapar |
| `gokai-proxy.js` | adb-mcp proxy'sinin GokAI sürümü: aynı protokol + `/status` API + panel |
| `public/index.html` | Durum paneli (http://localhost:3001) |

## Claude Desktop'a eklenen MCP sunucuları

| Girdi | Kaynak | Not |
|---|---|---|
| GokAI Photoshop | `@alisaitteke/photoshop-mcp` | Eklenti gerektirmez, AppleScript ile çalışır |
| GokAI Photoshop Plugin | adb-mcp `ps-mcp.py` | UXP eklentisi + proxy gerekir — **Beta makinelerde eklenmez** |
| GokAI Illustrator | adb-mcp `ai-mcp.py` | CEP eklentisi + proxy gerekir |

> **Önemli:** adb-mcp girdilerindeki `mcp[cli]==1.5.0` sabitlemesi bilinçli.
> Paketin yeni sürümlerinde `mcp.server.fastmcp` modülü kaldırıldığı için
> pin olmadan sunucular `ModuleNotFoundError` ile açılmaz. Kaldırma.

## Sorun giderme

- **Panel açılmıyor** → Bilgisayarı yeniden başlat (launchd proxy'yi otomatik başlatır).
  Log: `~/Library/Logs/gokai-proxy.error.log`
- **Kart "Bekleniyor"da kalıyor** → İlgili uygulamada eklenti paneli açık mı,
  Connect'e basıldı mı? Illustrator'da önce bir dosya açık olmalı.
- **Connect'e basınca hiçbir şey olmuyor** → Panel, eklenti yüklenmeden *önce*
  açılmış olabilir. Paneli kapat, uygulamayı yeniden başlat, paneli tekrar aç.
- **Claude araçları görmüyor** → Claude Desktop Cmd+Q ile tamamen kapatılıp açıldı mı?
- **Kurulum "Photoshop açık" / "Claude Desktop açık" diyor** → İlgili uygulamayı
  kapatıp betiği tekrar çalıştır. Bu kontrol bilinçli: açık uygulamalar kurulumu
  sessizce geri alabiliyor.
- **Kurulum başarılı görünüyor ama Claude sunucuları görmüyor** → Kurulum sırasında
  Claude Desktop açık mıydı? Açıksa yapılandırmayı geri yazmış olabilir; Claude'u
  Cmd+Q ile kapatıp kurulumu tekrar çalıştır.

## Bilinen sınırlar

- **InDesign yok.** adb-mcp InDesign UXP eklentisi içeriyor ama `.ccx` olarak
  paketlenmiş resmi bir sürümü yok; UXP Developer Tools ile elle yüklendiğinde
  InDesign her açıldığında tekrar `Load` gerektiriyor. 10+ makine için
  sürdürülebilir olmadığından kapsam dışı bırakıldı.
- Photoshop Beta'da UXP eklentisi kurulamaz (yukarıda açıklandı) — AppleScript
  sunucusu bu boşluğu tamamen dolduruyor.
- Proxy portu sabit: **3001**.

## Teşekkürler & Lisanslar

GokAI, iki açık kaynak projenin üzerine kurulmuş bir kurulum/panel katmanıdır —
asıl işi yapan onlar:

- **[adb-mcp](https://github.com/mikechambers/adb-mcp)** — Mike Chambers (MIT).
  Photoshop / Illustrator MCP sunucuları ve UXP/CEP eklentileri.
  `gokai-proxy.js` içindeki proxy protokolü bu projenin `adb-proxy-socket`
  bileşeninden türetilmiştir; orijinal lisans bildirimi dosyada korunmaktadır.
- **[photoshop-mcp](https://github.com/alisaitteke/photoshop-mcp)** — Ali Sait Teke (MIT).
  Eklentisiz, AppleScript tabanlı Photoshop MCP sunucusu
  (`@alisaitteke/photoshop-mcp` npm paketi olarak çalışır, kodu bu repoda yer almaz).

Bu repo MIT lisanslıdır — bkz. [LICENSE](LICENSE).
