# GokAI — Adobe MCP Köprüsü

Ajans içindeki Mac'lere Claude ↔ Adobe (Photoshop / Illustrator / InDesign)
entegrasyonunu tek komutla kuran sistem.

## Bileşenler

| Dosya | Ne işe yarar |
|---|---|
| `install.sh` | Tek satır kurulum: Node (özel kopya) + uv + adb-mcp + proxy + launchd + Claude config + GokAI.app |
| `gokai-proxy.js` | adb-mcp proxy'sinin GokAI sürümü: aynı protokol + `/status` API + web paneli + `/restart` |
| `public/index.html` | Durum paneli (http://localhost:3001) |
| `uninstall.sh` | Her şeyi geri alır |

## Dağıtım (senin yapacakların — bir kere)

1. GitHub'da `gokai` adında bir repo aç (public).
2. Bu klasördeki dosyaları push et.
3. `install.sh` içindeki `gokay12` yer tutucusunu kendi kullanıcı adınla değiştir (2 yerde: en üstteki yorum + `GOKAI_REPO_TARBALL`).
4. Arkadaşlarına şu tek satırı gönder:

```bash
curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
```

## Kurulumdan sonra (her makinede)

- Claude Desktop **tamamen** kapatılıp açılmalı (Cmd+Q).
- UXP/CEP eklentilerini sen kuracaksın (Photoshop `.ccx`, InDesign UXP, Illustrator CEP).
  Eklenti panellerinde **Connect on Launch** işaretlenirse kimsenin bir daha
  butona basması gerekmez.
- Durum paneli: **GokAI.app** (~/Applications) veya `http://localhost:3001`

## Claude Desktop'a eklenen MCP sunucuları

| Girdi | Kaynak | Not |
|---|---|---|
| GokAI Photoshop | `@alisaitteke/photoshop-mcp` (npx) | Eklenti gerektirmez, AppleScript ile çalışır |
| GokAI Photoshop Plugin | adb-mcp `ps-mcp.py` | UXP eklentisi + proxy gerekir |
| GokAI Illustrator | adb-mcp `ai-mcp.py` | CEP eklentisi + proxy gerekir |
| GokAI InDesign | adb-mcp `id-mcp.py` | UXP eklentisi + proxy gerekir |

> **Önemli:** adb-mcp girdilerinde `mcp[cli]==1.5.0` sabitlemesi bilinçli.
> Paketin yeni sürümlerinde `mcp.server.fastmcp` modülü kaldırıldığı için
> pin olmadan sunucular açılmaz. Kaldırma!

## Sorun giderme

- **Panel açılmıyor** → Bilgisayarı yeniden başlat (launchd proxy'yi otomatik başlatır).
  Log: `~/Library/Logs/gokai-proxy.error.log`
- **Kart "Bekleniyor"da kalıyor** → İlgili Adobe uygulamasında eklenti paneli açık mı,
  Connect'e basılmış mı? (Illustrator'da önce bir dosya açık olmalı.)
- **Claude araçları görmüyor** → Claude Desktop Cmd+Q ile tamamen kapatılıp açıldı mı?

## Bilinen sınırlar

- Photoshop/InDesign UXP eklentileri `.ccx` olarak kurulmadıysa (UXP Developer
  Tools ile yüklendiyse) her uygulama açılışında yeniden yüklenmeleri gerekir.
- Proxy portu sabit: 3001.
