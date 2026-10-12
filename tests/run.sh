#!/bin/bash
#
# GokAI testleri — yayınlamadan önce çalıştır.
#
#   bash tests/run.sh
#
# Gerçek kuruluma DOKUNMAZ: sahte bir ev klasörüne test modunda kurar (launchd,
# Adobe ve Claude ayarları atlanır; proxy 3907 portunda çalışır) ve her şeyi o
# kurulum üzerinde dener. İlk çalıştırma ~450 MB indirir; aynı klasörü yeniden
# kullanmak için:
#
#   GOKAI_SANDBOX_HOME=/tmp/gokai-test bash tests/run.sh
#
# Ne dener:
#   install   kurulum senaryoları: yeniden çalıştırma, internet kesintisi, bozuk
#             Claude ayarı, yarıda kesilme, kesilmiş yer değiştirmeyi geri alma
#             + normal Photoshop'lu makinede UXP eklenti adımı (sahte Adobe
#             kurucusuyla: başarı, hata kodu, Photoshop açık/eski, takılma)
#   proxy     gerçek MCP sunucusu → proxy → sahte eklenti: kopma, çift kayıt,
#             hatalı paket, yabancı kaynak, proxy'nin kendiliğinden başlatılması
#   offline   sunucular ağ erişimi tamamen kapalıyken açılıyor mu
#   launchd   servis yüklü değil / takılmış / devre dışı iken kurtarma
#             (kullanıcının launchd alanına geçici "com.gokai.proxy-test" yükler)
#   panel     Illustrator panelinin bağlantı mantığı, gerçek bir Chromium'da
#             (isteğe bağlı: GOKAI_TEST_PUPPETEER ve GOKAI_TEST_CHROME gerekir)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(dirname "$HERE")"
PORT=3907

stop_proxy() {
  local p
  for p in $({ lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true; } | sort -u); do kill "$p" 2>/dev/null; done
  sleep 0.5
}

export GOKAI_SANDBOX_HOME="${GOKAI_SANDBOX_HOME:-$(mktemp -d "${TMPDIR:-/tmp}/gokai-sandbox.XXXXXX")}"
H="$GOKAI_SANDBOX_HOME"
G="$H/Library/Application Support/GokAI"
mkdir -p "$H"

printf "\n\033[1m[GokAI testleri]\033[0m sandbox: %s\n" "$H"
stop_proxy
# Depodaki güncel dosyaları sandbox'a kur (kuruluysa saniyeler sürer).
if ! ( cd "$R" && HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT bash install.sh ) >"$H/install-for-tests.log" 2>&1; then
  echo "  Sandbox kurulumu başarısız — günlük: $H/install-for-tests.log"
  sed 's/\x1b\[[0-9;]*m//g' "$H/install-for-tests.log" | grep -E "✗|adım:" | head -5
  exit 1
fi
stop_proxy
NODE="$G/node/bin/node"

FAILED=""
run() { # ad komut...
  local name="$1"; shift
  printf "\n\033[1;35m━━ %s\033[0m\n" "$name"
  if "$@"; then :; else FAILED="$FAILED $name"; fi
  stop_proxy
}

run install bash "$HERE/install.test.sh"
run proxy   "$NODE" "$HERE/proxy.test.js"
run offline "$NODE" "$HERE/offline.test.js"
run launchd "$NODE" "$HERE/launchd.test.js"
run panel   "$NODE" "$HERE/panel.test.js"

echo ""
if [ -z "$FAILED" ]; then
  printf "\033[1;32mTüm test takımları geçti.\033[0m\n\n"
  exit 0
fi
printf "\033[1;31mBaşarısız:%s\033[0m\n\n" "$FAILED"
exit 1
