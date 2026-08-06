#!/bin/bash
#
# GokAI Kurulum — Adobe MCP köprüsü (Photoshop / Illustrator)
#
# Kullanım (arkadaşların çalıştıracağı tek satır):
#   curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
#
# Ne yapar:
#   1. Kendi özel Node.js kopyasını indirir (sisteme dokunmaz, sudo istemez)
#   2. uv (Python yöneticisi) kurar — yoksa
#   3. adb-mcp kaynak kodunu indirir
#   4. GokAI proxy'yi kurar ve oturum açılışında otomatik başlatır (launchd)
#   5. Claude Desktop yapılandırmasına MCP sunucularını ekler (mevcut ayarları BOZMAZ)
#   6. Illustrator CEP eklentisini kurar (kalıcı)
#   7. Photoshop UXP eklentisini .ccx olarak kurar (Beta makinelerde atlanır)
#   8. ~/Applications içine GokAI.app kısayolu koyar (durum panelini açar)
#
# Photoshop Beta olan makinelerde UXP eklentisi kurulamaz; betik bunu algılar ve
# yalnızca AppleScript tabanlı sunucuyu ekler (Beta'da 90 araçla tam çalışır).

set -euo pipefail

FORCE=0
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1; done

# ---------------------------------------------------------------- ayarlar ---
GOKAI_REPO_TARBALL="${GOKAI_REPO_TARBALL:-https://codeload.github.com/gokay12/gokai/tar.gz/refs/heads/main}"
ADB_MCP_TARBALL="https://codeload.github.com/mikechambers/adb-mcp/tar.gz/refs/heads/main"
NODE_VERSION="v22.14.0"
GOKAI_DIR="$HOME/Library/Application Support/GokAI"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PLIST="$HOME/Library/LaunchAgents/com.gokai.proxy.plist"
LOG_DIR="$HOME/Library/Logs"

# Yerel mod: betik, gokai-proxy.js'in yanından çalıştırılırsa repo indirilmez
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { printf "\n\033[1;35m[GokAI]\033[0m \033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
skip() { printf "  \033[90m·\033[0m %s\n" "$1"; }

bold ""
bold "  ██████╗  ██████╗ ██╗  ██╗ █████╗ ██╗"
bold " ██╔════╝ ██╔═══██╗██║ ██╔╝██╔══██╗██║"
bold " ██║  ███╗██║   ██║█████╔╝ ███████║██║"
bold " ██║   ██║██║   ██║██╔═██╗ ██╔══██║██║"
bold " ╚██████╔╝╚██████╔╝██║  ██╗██║  ██║██║"
bold "  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝"
bold "  Adobe MCP Köprüsü — Kurulum"

# Claude Desktop açıkken yapılandırma dosyasını düzenlemek GÜVENLİ DEĞİL:
# Claude kapanırken kendi bellekteki (eski) kopyasını dosyanın üzerine yazabiliyor
# ve kurulumda eklenen sunucular sessizce kayboluyor.
CLAUDE_PROC="$(ps -Ao comm= | grep 'Applications/Claude.app/Contents/MacOS/Claude$' || true)"
if [ -n "$CLAUDE_PROC" ] && [ "$FORCE" -eq 0 ]; then
  printf "\n  \033[33m!\033[0m \033[1mClaude Desktop açık.\033[0m\n\n"
  echo "  Claude açıkken yapılandırma düzenlenirse, Claude kapanırken eski"
  echo "  ayarlarını geri yazabilir ve kurulum boşa gider."
  echo ""
  printf "  Lütfen Claude Desktop uygulamasini \033[1mCmd+Q\033[0m ile kapatip tekrar calistirin.\n"
  echo "  (Yine de devam etmek için: ... | bash -s -- --force)"
  echo ""
  exit 1
fi

mkdir -p "$GOKAI_DIR" "$LOG_DIR" "$HOME/Applications" "$HOME/Library/LaunchAgents"

# ------------------------------------------------------------- 1. Node.js ---
step "1/8 Node.js hazırlanıyor (özel kopya, sisteme dokunmaz)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  NODE_ARCH="darwin-arm64" ;;
  x86_64) NODE_ARCH="darwin-x64" ;;
  *) echo "Desteklenmeyen mimari: $ARCH"; exit 1 ;;
esac

NODE_DIR="$GOKAI_DIR/node"
NODE_BIN="$NODE_DIR/bin/node"
if [ -x "$NODE_BIN" ]; then
  ok "Zaten kurulu: $("$NODE_BIN" -v)"
else
  NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-${NODE_ARCH}.tar.gz"
  curl -fsSL "$NODE_URL" -o "$GOKAI_DIR/node.tar.gz"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  tar -xzf "$GOKAI_DIR/node.tar.gz" -C "$NODE_DIR" --strip-components=1
  rm "$GOKAI_DIR/node.tar.gz"
  ok "Node $("$NODE_BIN" -v) kuruldu ($NODE_ARCH)"
fi
export PATH="$NODE_DIR/bin:$PATH"

# ------------------------------------------------------------------ 2. uv ---
step "2/8 uv (Python yöneticisi) hazırlanıyor"
if command -v uv >/dev/null 2>&1; then
  UV_BIN="$(command -v uv)"
  ok "Zaten kurulu: $UV_BIN"
elif [ -x "$HOME/.local/bin/uv" ]; then
  UV_BIN="$HOME/.local/bin/uv"
  ok "Zaten kurulu: $UV_BIN"
else
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  UV_BIN="$HOME/.local/bin/uv"
  [ -x "$UV_BIN" ] || { echo "uv kurulumu başarısız"; exit 1; }
  ok "uv kuruldu: $UV_BIN"
fi

# ------------------------------------------------------------- 3. adb-mcp ---
step "3/8 adb-mcp indiriliyor"
ADB_DIR="$GOKAI_DIR/adb-mcp"
curl -fsSL "$ADB_MCP_TARBALL" -o "$GOKAI_DIR/adb-mcp.tar.gz"
rm -rf "$ADB_DIR"; mkdir -p "$ADB_DIR"
tar -xzf "$GOKAI_DIR/adb-mcp.tar.gz" -C "$ADB_DIR" --strip-components=1
rm "$GOKAI_DIR/adb-mcp.tar.gz"
ok "adb-mcp hazır: $ADB_DIR"

# --------------------------------------------------------- 4. GokAI proxy ---
step "4/8 GokAI proxy + durum paneli kuruluyor"
PROXY_DIR="$GOKAI_DIR/proxy"
mkdir -p "$PROXY_DIR"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/gokai-proxy.js" ]; then
  # Yerel mod (geliştirme / repo checkout'u)
  cp "$SCRIPT_DIR/gokai-proxy.js" "$SCRIPT_DIR/package.json" "$PROXY_DIR/"
  rm -rf "$PROXY_DIR/public"; cp -R "$SCRIPT_DIR/public" "$PROXY_DIR/public"
  [ -f "$SCRIPT_DIR/gokai.icns" ] && cp "$SCRIPT_DIR/gokai.icns" "$GOKAI_DIR/gokai.icns"
  ok "Yerel dosyalardan kopyalandı"
else
  # Uzak mod: GokAI reposunun tamamını indir
  curl -fsSL "$GOKAI_REPO_TARBALL" -o "$GOKAI_DIR/gokai.tar.gz"
  TMP_EXTRACT="$GOKAI_DIR/.gokai-src"
  rm -rf "$TMP_EXTRACT"; mkdir -p "$TMP_EXTRACT"
  tar -xzf "$GOKAI_DIR/gokai.tar.gz" -C "$TMP_EXTRACT" --strip-components=1
  cp "$TMP_EXTRACT/gokai-proxy.js" "$TMP_EXTRACT/package.json" "$PROXY_DIR/"
  rm -rf "$PROXY_DIR/public"; cp -R "$TMP_EXTRACT/public" "$PROXY_DIR/public"
  [ -f "$TMP_EXTRACT/gokai.icns" ] && cp "$TMP_EXTRACT/gokai.icns" "$GOKAI_DIR/gokai.icns"
  rm -rf "$TMP_EXTRACT" "$GOKAI_DIR/gokai.tar.gz"
  ok "GokAI dosyaları indirildi"
fi

( cd "$PROXY_DIR" && "$NODE_DIR/bin/npm" install --silent --no-audit --no-fund >/dev/null 2>&1 )
ok "Bağımlılıklar kuruldu (express, socket.io)"

# launchd servisi
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.gokai.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_DIR}/bin/node</string>
        <string>${PROXY_DIR}/gokai-proxy.js</string>
    </array>
    <key>WorkingDirectory</key><string>${PROXY_DIR}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${LOG_DIR}/gokai-proxy.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/gokai-proxy.error.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
ok "Arka plan servisi kuruldu (oturum açılışında otomatik başlar)"

# ---------------------------------------------- 5. Claude Desktop config ---
step "5/8 Claude Desktop yapılandırılıyor"
[ -f "$CLAUDE_CONFIG" ] && cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.gokai-backup-$(date +%Y%m%d%H%M%S)"

# Normal (Beta olmayan) Photoshop var mı? Yoksa UXP eklentisi kurulamaz, dolayısıyla
# ona bağlı MCP sunucusunu hiç ekleme — Claude'da hiç bağlanmayan bir sunucu görünmesin.
HAS_STABLE_PS=0
for d in /Applications/Adobe\ Photoshop*; do
  case "$d" in *"(Beta)"*) ;; *) [ -d "$d" ] && HAS_STABLE_PS=1 ;; esac
done
[ "$HAS_STABLE_PS" -eq 1 ] || warn "Sadece Photoshop Beta bulundu — UXP tabanlı sunucu atlanıyor (AppleScript sunucusu Beta'da tam çalışır)"

GOKAI_DIR="$GOKAI_DIR" UV_BIN="$UV_BIN" CLAUDE_CONFIG="$CLAUDE_CONFIG" HAS_STABLE_PS="$HAS_STABLE_PS" \
"$NODE_DIR/bin/node" <<'MERGE_EOF'
const fs = require("fs");
const path = require("path");

const gokaiDir = process.env.GOKAI_DIR;
const uvBin = process.env.UV_BIN;
const configPath = process.env.CLAUDE_CONFIG;
const nodeBin = path.join(gokaiDir, "node", "bin");
const adbMcp = path.join(gokaiDir, "adb-mcp", "mcp");

// mcp[cli] SABİTLENMELİ: yeni sürümlerde fastmcp modülü kaldırıldı,
// pin olmadan adb-mcp sunucuları ModuleNotFoundError ile çöker.
const adbArgs = (script) => [
  "run",
  "--with", "fonttools",
  "--with", "mcp[cli]==1.5.0",
  "--with", "numpy",
  "--with", "pillow",
  "--with", "python-socketio",
  "--with", "requests",
  "--with", "websocket-client",
  "mcp", "run", path.join(adbMcp, script),
];

const entries = {
  "GokAI Photoshop": {
    command: path.join(nodeBin, "npx"),
    args: ["-y", "@alisaitteke/photoshop-mcp"],
    env: { LOG_LEVEL: "1", PATH: `${nodeBin}:/usr/bin:/bin` },
  },
  "GokAI Illustrator":      { command: uvBin, args: adbArgs("ai-mcp.py") },
};

// UXP eklentisi yalnızca normal Photoshop'ta kurulabiliyor; Beta-only makinelerde
// bu sunucu asla bağlanamaz, o yüzden hiç eklenmiyor.
if (process.env.HAS_STABLE_PS === "1") {
  entries["GokAI Photoshop Plugin"] = { command: uvBin, args: adbArgs("ps-mcp.py") };
}

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(configPath, "utf8")); } catch (e) {}
cfg.mcpServers = cfg.mcpServers || {};

// Bu çalıştırmada eklenmeyen eski GokAI girdilerini temizle. Örn. makinede
// normal Photoshop varken kurulmuş, sonra sadece Beta kalmışsa "GokAI Photoshop
// Plugin" girdisi ortada kalır ve Claude'da hiç bağlanmayan bir sunucu görünür.
for (const name of Object.keys(cfg.mcpServers)) {
  if (name.startsWith("GokAI ") && !(name in entries)) {
    delete cfg.mcpServers[name];
    console.log(`  \x1b[33m!\x1b[0m eski girdi kaldırıldı: ${name}`);
  }
}
Object.assign(cfg.mcpServers, entries); // GokAI anahtarları; diğerleri korunur

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
console.log(`  \x1b[32m✓\x1b[0m ${Object.keys(entries).length} MCP sunucusu eklendi (mevcut ayarlar korundu)`);
MERGE_EOF

# Python ortamlarını önceden ısıt (ilk Claude açılışı yavaş olmasın)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"gokai-warmup","version":"1.0"}}}'
WARM="ai-mcp.py"; [ "$HAS_STABLE_PS" -eq 1 ] && WARM="ps-mcp.py ai-mcp.py"
for f in $WARM; do
  echo "$INIT" | "$UV_BIN" run \
    --with fonttools --with "mcp[cli]==1.5.0" --with numpy --with pillow \
    --with python-socketio --with requests --with websocket-client \
    mcp run "$GOKAI_DIR/adb-mcp/mcp/$f" >/dev/null 2>&1 \
    && ok "$f doğrulandı" || warn "$f doğrulanamadı (internet bağlantısını kontrol edin)"
done

# ------------------------------------------- 6. Illustrator eklentisi (CEP) ---
# Illustrator CEP kullanıyor: klasör bağlantısı + imzasız eklentilere izin.
# UXP'nin aksine bu KALICIDIR — Illustrator her açıldığında tekrar yüklemeye gerek yok.
step "6/8 Illustrator eklentisi kuruluyor (CEP)"
CEP_DIR="$HOME/Library/Application Support/Adobe/CEP/extensions"
CEP_SRC="$GOKAI_DIR/adb-mcp/cep/com.mikechambers.ai"
if [ -d "$CEP_SRC" ]; then
  mkdir -p "$CEP_DIR"
  ln -sfn "$CEP_SRC" "$CEP_DIR/com.mikechambers.ai"
  ok "eklenti bağlandı: com.mikechambers.ai"
  # İmzasız CEP eklentilerinin yüklenmesi için gerekli (CSXS sürümü CC sürümüne göre değişir)
  for v in 10 11 12 13; do defaults write "com.adobe.CSXS.$v" PlayerDebugMode 1 2>/dev/null; done
  ok "PlayerDebugMode etkinleştirildi"
else
  warn "CEP kaynağı bulunamadı, atlandı"
fi

# ------------------------------------------- 7. Photoshop eklentisi (UXP/.ccx) ---
# Adobe'nin resmi komut satırı kurucusuyla (UPIA) .ccx paketini kurar.
# Başarılı olursa KALICIDIR — UXP Developer Tools'a hiç gerek kalmaz.
# Photoshop Beta'da çalışmaz (Adobe Beta'yı geçerli hedef saymıyor); o durumda
# aşağıdaki uyarı çıkar ve UDT ile elle kurulur.
step "7/8 Photoshop eklentisi kuruluyor (.ccx)"
UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
PS_CCX_URL="https://github.com/mikechambers/adb-mcp/releases/download/v0.85.4/Photoshop.MCP.Agent_PS.ccx"
PS_CCX="$GOKAI_DIR/Photoshop_MCP_Agent.ccx"
UXP_EXTERNAL="$HOME/Library/Application Support/Adobe/UXP/Plugins/External"

ps_plugin_installed() { ls "$UXP_EXTERNAL" 2>/dev/null | grep -qi "Photoshop MCP Agent"; }

if [ "$HAS_STABLE_PS" -eq 0 ]; then
  skip_ccx=1
  warn "Photoshop Beta — .ccx kurulumu atlandı (AppleScript sunucusu eklenti istemez)"
elif [ ! -x "$UPIA" ]; then
  warn "Adobe eklenti kurucusu bulunamadı — Photoshop eklentisi elle kurulmalı"
elif pgrep -f "Adobe Photoshop [0-9]" >/dev/null 2>&1; then
  warn "Photoshop açık — eklenti kurulamadı. Photoshop'u kapatıp kurulumu tekrar çalıştırın."
else
  curl -fsSL "$PS_CCX_URL" -o "$PS_CCX" 2>/dev/null || true
  if [ -s "$PS_CCX" ]; then
    # UPIA bazen takılıyor: arka planda çalıştırıp süre sınırı koy.
    # Ayrıca eski bir kayıt varsa önce kaldır — yoksa "başarılı" deyip dosya yazmıyor.
    ( "$UPIA" --remove "Photoshop MCP Agent" >/dev/null 2>&1 & sleep 20; kill %1 2>/dev/null ) >/dev/null 2>&1
    ( "$UPIA" --install "$PS_CCX" >/dev/null 2>&1 & sleep 40; kill %1 2>/dev/null ) >/dev/null 2>&1
    if ps_plugin_installed; then
      ok "Photoshop eklentisi kalıcı olarak kuruldu (UDT gerekmiyor)"
    else
      warn "Otomatik kurulum olmadı — Photoshop Beta kullanıyorsanız normaldir."
      warn "Elle kurulum: UXP Developer Tools › Add Plugin ›"
      warn "  $GOKAI_DIR/adb-mcp/uxp/ps/manifest.json  → Load"
    fi
  else
    warn "Eklenti paketi indirilemedi (internet?) — elle kurulacak"
  fi
fi

# ----------------------------------------------------- 8. GokAI.app kısayolu ---
step "8/8 GokAI.app oluşturuluyor"
APP="$HOME/Applications/GokAI.app"
rm -rf "$APP"
osacompile -e 'do shell script "open http://localhost:3001"' -o "$APP" >/dev/null 2>&1
# Yerelde oluşturulduğu için Gatekeeper karantinası YOK.
# Özel ikon uygula
if [ -f "$GOKAI_DIR/gokai.icns" ] && [ -d "$APP/Contents/Resources" ]; then
  cp "$GOKAI_DIR/gokai.icns" "$APP/Contents/Resources/applet.icns"
  touch "$APP"
fi
ok "~/Applications/GokAI.app hazır (durum panelini açar)"

# ----------------------------------------------------------------- kontrol ---
sleep 1
if curl -fsS "http://localhost:3001/status" >/dev/null 2>&1; then
  ok "Proxy yanıt veriyor: http://localhost:3001"
else
  warn "Proxy henüz yanıt vermiyor — birkaç saniye sonra GokAI.app ile kontrol edin"
fi

printf "\n\033[1;32mKurulum tamamlandı!\033[0m\n\n"
echo "Sonraki adımlar:"
echo "  1. Claude Desktop'ı TAMAMEN kapatıp yeniden açın (Cmd+Q)"
echo "  2. Illustrator: yeniden başlat → Pencere › Uzantılar › Illustrator MCP Agent → Connect"
if [ "$HAS_STABLE_PS" -eq 1 ]; then
  echo "  3. Photoshop: yeniden başlat → Eklentiler › Photoshop MCP Agent → Connect"
  echo "     (7/8 adımında sarı uyarı çıktıysa eklenti elle kurulmalı)"
else
  echo "  3. Photoshop: yapacak bir şey yok — Beta'da eklentisiz çalışır"
fi
echo "  4. Durum paneli: GokAI.app  →  http://localhost:3001"
echo ""
open "http://localhost:3001" 2>/dev/null || true
