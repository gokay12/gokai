#!/bin/bash
#
# GokAI Sıfırlama — önceki TÜM kurulumları temizler (elle kurulanlar dahil)
#
# Kullanım:
#   Sadece temizle:
#     curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash
#
#   Temizle + hemen temiz kurulum yap:
#     curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/reset.sh | bash -s -- --install
#
# Ne SİLMEZ (bilerek):
#   - Homebrew ile kurulmuş node / uv  (başka işler bunlara bağlı olabilir)
#   - Senin diğer CEP/UXP eklentilerin (AtomX, Animation Composer vb.)
#   - Claude Desktop'taki GokAI ile ilgisi olmayan MCP sunucuları
#   - Eski yapılandırma yedekleri (güvenlik için duruyorlar)

set -uo pipefail

# Test modu (GOKAI_TEST_MODE=1): launchd'ye ve gerçek 3001 portuna dokunmaz.
TEST_MODE="${GOKAI_TEST_MODE:-0}"

# --- JSON düzenlemesi için yorumlayıcı seç ---------------------------------
# Sistem python3'ü (/usr/bin/python3) Xcode Command Line Tools gerektirir ve
# kurulu değilse bir kurulum penceresi açar. Tasarımcı makinelerinde çoğu zaman
# yoktur — o yüzden önce CLT'yi kontrol et, yoksa GokAI'nin / uv'nin indirdiği
# python'a düş.
PY_BIN=""        # yorumlayıcının (ya da uv'nin) yolu
PY_VIA_UV=0      # 1: "uv run --quiet python" ile çalıştır
USE_SYSTEM_PY=1
# (Yalnızca test: CLT'siz bir makineyi taklit et.)
if [ "$TEST_MODE" = "1" ] && [ "${GOKAI_TEST_NO_SYSTEM_PYTHON:-0}" = "1" ]; then USE_SYSTEM_PY=0; fi

if [ "$USE_SYSTEM_PY" -eq 1 ] && xcode-select -p >/dev/null 2>&1 && /usr/bin/python3 -c "pass" >/dev/null 2>&1; then
  PY_BIN="/usr/bin/python3"
else
  # GokAI v2 kendi Python'unu getirir; v1 kurulumlarında uv'nin indirdiği durur.
  for c in "$HOME/Library/Application Support/GokAI/venv/bin/python" \
           "$HOME/Library/Application Support/GokAI/python"/*/bin/python3 \
           "$HOME/.local/share/uv/python"/*/bin/python3; do
    if [ -x "$c" ] && "$c" -c "pass" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
  done
  if [ -z "$PY_BIN" ]; then
    if command -v uv >/dev/null 2>&1; then PY_BIN="$(command -v uv)"; PY_VIA_UV=1
    elif [ -x "$HOME/.local/bin/uv" ]; then PY_BIN="$HOME/.local/bin/uv"; PY_VIA_UV=1
    fi
  fi
fi

# Seçilen yorumlayıcıyla stdin'deki betiği çalıştırır. Yol boşluk içerebildiği
# ("Application Support") için tırnaksız bir değişken yerine fonksiyon.
py_run() {
  if [ -z "$PY_BIN" ]; then cat >/dev/null; return 0; fi   # yorumlayıcı yok: atla
  if [ "$PY_VIA_UV" -eq 1 ]; then "$PY_BIN" run --quiet python "$@"; else "$PY_BIN" "$@"; fi
}

DO_INSTALL=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --force)   FORCE=1 ;;
  esac
done

INSTALL_URL="https://raw.githubusercontent.com/gokay12/gokai/main/install.sh"
PORT=3001
if [ "$TEST_MODE" = "1" ]; then
  # Test modu gerçek proxy'nin portunu (3001) asla kullanmaz.
  PORT="${GOKAI_PORT:-3907}"
  if [ "$PORT" = "3001" ]; then echo "Test modunda GOKAI_PORT 3001 olamaz (gerçek servisin portu)."; exit 1; fi
  INSTALL_URL="${GOKAI_INSTALL_URL:-$INSTALL_URL}"
fi
GOKAI_DIR="$HOME/Library/Application Support/GokAI"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PLIST="$HOME/Library/LaunchAgents/com.gokai.proxy.plist"
CEP_DIR="$HOME/Library/Application Support/Adobe/CEP/extensions"
UXP_DIR="$HOME/Library/Application Support/Adobe/UXP"
UDT_WS="$HOME/Library/Application Support/Adobe/Adobe UXP Developer Tool/plugins_workspace.json"

step() { printf "\n\033[1;38;5;208m[GokAI]\033[0m \033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
skip() { printf "  \033[90m·\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

printf "\n\033[1m  GokAI — Sıfırlama\033[0m\n"
printf "  Önceki tüm kurulumları temizler\n"

# ------------------------------------------------- 0. Açık uygulama kontrolü ---
step "0/8 Açık uygulamalar kontrol ediliyor"
RUNNING=""
pgrep -f "Adobe Photoshop [0-9]" >/dev/null 2>&1 && RUNNING="$RUNNING Photoshop"
pgrep -f "Adobe Photoshop (Beta)" >/dev/null 2>&1 && RUNNING="$RUNNING Photoshop-Beta"
pgrep -f "Illustrator.app/Contents/MacOS" >/dev/null 2>&1 && RUNNING="$RUNNING Illustrator"
pgrep -f "InDesign.app/Contents/MacOS" >/dev/null 2>&1 && RUNNING="$RUNNING InDesign"
# NOT: `ps ... | grep -q` kullanma — grep erken çıkınca ps SIGPIPE alır ve
# `set -o pipefail` yüzünden boru hattı başarısız sayılır (tespit sessizce kaçar).
CLAUDE_PROC="$(ps -Ao comm= | grep 'Applications/Claude.app/Contents/MacOS/Claude$' || true)"
[ -n "$CLAUDE_PROC" ] && RUNNING="$RUNNING Claude-Desktop"

[ "$TEST_MODE" = "1" ] && RUNNING=""
if [ -n "$RUNNING" ] && [ "$FORCE" -eq 0 ]; then
  warn "Şu uygulamalar açık:$RUNNING"
  echo ""
  echo "  Eklentiler açık uygulamalardan temizlenemez."
  echo "  Lütfen bunları kapatıp betiği tekrar çalıştırın."
  echo "  (Yine de devam etmek için sonuna --force ekleyin.)"
  exit 1
fi
[ -z "$RUNNING" ] && ok "Adobe uygulamaları ve Claude kapalı" || warn "--force ile devam ediliyor"

# Temizledikten sonra yeniden kuracaksak: silmeden ÖNCE kurulumun indirebileceğinden
# emin ol. İnternet yokken çalışan kurulumu silip makineyi GokAI'siz bırakmayalım.
INSTALL_SCRIPT=""
if [ "$DO_INSTALL" -eq 1 ]; then
  INSTALL_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/gokai-install.XXXXXX")"
  if ! curl -fsSL --connect-timeout 15 --max-time 60 "$INSTALL_URL" -o "$INSTALL_SCRIPT" 2>/dev/null \
     || ! grep -q "GokAI Kurulum" "$INSTALL_SCRIPT"; then
    rm -f "$INSTALL_SCRIPT"
    warn "Kurulum betiği indirilemedi — internet bağlantısını kontrol edin."
    echo "  Hiçbir şey silinmedi; mevcut kurulumunuz olduğu gibi duruyor."
    exit 1
  fi
  if [ "$TEST_MODE" != "1" ]; then
    # Yalnızca başlık iste (-I) ve küçük adresler kullan: pypi.org/simple/ gibi
    # sayfalar onlarca MB; gövdesini indirmek yavaş bağlantıda zaman aşımına düşer.
    for host in https://nodejs.org/dist/ https://pypi.org/simple/pip/ https://registry.npmjs.org/-/ping https://codeload.github.com/; do
      if ! curl -sS -I -o /dev/null --connect-timeout 10 --max-time 20 "$host" 2>/dev/null; then
        rm -f "$INSTALL_SCRIPT"
        warn "Kurulum için gereken adrese ulaşılamıyor: $host"
        echo "  Hiçbir şey silinmedi; mevcut kurulumunuz olduğu gibi duruyor."
        echo "  Ağ / VPN / güvenlik yazılımını kontrol edip tekrar deneyin."
        exit 1
      fi
    done
  fi
  ok "Kurulum için gereken adreslere ulaşılabiliyor"
fi

# --------------------------------------------------------- 1. Arka plan servisi ---
step "1/8 Arka plan servisi durduruluyor"
if [ "$TEST_MODE" = "1" ]; then
  rm -f "$PLIST"
  skip "test modu: launchd'ye dokunulmadı (kayıt dosyası silindi)"
elif [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  ok "launchd servisi kaldırıldı (com.gokai.proxy)"
else
  # plist elle silinmiş ama servis hâlâ yüklü olabilir
  launchctl bootout "gui/$(id -u)/com.gokai.proxy" >/dev/null 2>&1
  skip "launchd servisi zaten yok"
fi

# Portta kalan süreçler (elle başlatılmış eski proxy'ler ve MCP sunucularının
# doğrudan başlattığı kopyalar dahil)
PIDS="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u)"
if [ -n "$PIDS" ]; then
  echo "$PIDS" | xargs kill 2>/dev/null
  sleep 1
  ok "$PORT portundaki süreçler durduruldu"
else
  skip "$PORT portu zaten boş"
fi

# ---------------------------------------------------- 2. Claude Desktop config ---
step "2/8 Claude Desktop yapılandırması temizleniyor"
if [ -z "$PY_BIN" ]; then
  warn "JSON düzenleyici bulunamadı — yapılandırma temizliği atlanıyor."
  warn "Kurulum yine de çalışır; eski girdiler Claude'da görünürse haber ver."
fi
if [ -f "$CLAUDE_CONFIG" ]; then
  cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.reset-backup-$(date +%Y%m%d%H%M%S)"
  CLAUDE_CONFIG="$CLAUDE_CONFIG" py_run <<'PYEOF'
import json, os, sys
p = os.environ["CLAUDE_CONFIG"]
try:
    cfg = json.load(open(p, encoding="utf-8"))
except Exception as e:
    print("  ! config okunamadı:", e); sys.exit(0)

servers = cfg.get("mcpServers", {})
# İsimden değil, GERÇEKTE NE ÇALIŞTIRDIĞINDAN tanı — eski/yeni tüm sürümleri yakalar
SIGNATURES = ("adb-mcp", "@alisaitteke/photoshop-mcp", "ps-mcp.py",
              "ai-mcp.py", "id-mcp.py", "pr-mcp.py", "ae-mcp.py",
              "Application Support/GokAI")

removed = []
for name in list(servers):
    blob = json.dumps(servers[name], ensure_ascii=False)
    if name.startswith("GokAI ") or any(s in blob for s in SIGNATURES):
        del servers[name]
        removed.append(name)

if removed:
    json.dump(cfg, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    for r in removed:
        print(f"  \033[32m✓\033[0m silindi: {r}")
    print(f"  \033[32m✓\033[0m korunan diğer sunucular: {list(servers.keys()) or '(yok)'}")
else:
    print("  \033[90m·\033[0m temizlenecek girdi yok")
PYEOF
  ok "yedek alındı: claude_desktop_config.json.reset-backup-*"
else
  skip "Claude yapılandırması bulunamadı"
fi

# ---------------------------------------------------------- 3. CEP eklentileri ---
step "3/8 CEP eklentileri (Illustrator / Premiere Pro / After Effects)"
FOUND=0
for ext in com.mikechambers.ai com.mikechambers.ae MCPBridgeCEP games.engine-room.ae-mcp; do
  if [ -e "$CEP_DIR/$ext" ] || [ -L "$CEP_DIR/$ext" ]; then
    rm -rf "$CEP_DIR/$ext"; ok "kaldırıldı: $ext"; FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && skip "CEP eklentisi bulunamadı"
[ -d "$CEP_DIR" ] && ok "diğer eklentilerine dokunulmadı: $(ls "$CEP_DIR" 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------- 4. UXP eklentileri ---
step "4/8 UXP eklentileri (Photoshop / InDesign)"
FOUND=0
if [ -d "$UXP_DIR/Plugins/External" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    rm -rf "$d"; ok "kaldırıldı: $(basename "$d")"; FOUND=1
  done < <(find "$UXP_DIR/Plugins/External" -maxdepth 1 -iname "*MCP Agent*" 2>/dev/null)
fi
# Eklenti verileri (kayıtlı Connect on Launch tercihi vb.)
while IFS= read -r d; do
  [ -z "$d" ] && continue
  rm -rf "$d"; FOUND=1
done < <(find "$UXP_DIR/PluginsStorage" -maxdepth 3 -iname "*MCP Agent*" 2>/dev/null)
[ "$FOUND" -eq 0 ] && skip "UXP eklentisi bulunamadı" || ok "eklenti verileri de temizlendi"

# UXP kayıt defteri: dosyayı silme — sadece BİZİM girdileri çıkar
if [ -d "$UXP_DIR/PluginsInfo/v1" ]; then
  UXP_V1="$UXP_DIR/PluginsInfo/v1" py_run <<'PYEOF'
import json, os, glob
d = os.environ["UXP_V1"]
for f in glob.glob(os.path.join(d, "*.json")):
    try:
        data = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    plugins = data.get("plugins")
    if not isinstance(plugins, list):
        continue
    keep = [p for p in plugins if "MCP Agent" not in json.dumps(p, ensure_ascii=False)]
    if len(keep) == len(plugins):
        continue
    if keep:
        data["plugins"] = keep
        json.dump(data, open(f, "w", encoding="utf-8"))
        print(f"  \033[32m✓\033[0m kayıt temizlendi: {os.path.basename(f)} (diğer eklentiler korundu)")
    else:
        os.remove(f)
        print(f"  \033[32m✓\033[0m kayıt silindi: {os.path.basename(f)}")
PYEOF
fi

# ------------------------------------------------------- 5. UDT çalışma alanı ---
step "5/8 UXP Developer Tools listesi"
if [ -f "$UDT_WS" ]; then
  UDT_WS="$UDT_WS" py_run <<'PYEOF'
import json, os
p = os.environ["UDT_WS"]
try:
    d = json.load(open(p, encoding="utf-8"))
except Exception:
    raise SystemExit
plugins = d.get("plugins", [])
keep = [x for x in plugins
        if "adb-mcp" not in x.get("manifestPath", "")
        and "Application Support/GokAI" not in x.get("manifestPath", "")]
if len(keep) != len(plugins):
    d["plugins"] = keep
    json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
    print(f"  \033[32m✓\033[0m {len(plugins) - len(keep)} girdi listeden çıkarıldı")
else:
    print("  \033[90m·\033[0m temizlenecek girdi yok")
PYEOF
else
  skip "UDT listesi bulunamadı"
fi

# ------------------------------------------------------------- 6. GokAI dosyaları ---
step "6/8 GokAI dosyaları"
[ -d "$GOKAI_DIR" ] && { rm -rf "$GOKAI_DIR"; ok "kaldırıldı: ~/Library/Application Support/GokAI"; } || skip "GokAI klasörü yok"
[ -d "$HOME/Applications/GokAI.app" ] && { rm -rf "$HOME/Applications/GokAI.app"; ok "kaldırıldı: GokAI.app"; } || skip "GokAI.app yok"
rm -f "$HOME/Library/Logs/gokai-proxy.log" "$HOME/Library/Logs/gokai-proxy.error.log" \
      "$HOME/Library/Logs/gokai-install.log" 2>/dev/null
ok "günlük dosyaları temizlendi"

# ------------------------------------------------- 7. Eski elle kurulum artıkları ---
step "7/8 Eski elle kurulum artıkları"
FOUND=0
for d in "$HOME/mcp-servers/adb-mcp" "$HOME/adb-mcp" "$HOME/Documents/adb-mcp" "$HOME/Desktop/adb-mcp"; do
  if [ -d "$d/adb-proxy-socket" ] || [ -d "$d/uxp" ]; then
    rm -rf "$d"; ok "kaldırıldı: $d"; FOUND=1
  fi
done
# İndirilmiş eklenti paketleri
for f in "$HOME/Downloads"/*MCP*.ccx "$HOME/Desktop"/*MCP*.ccx "$HOME/Downloads/Photoshop_MCP_Agent.ccx"; do
  [ -f "$f" ] && { rm -f "$f"; ok "kaldırıldı: $(basename "$f")"; FOUND=1; }
done
[ "$FOUND" -eq 0 ] && skip "eski artık bulunamadı"

# --------------------------------------------------------------- 8. Doğrulama ---
step "8/8 Doğrulama"
CLEAN=1
[ -d "$GOKAI_DIR" ] && { warn "GokAI klasörü hâlâ duruyor"; CLEAN=0; }
[ -f "$PLIST" ] && { warn "launchd plist hâlâ duruyor"; CLEAN=0; }
[ -n "$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)" ] && { warn "$PORT portu hâlâ dolu"; CLEAN=0; }
[ -e "$CEP_DIR/com.mikechambers.ai" ] && { warn "CEP eklentisi hâlâ duruyor"; CLEAN=0; }
[ "$CLEAN" -eq 1 ] && ok "her şey temiz"

if [ "$DO_INSTALL" -eq 1 ]; then
  step "Temiz kurulum başlatılıyor"
  # reset zaten uygulama kontrolünü yaptı; install tekrar sormasın.
  # Betik yukarıda (silmeden önce) indirildi.
  bash "$INSTALL_SCRIPT" --force </dev/null
  CODE=$?
  rm -f "$INSTALL_SCRIPT"
  exit $CODE
fi

printf "\n\033[1;32mSıfırlama tamamlandı.\033[0m\n\n"
echo "Temiz kurulum için:"
echo "  curl -fsSL $INSTALL_URL | bash"
echo ""
echo "Not: Homebrew ile kurulu node/uv ve diğer eklentilerin korundu."
echo "     Claude yapılandırmasının yedeği alındı (.reset-backup-*)."
echo ""
