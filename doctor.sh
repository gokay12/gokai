#!/bin/bash
#
# GokAI Doktor — bir makinede neyin çalışmadığını bulur
#
# Kullanım (sorun yaşayan makinede):
#   curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/doctor.sh | bash
#
# Hiçbir şeyi değiştirmez; yalnızca kontrol eder ve rapor verir:
#   - kurulum dosyaları, Node, kilitli Python ortamı
#   - arka plan servisi (launchd), 3001 portu
#   - Claude Desktop yapılandırması
#   - MCP sunucularını Claude'un yaptığı gibi GERÇEKTEN başlatıp dener
#   - Adobe eklentileri ve canlı bağlantı durumu
#   - Claude'un günlüklerindeki bilinen hata imzaları
#
# Seçenekler:
#   --json     makine tarafından okunabilir çıktı
#   --quick    MCP sunucularını başlatma, günlükleri tarama (hızlı)
#
# Eski (v1.x) ve yarım kalmış kurulumlarda da çalışır: tanı betiğinin en güncel
# halini indirir, indiremezse kurulu kopyayı kullanır.

set -uo pipefail

RAW="${GOKAI_RAW_URL:-https://raw.githubusercontent.com/gokay12/gokai/main}"
GOKAI_DIR="$HOME/Library/Application Support/GokAI"
INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash"

warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m \033[1m%s\033[0m\n" "$1"; }

# --- Node bul: önce GokAI'nin kendi kopyası, yoksa sistemdeki ------------------
NODE=""
if [ -x "$GOKAI_DIR/node/bin/node" ] && "$GOKAI_DIR/node/bin/node" -v >/dev/null 2>&1 </dev/null; then
  NODE="$GOKAI_DIR/node/bin/node"
else
  for c in /opt/homebrew/bin/node /usr/local/bin/node "$(command -v node 2>/dev/null || true)"; do
    if [ -n "$c" ] && [ -x "$c" ] && "$c" -e 'process.exit(parseInt(process.versions.node) >= 18 ? 0 : 1)' >/dev/null 2>&1 </dev/null; then
      NODE="$c"; break
    fi
  done
fi

if [ -z "$NODE" ]; then
  # Node yoksa ayrıntılı tanı çalışamaz; yine de en temel durumu söyle.
  printf "\n\033[1m  GokAI Doktor\033[0m\n\n"
  if [ ! -d "$GOKAI_DIR" ]; then
    bad "GokAI bu makinede kurulu değil"
  else
    bad "GokAI klasörü var ama Node.js kopyası eksik ya da bozuk"
    echo "      $GOKAI_DIR/node/bin/node"
  fi
  [ -f "$HOME/Library/LaunchAgents/com.gokai.proxy.plist" ] || warn "Otomatik başlatma kaydı yok"
  if curl -fsS --max-time 3 http://127.0.0.1:3001/status >/dev/null 2>&1 </dev/null; then
    warn "3001 portunda bir proxy yanıt veriyor (eski bir kurulumdan kalmış olabilir)"
  else
    warn "3001 portunda proxy yanıt vermiyor"
  fi
  echo ""
  echo "  Çözüm — Claude Desktop, Photoshop ve Illustrator'ı kapatıp şunu çalıştırın:"
  printf "    \033[36m%s\033[0m\n\n" "$INSTALL_CMD"
  exit 1
fi

# --- Tanı betiği: en güncel hali, olmazsa kurulu kopya -------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gokai-doctor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
DOCTOR_JS=""

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$HERE" ] && [ -f "$HERE/gokai-doctor.js" ] && [ -f "$HERE/gokai-proxy.js" ]; then
  # Repo içinden çalıştırılıyor (geliştirme)
  DOCTOR_JS="$HERE/gokai-doctor.js"
elif curl -fsSL --connect-timeout 8 --max-time 30 "$RAW/gokai-doctor.js" -o "$TMP/gokai-doctor.js" 2>/dev/null </dev/null \
     && "$NODE" --check "$TMP/gokai-doctor.js" >/dev/null 2>&1 </dev/null; then
  DOCTOR_JS="$TMP/gokai-doctor.js"
elif [ -f "$GOKAI_DIR/proxy/gokai-doctor.js" ]; then
  DOCTOR_JS="$GOKAI_DIR/proxy/gokai-doctor.js"
  warn "Güncel tanı betiği indirilemedi (internet?) — kurulu kopya kullanılıyor"
else
  printf "\n\033[1m  GokAI Doktor\033[0m\n\n"
  bad "Tanı betiği indirilemedi ve bu makinede kurulu bir kopyası yok"
  echo "      İnternet bağlantısını kontrol edip tekrar deneyin."
  echo ""
  exit 2
fi

COLOR=""
[ -t 1 ] && COLOR="--color"
"$NODE" "$DOCTOR_JS" $COLOR "$@" </dev/null
exit $?
