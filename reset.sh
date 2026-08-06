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

DO_INSTALL=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --force)   FORCE=1 ;;
  esac
done

INSTALL_URL="https://raw.githubusercontent.com/gokay12/gokai/main/install.sh"
GOKAI_DIR="$HOME/Library/Application Support/GokAI"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PLIST="$HOME/Library/LaunchAgents/com.gokai.proxy.plist"
CEP_DIR="$HOME/Library/Application Support/Adobe/CEP/extensions"
UXP_DIR="$HOME/Library/Application Support/Adobe/UXP"
UDT_WS="$HOME/Library/Application Support/Adobe/Adobe UXP Developer Tool/plugins_workspace.json"

step() { printf "\n\033[1;35m[GokAI]\033[0m \033[1m%s\033[0m\n" "$1"; }
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

if [ -n "$RUNNING" ] && [ "$FORCE" -eq 0 ]; then
  warn "Şu uygulamalar açık:$RUNNING"
  echo ""
  echo "  Eklentiler açık uygulamalardan temizlenemez."
  echo "  Lütfen bunları kapatıp betiği tekrar çalıştırın."
  echo "  (Yine de devam etmek için sonuna --force ekleyin.)"
  exit 1
fi
[ -z "$RUNNING" ] && ok "Adobe uygulamaları ve Claude kapalı" || warn "--force ile devam ediliyor"

# --------------------------------------------------------- 1. Arka plan servisi ---
step "1/8 Arka plan servisi durduruluyor"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  ok "launchd servisi kaldırıldı (com.gokai.proxy)"
else
  skip "launchd servisi zaten yok"
fi

# 3001 portunda kalan süreçler (elle başlatılmış eski proxy'ler dahil)
PIDS="$(lsof -tiTCP:3001 -sTCP:LISTEN 2>/dev/null)"
if [ -n "$PIDS" ]; then
  echo "$PIDS" | xargs kill 2>/dev/null
  sleep 1
  ok "3001 portundaki süreçler durduruldu"
else
  skip "3001 portu zaten boş"
fi

# ---------------------------------------------------- 2. Claude Desktop config ---
step "2/8 Claude Desktop yapılandırması temizleniyor"
if [ -f "$CLAUDE_CONFIG" ]; then
  cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.reset-backup-$(date +%Y%m%d%H%M%S)"
  CLAUDE_CONFIG="$CLAUDE_CONFIG" /usr/bin/python3 <<'PYEOF'
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
step "3/8 CEP eklentileri (Illustrator / After Effects)"
FOUND=0
for ext in com.mikechambers.ai com.mikechambers.ae; do
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
  UXP_V1="$UXP_DIR/PluginsInfo/v1" /usr/bin/python3 <<'PYEOF'
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
  UDT_WS="$UDT_WS" /usr/bin/python3 <<'PYEOF'
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
rm -f "$HOME/Library/Logs/gokai-proxy.log" "$HOME/Library/Logs/gokai-proxy.error.log" 2>/dev/null
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
lsof -tiTCP:3001 -sTCP:LISTEN >/dev/null 2>&1 && { warn "3001 portu hâlâ dolu"; CLEAN=0; }
[ -e "$CEP_DIR/com.mikechambers.ai" ] && { warn "CEP eklentisi hâlâ duruyor"; CLEAN=0; }
[ "$CLEAN" -eq 1 ] && ok "her şey temiz"

if [ "$DO_INSTALL" -eq 1 ]; then
  step "Temiz kurulum başlatılıyor"
  curl -fsSL "$INSTALL_URL" | bash
  exit $?
fi

printf "\n\033[1;32mSıfırlama tamamlandı.\033[0m\n\n"
echo "Temiz kurulum için:"
echo "  curl -fsSL $INSTALL_URL | bash"
echo ""
echo "Not: Homebrew ile kurulu node/uv ve diğer eklentilerin korundu."
echo "     Claude yapılandırmasının yedeği alındı (.reset-backup-*)."
echo ""
