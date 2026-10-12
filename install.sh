#!/bin/bash
#
# GokAI Kurulum — Adobe MCP köprüsü (Photoshop / Illustrator)
#
# Kullanım (arkadaşların çalıştıracağı tek satır):
#   curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash
#
# Ne yapar:
#   1. Kendi özel Node.js kopyasını indirir (sisteme dokunmaz, sudo istemez)
#   2. Kendi özel uv + Python 3.12 kopyasını indirir
#   3. adb-mcp'yi SABİT bir sürümden indirir, Illustrator eklentisini çevrimdışı
#      çalışacak şekilde hazırlar
#   4. MCP sunucuları için KİLİTLİ ortamları kurar (Python: requirements.lock,
#      Photoshop: package-lock.json) — Claude açılırken hiçbir şey internetten
#      çözülmez
#   5. Yeni kurulumu yerine koymadan önce sunucuları gerçekten başlatıp dener
#   6. Proxy'yi kurar, oturum açılışında otomatik başlatır (launchd)
#   7. Claude Desktop yapılandırmasına MCP sunucularını ekler (mevcut ayarları BOZMAZ)
#   8. Illustrator CEP eklentisini ve (Beta olmayan) Photoshop UXP eklentisini kurar
#   9. ~/Applications içine GokAI.app kısayolu koyar (durum panelini açar)
#  10. Doktoru çalıştırıp her şeyi uçtan uca doğrular
#
# Yarıda kesilen ya da başarısız olan bir kurulum, çalışan mevcut kurulumu bozmaz:
# her şey önce geçici bir klasörde hazırlanır ve denenir, sonra yerine konur.
#
# Photoshop Beta olan makinelerde UXP eklentisi kurulamaz; betik bunu algılar ve
# yalnızca AppleScript tabanlı sunucuyu ekler (Beta'da tam çalışır).

# NOT: `set -E` + ERR tuzağı KULLANMA. O tuzak $(...) alt kabuklarında da çalışır;
# içinde temizlik yapan bir tuzak, zararsız bir komut (ör. sonuç bulamayan lsof)
# yüzünden hazırlık klasörünü kurulumun ortasında siler. Aşağıda EXIT tuzağı var:
# yalnızca ana kabukta ve yalnızca bir kez çalışır.
set -euo pipefail

GOKAI_VERSION="2.0.1"

# ------------------------------------------------- sabitlenmiş sürümler ---
# Buradaki her şey bilinçli olarak sabit. Yükseltmek için README'deki
# "Sürümleri yükseltme" bölümüne bak; rastgele değiştirme.
NODE_VERSION="v22.14.0"
NODE_SHA256_ARM64="e9404633bc02a5162c5c573b1e2490f5fb44648345d64a958b17e325729a5e42"
NODE_SHA256_X64="6698587713ab565a94a360e091df9f6d91c8fadda6d00f0cf6526e9b40bed250"

UV_VERSION="0.12.24"
UV_SHA256_ARM64="0c4346de7abdb49495b393b9ec809fe387aa43e586be20fecb972216c1e71732"
UV_SHA256_X64="4fa82e37cb94767661f532b001e470b67a186c7260e305bd84ddb78fd545c0b6"

# --python ZORUNLU: sistemdeki Python (macOS 3.9.6 ile gelir) adb-mcp için eski.
PYTHON_VERSION="3.12"

# adb-mcp "main" dalı yerine belirli bir commit: upstream'deki bir değişiklik
# yeni kurulumları habersizce bozamasın.
ADB_MCP_COMMIT="afe5d09cdbdd4cc60434dce6b3f46fdafe15a21c"
# cep/ klasöründeki dosyalar upstream'in şu iki dosyasının YERİNE geçer. Commit
# değişip de upstream dosyaları farklılaşırsa kurulum durur: önce cep/ altındaki
# sürümleri yeni upstream ile karşılaştır.
CEP_UPSTREAM_MAIN_SHA256="dfaae854f26ad03f973e1cb8fdcadff3e9d57a125116ec79ceabedfbce5416fb"
CEP_UPSTREAM_INDEX_SHA256="d347e76a1e652523fe600564d6e2a0ee3b1a4b1424475d637f30f81ad23cefbb"

PS_CCX_URL="https://github.com/mikechambers/adb-mcp/releases/download/v0.85.4/Photoshop.MCP.Agent_PS.ccx"
PS_PLUGIN_NAME="Photoshop MCP Agent"
# .ccx içindeki manifest: host.minVersion 26.0.0 — eklenti Photoshop 2025 (26) ve üzerinde yüklenir.
PS_PLUGIN_MIN_MAJOR=26

# ---------------------------------------------------------------- ayarlar ---
FORCE=0
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1; fi
done

# Test modu (GOKAI_TEST_MODE=1): launchd, Adobe ve tarayıcıya dokunmaz; proxy'yi
# GOKAI_PORT üzerinde doğrudan başlatır. Sahte bir HOME ile uçtan uca denemek için.
TEST_MODE="${GOKAI_TEST_MODE:-0}"
if [ "$TEST_MODE" = "1" ]; then
  # Test modu gerçek proxy'nin portunu (3001) asla kullanmaz.
  PORT="${GOKAI_PORT:-3907}"
  if [ "$PORT" = "3001" ]; then echo "Test modunda GOKAI_PORT 3001 olamaz (gerçek servisin portu)."; exit 1; fi
else
  PORT=3001
  unset GOKAI_DIR GOKAI_PORT GOKAI_CLAUDE_CONFIG GOKAI_CLAUDE_LOG_DIR GOKAI_NO_AUTOSTART || true
fi

GOKAI_REPO_TARBALL="${GOKAI_REPO_TARBALL:-https://codeload.github.com/gokay12/gokai/tar.gz/refs/heads/main}"
ADB_MCP_TARBALL="https://codeload.github.com/mikechambers/adb-mcp/tar.gz/${ADB_MCP_COMMIT}"

GOKAI_DIR="$HOME/Library/Application Support/GokAI"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PLIST="$HOME/Library/LaunchAgents/com.gokai.proxy.plist"
LOG_DIR="$HOME/Library/Logs"
ILOG="$LOG_DIR/gokai-install.log"
STAGE="$GOKAI_DIR/.stage"
ROOT="$STAGE/root"          # yeni kurulumun, yerine konmadan önceki hali
SERVICE="com.gokai.proxy"

# Yerel mod: betik, gokai-proxy.js'in yanından çalıştırılırsa repo indirilmez
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { CURRENT_STEP="$1"; printf "\n\033[1;35m[GokAI]\033[0m \033[1m%s\033[0m\n" "$1"; echo "=== $(date '+%H:%M:%S') $1" >>"$ILOG"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
skip() { printf "  \033[90m·\033[0m %s\n" "$1"; }

# Yeni dosyalar yerine kondu mu? (Hata iletilerinin doğru olması için.)
APPLIED=0
# Hata iletisi zaten basıldı mı? (fail, kullanıcı kesmesi ya da bilinçli çıkış)
HANDLED=0
CURRENT_STEP="hazırlık"
SPIN_PID=""

aftermath() {
  echo "    Ayrıntılı günlük: $ILOG"
  if [ "$APPLIED" -eq 0 ]; then
    echo "    Mevcut kurulumunuza dokunulmadı; sorunu giderip aynı komutu yeniden çalıştırın."
  else
    echo "    Yeni dosyalar yerine kondu ama kurulum TAMAMLANMADI;"
    echo "    sorunu giderip aynı komutu yeniden çalıştırın."
  fi
  echo ""
}

# Anlaşılır bir nedenle dur. $1 = başlık, sonrakiler = açıklama satırları.
fail() {
  HANDLED=1
  printf "\n  \033[31m✗\033[0m \033[1m%s\033[0m\n" "$1"; shift
  for l in "$@"; do echo "    $l"; done
  echo ""
  aftermath
  exit 1
}

# Bir sürecin tüm alt süreçlerini (kendisi hariç) listeler.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$child"
    descendants "$child"
  done
}

# Bir süreci tüm alt süreçleriyle durdurur ve GERÇEKTEN bittiklerini bekler:
# npm kapanırken birkaç saniye daha dosya yazabiliyor; beklemeden hazırlık
# klasörünü silmek yarım bir klasör bırakır.
stop_tree() {
  local pids p alive="" i
  pids="$1 $(descendants "$1" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8; do
    alive=""
    for p in $pids; do
      if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; fi
    done
    if [ -z "$alive" ]; then return 0; fi
    sleep 0.5
  done
  # shellcheck disable=SC2086
  kill -9 $alive 2>/dev/null || true
  sleep 0.3
}

# Betik nasıl biterse bitsin (başarı, hata, Ctrl-C) ana kabukta bir kez çalışır:
# arka planda süren indirmeyi durdurur, hazırlık klasörünü siler ve beklenmeyen
# bir hatada nerede kalındığını söyler.
on_exit() {
  local code=$?
  trap - EXIT INT TERM
  set +e      # temizlik sırasındaki bir hata temizliği yarıda bırakmasın
  if [ -n "$SPIN_PID" ]; then
    disown "$SPIN_PID" 2>/dev/null || true     # kabuğun "Terminated" bildirimini bastır
    stop_tree "$SPIN_PID"
  fi
  if [ "$code" -ne 0 ] && [ "$HANDLED" -eq 0 ]; then
    printf "\n  \033[31m✗\033[0m \033[1mKurulum tamamlanamadı\033[0m — adım: %s (kod %s)\n" "$CURRENT_STEP" "$code"
    if [ -f "$ILOG" ]; then
      echo "    Günlüğün son satırları:"
      tail -n 12 "$ILOG" | sed 's/^/      /' || true
    fi
    aftermath
  fi
  rm -rf "$STAGE" 2>/dev/null || { sleep 1; rm -rf "$STAGE" 2>/dev/null || true; }
  exit "$code"
}
trap on_exit EXIT

# Ctrl-C: etkileşimsiz kabukta arka plan işleri Ctrl-C'yi yok sayar; on_exit onları da durdurur.
on_interrupt() {
  HANDLED=1
  printf "\n  Kurulum durduruldu.\n"
  if [ "$APPLIED" -eq 0 ]; then echo "  Mevcut kurulumunuza dokunulmadı."; fi
  exit 130
}
trap on_interrupt INT TERM

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Uzun süren bir komut çalışırken birkaç saniyede bir nokta bas: kullanıcı
# kurulumun takıldığını sanıp yarıda kesmesin. Komutun çıkış kodunu döndürür.
spin() {
  "$@" &
  local pid=$! n=0 code=0
  SPIN_PID="$pid"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    n=$((n + 1))
    if [ "$n" -eq 5 ]; then printf "    "; fi
    if [ $((n % 5)) -eq 0 ]; then printf "."; fi
  done
  if [ "$n" -ge 5 ]; then printf "\n"; fi
  wait "$pid" || code=$?
  SPIN_PID=""
  return "$code"
}

# İndir (yeniden denemeli); sha256 verilmişse doğrula. Yarım dosya bırakmaz.
fetch() { # url hedef [sha256]
  local url="$1" dest="$2" want="${3:-}" i got
  for i in 1 2 3; do
    if curl -fL --silent --show-error --connect-timeout 20 --max-time 900 \
            -o "$dest.part" "$url" </dev/null 2>>"$ILOG"; then
      if [ -n "$want" ]; then
        got="$(sha256_of "$dest.part")"
        if [ "$got" != "$want" ]; then
          echo "sha256 uyuşmadı ($url): beklenen $want, gelen $got" >>"$ILOG"
          rm -f "$dest.part"; sleep 2; continue
        fi
      fi
      mv "$dest.part" "$dest"
      return 0
    fi
    echo "indirme denemesi $i başarısız: $url" >>"$ILOG"
    rm -f "$dest.part"; sleep 3
  done
  return 1
}

net_fail() { # ne indirilemedi
  fail "$1 indirilemedi" \
       "İnternet bağlantısını kontrol edin (VPN / kurumsal ağ / güvenlik yazılımı engelliyor olabilir)." \
       "Ardından aynı komutu yeniden çalıştırın."
}

# Hazırlanan bileşeni yerine koy (aynı disk üzerinde yeniden adlandırma: anlık).
# Yenisi yerine oturmazsa eskisini geri koyar: bileşensiz kalınmaz.
swap_in() { # hazırlanan  hedef
  local staged="$1" final="$2" old="$2.old-$$"
  [ -e "$staged" ] || fail "İç hata: hazırlanan bileşen bulunamadı" "$staged"
  if [ -e "$final" ] || [ -L "$final" ]; then mv "$final" "$old"; fi
  if ! mv "$staged" "$final"; then
    if [ -e "$old" ] || [ -L "$old" ]; then mv "$old" "$final" || true; fi
    fail "Bileşen yerine konamadı (eskisi geri yüklendi)" "$final"
  fi
  rm -rf "$old"
}

mkdir -p "$LOG_DIR"
# Kurulum günlüğü sınırsız büyümesin
if [ -f "$ILOG" ] && [ "$(wc -c <"$ILOG")" -gt 524288 ]; then
  tail -c 131072 "$ILOG" >"$ILOG.tmp" && mv "$ILOG.tmp" "$ILOG"
fi
{ echo ""; echo "##### GokAI $GOKAI_VERSION kurulumu — $(date '+%Y-%m-%d %H:%M:%S') #####"; } >>"$ILOG"

bold ""
bold "  ██████╗  ██████╗ ██╗  ██╗ █████╗ ██╗"
bold " ██╔════╝ ██╔═══██╗██║ ██╔╝██╔══██╗██║"
bold " ██║  ███╗██║   ██║█████╔╝ ███████║██║"
bold " ██║   ██║██║   ██║██╔═██╗ ██╔══██║██║"
bold " ╚██████╔╝╚██████╔╝██║  ██╗██║  ██║██║"
bold "  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝"
bold "  Adobe MCP Köprüsü — Kurulum v$GOKAI_VERSION"

# ------------------------------------------------------------- ön kontroller ---
[ "$(uname -s)" = "Darwin" ] || fail "Bu kurulum yalnızca macOS içindir."
for tool in curl tar shasum awk sed; do
  command -v "$tool" >/dev/null 2>&1 || fail "Gerekli sistem aracı bulunamadı: $tool"
done

# Claude Desktop açıkken yapılandırma dosyasını düzenlemek GÜVENLİ DEĞİL:
# Claude kapanırken kendi bellekteki (eski) kopyasını dosyanın üzerine yazabiliyor
# ve kurulumda eklenen sunucular sessizce kayboluyor.
CLAUDE_RUNNING=0
if [ "$TEST_MODE" != "1" ]; then
  # NOT: `ps ... | grep -q` kullanma — grep erken çıkınca ps SIGPIPE alır ve
  # `set -o pipefail` yüzünden boru hattı başarısız sayılır.
  CLAUDE_PROC="$(ps -Ao comm= | grep 'Applications/Claude.app/Contents/MacOS/Claude$' || true)"
  if [ -n "$CLAUDE_PROC" ]; then CLAUDE_RUNNING=1; fi
fi
if [ "$CLAUDE_RUNNING" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  printf "\n  \033[33m!\033[0m \033[1mClaude Desktop açık.\033[0m\n\n"
  echo "  Claude açıkken yapılandırma düzenlenirse, Claude kapanırken eski"
  echo "  ayarlarını geri yazabilir ve kurulum boşa gider."
  echo ""
  printf "  Lütfen Claude Desktop uygulamasini \033[1mCmd+Q\033[0m ile kapatip tekrar calistirin.\n"
  echo "  (Yine de devam etmek için: ... | bash -s -- --force)"
  echo ""
  HANDLED=1
  exit 1
fi

# Gerçek işlemci mimarisi (Rosetta altındaki bir terminal x86_64 bildirir)
if [ "$TEST_MODE" = "1" ] && [ -n "${GOKAI_FORCE_ARCH:-}" ]; then
  ARCH="$GOKAI_FORCE_ARCH"
elif [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  ARCH="arm64"
elif [ "$(uname -m)" = "x86_64" ]; then
  ARCH="x64"
else
  fail "Desteklenmeyen işlemci mimarisi: $(uname -m)"
fi
if [ "$ARCH" = "arm64" ]; then
  NODE_ARCH="darwin-arm64"; NODE_SHA256="$NODE_SHA256_ARM64"
  UV_ARCH="aarch64-apple-darwin"; UV_SHA256="$UV_SHA256_ARM64"
else
  NODE_ARCH="darwin-x64"; NODE_SHA256="$NODE_SHA256_X64"
  UV_ARCH="x86_64-apple-darwin"; UV_SHA256="$UV_SHA256_X64"
fi

mkdir -p "$GOKAI_DIR" "$HOME/Applications" "$HOME/Library/LaunchAgents"

FREE_KB="$(df -k "$GOKAI_DIR" | awk 'NR==2 {print $4}')"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 2097152 ]; then
  fail "Diskte yeterli boş alan yok" \
       "Kurulum için en az 2 GB boş alan gerekir (şu an: $((FREE_KB / 1024)) MB)."
fi

# Önceki yarım kalmış denemelerin artıkları. Yer değiştirme tam ortasında
# kesildiyse (eski bileşen ".old-…" adında kalmış, yenisi yok) eskisini geri koy.
rm -rf "$STAGE" 2>/dev/null || true
for old in "$GOKAI_DIR"/*.old-* "$GOKAI_DIR"/proxy/*.old-*; do
  if [ ! -e "$old" ] && [ ! -L "$old" ]; then continue; fi   # eşleşme yok
  orig="${old%.old-*}"
  if [ -e "$orig" ] || [ -L "$orig" ]; then
    rm -rf "$old"
  else
    mv "$old" "$orig"
    echo "kesilmiş yer değiştirme geri alındı: $orig" >>"$ILOG"
  fi
done
mkdir -p "$ROOT"

# npm ve uv'yi kullanıcının kendi ayar/önbelleklerinden yalıt: bozuk bir ~/.npm
# ya da özel bir ~/.npmrc / uv.toml kurulumu etkilemesin.
CACHE_DIR="$GOKAI_DIR/.cache"
mkdir -p "$CACHE_DIR"
# (npm aynı dosyanın hem kullanıcı hem genel ayar olarak verilmesini reddediyor.)
: >"$STAGE/npmrc-user"
: >"$STAGE/npmrc-global"
export npm_config_cache="$CACHE_DIR/npm"
export npm_config_userconfig="$STAGE/npmrc-user"
export npm_config_globalconfig="$STAGE/npmrc-global"
export npm_config_registry="https://registry.npmjs.org/"
export npm_config_update_notifier=false
export npm_config_fund=false
export npm_config_audit=false

# ---------------------------------------------------- 1. GokAI dosyaları ---
step "1/10 GokAI dosyaları alınıyor"
SRC="$STAGE/src"
mkdir -p "$SRC"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/gokai-proxy.js" ]; then
  # Yerel mod (geliştirme / repo checkout'u)
  ( cd "$SCRIPT_DIR" && tar -cf - --exclude node_modules --exclude .git . ) | ( cd "$SRC" && tar -xf - )
  ok "Yerel dosyalar kullanılıyor: $SCRIPT_DIR"
else
  fetch "$GOKAI_REPO_TARBALL" "$STAGE/gokai.tar.gz" || net_fail "GokAI dosyaları"
  tar -xzf "$STAGE/gokai.tar.gz" -C "$SRC" --strip-components=1
  rm -f "$STAGE/gokai.tar.gz"
  ok "GokAI dosyaları indirildi"
fi
for f in gokai-proxy.js gokai-doctor.js package.json package-lock.json public/index.html \
         mcp/gokai_mcp.py mcp/requirements.lock cep/index.html cep/main.js \
         photoshop-mcp/package.json photoshop-mcp/package-lock.json; do
  [ -f "$SRC/$f" ] || fail "GokAI paketi eksik: $f bulunamadı" \
    "İndirme yarım kalmış ya da depo güncelleniyor olabilir. Birkaç dakika sonra tekrar deneyin."
done
# install.sh ile indirilen dosyalar aynı sürümden mi? (GitHub'ın ham dosya
# önbelleği birkaç dakika geriden gelebiliyor.)
grep -q "const VERSION = \"$GOKAI_VERSION\"" "$SRC/gokai-proxy.js" || fail \
  "Kurulum betiği ile indirilen dosyaların sürümü uyuşmuyor" \
  "GitHub önbelleği henüz güncellenmemiş olabilir. 5 dakika sonra tekrar deneyin."
PS_MCP_VERSION="$(awk -F'"' '/"@alisaitteke\/photoshop-mcp":/ {print $4; exit}' "$SRC/photoshop-mcp/package.json")"
[ -n "$PS_MCP_VERSION" ] || fail "photoshop-mcp sürümü okunamadı"

# Bundan sonraki hazırlık adımları (2-7) bir fonksiyonda: yeniden kullanılan bir
# bileşen bozuk çıkarsa her şey sıfırdan bir kez daha hazırlanabilsin.
#
# REUSE=1 iken, kilit dosyası değişmemiş ve yerinde duran bileşenler yeniden
# indirilmez (tekrar kurulum saniyeler sürer, internet gerektirmez).
REUSE=1
REUSED_ANY=0
NODE="$ROOT/node/bin/node"
NODE_DIR="$GOKAI_DIR/node"
UV_DIR="$GOKAI_DIR/uv"
PY_DIR="$GOKAI_DIR/python"
VENV="$GOKAI_DIR/venv"
ADB_DIR="$GOKAI_DIR/adb-mcp"
PS_DIR="$GOKAI_DIR/photoshop-mcp"
PS_ENTRY_REL="node_modules/@alisaitteke/photoshop-mcp/dist/index.js"
PROXY_LOCK_SHA="$(sha256_of "$SRC/package-lock.json")"
PY_LOCK_SHA="$(sha256_of "$SRC/mcp/requirements.lock")"
PS_LOCK_SHA="$(sha256_of "$SRC/photoshop-mcp/package-lock.json")"

run_npm() { ( cd "$1" && shift && PATH="$ROOT/node/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/node/bin/npm" "$@" </dev/null >>"$ILOG" 2>&1 ); }

# Sistemdeki uv ayarlarından, Python'lardan ve ortam değişkenlerinden yalıtılmış uv
run_uv() {
  env -u VIRTUAL_ENV -u PYTHONPATH -u PYTHONHOME -u UV_PYTHON -u UV_PROJECT_ENVIRONMENT \
      UV_NO_CONFIG=1 UV_NO_PROGRESS=1 UV_PYTHON_PREFERENCE=only-managed \
      UV_PYTHON_INSTALL_DIR="$PY_DIR" UV_CACHE_DIR="$CACHE_DIR/uv" UV_LINK_MODE=copy \
      "$ROOT/uv/uv" "$@" </dev/null >>"$ILOG" 2>&1
}

reuse() { # bileşen-adı  mevcut-yol  → $ROOT altına bağla
  ln -s "$2" "$ROOT/$1"
  REUSED_ANY=1
}

# Claude yapılandırması okunabiliyor mu? Bozuksa üzerine yazmak kullanıcının diğer
# MCP sunucularını siler; uzun indirmelere başlamadan ve hiçbir şeyi değiştirmeden dur.
check_claude_config() {
  [ -s "$CLAUDE_CONFIG" ] || return 0
  CLAUDE_CONFIG="$CLAUDE_CONFIG" "$NODE" -e '
    const fs = require("fs");
    const text = fs.readFileSync(process.env.CLAUDE_CONFIG, "utf8").replace(/^\uFEFF/, "").trim();
    if (!text) process.exit(0);
    let cfg;
    try { cfg = JSON.parse(text); } catch (e) { console.error(e.message); process.exit(3); }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) { console.error("kök nesne değil"); process.exit(3); }
  ' </dev/null 2>>"$ILOG" || fail "Claude yapılandırma dosyası bozuk (geçerli JSON değil)" \
    "$CLAUDE_CONFIG" \
    "Dosyayı bir metin düzenleyicide düzeltin ya da aynı klasördeki bir yedeği" \
    "(claude_desktop_config.json.gokai-backup-*) geri yükleyin, sonra kurulumu tekrar çalıştırın."
}

stage_all() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT"

  # ----------------------------------------------------------- 2. Node.js ---
  step "2/10 Node.js hazırlanıyor (özel kopya, sisteme dokunmaz)"
  if [ "$REUSE" -eq 1 ] && [ -x "$NODE_DIR/bin/node" ] \
     && [ "$("$NODE_DIR/bin/node" -v 2>/dev/null </dev/null || true)" = "$NODE_VERSION" ]; then
    reuse node "$NODE_DIR"
    ok "Zaten kurulu: $NODE_VERSION"
  else
    fetch "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-${NODE_ARCH}.tar.gz" \
          "$STAGE/node.tar.gz" "$NODE_SHA256" || net_fail "Node.js"
    mkdir -p "$ROOT/node"
    tar -xzf "$STAGE/node.tar.gz" -C "$ROOT/node" --strip-components=1
    rm -f "$STAGE/node.tar.gz"
    [ "$("$ROOT/node/bin/node" -v </dev/null)" = "$NODE_VERSION" ] || fail "İndirilen Node.js çalışmıyor"
    ok "Node $NODE_VERSION indirildi ($NODE_ARCH, sha256 doğrulandı)"
  fi
  check_claude_config

  # ------------------------------------------------------------- 3. Proxy ---
  step "3/10 GokAI proxy bağımlılıkları kuruluyor"
  mkdir -p "$ROOT/proxy"
  cp "$SRC/gokai-proxy.js" "$SRC/gokai-doctor.js" "$SRC/package.json" "$SRC/package-lock.json" "$ROOT/proxy/"
  cp -R "$SRC/public" "$ROOT/proxy/public"
  if [ "$REUSE" -eq 1 ] && [ -f "$GOKAI_DIR/proxy/node_modules/.gokai-lock-sha256" ] \
     && [ "$(cat "$GOKAI_DIR/proxy/node_modules/.gokai-lock-sha256")" = "$PROXY_LOCK_SHA" ] \
     && [ -f "$GOKAI_DIR/proxy/node_modules/socket.io-client/dist/socket.io.min.js" ]; then
    reuse proxy/node_modules "$GOKAI_DIR/proxy/node_modules"
    ok "Zaten kurulu (kilit dosyası değişmemiş)"
  else
    # npm ci: package-lock.json'daki sürümleri birebir kurar, başka bir şey çözmez.
    run_npm "$ROOT/proxy" ci --omit=dev --no-audit --no-fund --loglevel=error || net_fail "Proxy bağımlılıkları (npm)"
    echo "$PROXY_LOCK_SHA" >"$ROOT/proxy/node_modules/.gokai-lock-sha256"
    ok "express + socket.io kuruldu (kilitli sürümler)"
  fi
  SOCKETIO_CLIENT="$ROOT/proxy/node_modules/socket.io-client/dist/socket.io.min.js"
  [ -f "$SOCKETIO_CLIENT" ] || fail "Socket.IO istemci dosyası bulunamadı"

  # ------------------------------------------------------ 4. uv + Python ---
  step "4/10 Python $PYTHON_VERSION hazırlanıyor (özel kopya)"
  local uv_have=""
  if [ "$REUSE" -eq 1 ] && [ -x "$UV_DIR/uv" ]; then
    uv_have="$("$UV_DIR/uv" --version 2>/dev/null </dev/null || true)"
  fi
  case "$uv_have" in
    "uv $UV_VERSION "*)
      reuse uv "$UV_DIR" ;;
    *)
      fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
            "$STAGE/uv.tar.gz" "$UV_SHA256" || net_fail "uv"
      mkdir -p "$ROOT/uv"
      tar -xzf "$STAGE/uv.tar.gz" -C "$ROOT/uv" --strip-components=1
      rm -f "$STAGE/uv.tar.gz"
      "$ROOT/uv/uv" --version </dev/null >>"$ILOG" 2>&1 || fail "İndirilen uv çalışmıyor" ;;
  esac
  # --no-bin: ~/.local/bin içine python kısayolu KOYMA (sisteme dokunmuyoruz).
  # Python doğrudan son yerine kurulur: klasör eklemelidir, mevcut ortamı bozmaz.
  spin run_uv python install --no-bin "$PYTHON_VERSION" || net_fail "Python $PYTHON_VERSION"
  ok "uv $UV_VERSION + Python $PYTHON_VERSION hazır (yalnızca GokAI klasöründe)"

  # ------------------------------------------------ 5. Kilitli Python ortamı ---
  step "5/10 Kilitli Python ortamı kuruluyor"
  if [ "$REUSE" -eq 1 ] && [ -f "$VENV/.gokai-lock-sha256" ] \
     && [ "$(cat "$VENV/.gokai-lock-sha256")" = "$PY_LOCK_SHA" ] \
     && "$VENV/bin/python" -I -c "import mcp, pydantic, numpy, PIL, socketio" </dev/null >>"$ILOG" 2>&1; then
    reuse venv "$VENV"
    ok "Zaten kurulu (kilit dosyası değişmemiş)"
  else
    # --relocatable: ortam geçici klasörde hazırlanıp sonra yerine taşınıyor.
    run_uv venv --relocatable --python "$PYTHON_VERSION" "$ROOT/venv" || fail "Python ortamı oluşturulamadı"
    # --require-hashes: her paket kilit dosyasındaki hash ile doğrulanır.
    # --only-binary:   derleme gerektiren kaynak paketine asla düşme (tasarımcı
    #                  makinelerinde derleyici yok; sessizce başarısız olmasın).
    spin run_uv pip sync --python "$ROOT/venv/bin/python" --require-hashes --only-binary :all: \
           "$SRC/mcp/requirements.lock" || net_fail "Python paketleri"
    echo "$PY_LOCK_SHA" >"$ROOT/venv/.gokai-lock-sha256"
    ok "$(grep -c -E '^[A-Za-z0-9_.-]+==' "$SRC/mcp/requirements.lock") paket kuruldu (sürüm + hash kilitli)"
  fi
  mkdir -p "$ROOT/mcp"
  cp "$SRC/mcp/gokai_mcp.py" "$SRC/mcp/requirements.lock" "$ROOT/mcp/"

  # ----------------------------------------------------------- 6. adb-mcp ---
  step "6/10 adb-mcp hazırlanıyor (sabit sürüm ${ADB_MCP_COMMIT:0:7})"
  if [ "$REUSE" -eq 1 ] && [ -f "$ADB_DIR/.gokai-commit" ] \
     && [ "$(cat "$ADB_DIR/.gokai-commit")" = "$ADB_MCP_COMMIT" ] \
     && [ -f "$ADB_DIR/mcp/ai-mcp.py" ] && [ -f "$ADB_DIR/cep/com.mikechambers.ai/commands.js" ]; then
    # Aynı sürüm duruyor: kopyasını al, eklenti dosyalarını aşağıda yeniden uygula.
    cp -R "$ADB_DIR" "$ROOT/adb-mcp"
    REUSED_ANY=1
    ok "Zaten indirilmiş"
  else
    fetch "$ADB_MCP_TARBALL" "$STAGE/adb-mcp.tar.gz" || net_fail "adb-mcp"
    mkdir -p "$ROOT/adb-mcp"
    tar -xzf "$STAGE/adb-mcp.tar.gz" -C "$ROOT/adb-mcp" --strip-components=1
    rm -f "$STAGE/adb-mcp.tar.gz"
    local f
    for f in mcp/ai-mcp.py mcp/ps-mcp.py mcp/core.py mcp/socket_client.py mcp/fonts.py mcp/logger.py \
             cep/com.mikechambers.ai/CSXS/manifest.xml cep/com.mikechambers.ai/commands.js \
             cep/com.mikechambers.ai/main.js cep/com.mikechambers.ai/index.html \
             cep/com.mikechambers.ai/lib/CSInterface.js; do
      [ -f "$ROOT/adb-mcp/$f" ] || fail "adb-mcp paketi eksik: $f bulunamadı"
    done
    # Yerine koyacağımız upstream dosyaları beklediğimiz dosyalar mı?
    if [ "$(sha256_of "$ROOT/adb-mcp/cep/com.mikechambers.ai/main.js")" != "$CEP_UPSTREAM_MAIN_SHA256" ] \
       || [ "$(sha256_of "$ROOT/adb-mcp/cep/com.mikechambers.ai/index.html")" != "$CEP_UPSTREAM_INDEX_SHA256" ]; then
      fail "adb-mcp'nin Illustrator eklentisi beklenenden farklı" \
           "ADB_MCP_COMMIT değişmiş ama cep/ altındaki GokAI dosyaları ve parmak izleri güncellenmemiş." \
           "(Bakımcı için: README › Sürümleri yükseltme.)"
    fi
    echo "$ADB_MCP_COMMIT" >"$ROOT/adb-mcp/.gokai-commit"
    ok "adb-mcp indirildi ve doğrulandı"
  fi
  # Illustrator eklentisi: GokAI'nin bağlantı yönetimi + yerel Socket.IO.
  # (upstream Socket.IO'yu internetten yüklüyor; internet yokken Connect çalışmıyor.)
  local cep="$ROOT/adb-mcp/cep/com.mikechambers.ai"
  cp "$SRC/cep/index.html" "$SRC/cep/main.js" "$cep/"
  cp "$SOCKETIO_CLIENT" "$cep/lib/socket.io.min.js"
  # Eklenti hiçbir betiği internetten yüklememeli.
  if grep -q -E '<script[^>]+src="https?://' "$cep/index.html" || [ ! -s "$cep/lib/socket.io.min.js" ]; then
    fail "Illustrator eklentisi çevrimdışı çalışacak şekilde hazırlanamadı"
  fi
  ok "Illustrator eklentisi hazırlandı (Socket.IO yerel, internet gerekmez)"

  # ---------------------------------------------------- 7. Photoshop MCP ---
  step "7/10 Photoshop MCP sunucusu kuruluyor (photoshop-mcp $PS_MCP_VERSION, sabit)"
  if [ "$REUSE" -eq 1 ] && [ -f "$PS_DIR/.gokai-lock-sha256" ] \
     && [ "$(cat "$PS_DIR/.gokai-lock-sha256")" = "$PS_LOCK_SHA" ] && [ -f "$PS_DIR/$PS_ENTRY_REL" ]; then
    reuse photoshop-mcp "$PS_DIR"
    ok "Zaten kurulu (kilit dosyası değişmemiş)"
  else
    mkdir -p "$ROOT/photoshop-mcp"
    cp "$SRC/photoshop-mcp/package.json" "$SRC/photoshop-mcp/package-lock.json" "$ROOT/photoshop-mcp/"
    skip "~350 MB indiriliyor; bağlantıya göre birkaç dakika sürebilir, lütfen bekleyin"
    # Eskiden bu sunucu her Claude açılışında "npx -y" ile internetten kuruluyordu.
    spin run_npm "$ROOT/photoshop-mcp" ci --omit=dev --no-audit --no-fund --loglevel=error || net_fail "Photoshop MCP sunucusu (npm)"
    [ -f "$ROOT/photoshop-mcp/$PS_ENTRY_REL" ] || fail "Photoshop MCP sunucusu eksik kuruldu"
    echo "$PS_LOCK_SHA" >"$ROOT/photoshop-mcp/.gokai-lock-sha256"
    ok "photoshop-mcp $PS_MCP_VERSION kuruldu (kilitli sürümler)"
  fi
}

# Normal (Beta olmayan) Photoshop var mı? Yoksa UXP eklentisi kurulamaz, dolayısıyla
# ona bağlı MCP sunucusunu hiç ekleme — Claude'da hiç bağlanmayan bir sunucu görünmesin.
# Klasörün var olması yetmez: kaldırılmış bir sürümden kalan boş klasör de
# "Adobe Photoshop 2025" adını taşır. İçinde gerçekten uygulama olmalı.
HAS_STABLE_PS=0
PS_STABLE_VERSION=""      # kurulu normal Photoshop'ların en yükseği (ör. 27.1.0)
for d in /Applications/Adobe\ Photoshop*; do
  case "$d" in
    *"(Beta)"*|*Elements*|*Lightroom*) continue ;;     # bunlar "normal Photoshop" değil
  esac
  for app in "$d"/Adobe\ Photoshop*.app; do
    if [ ! -d "$app/Contents/MacOS" ]; then continue; fi
    HAS_STABLE_PS=1
    v="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    case "${v%%.*}" in
      ''|*[!0-9]*) continue ;;      # sürüm okunamadı
    esac
    if [ -z "$PS_STABLE_VERSION" ] || [ "${v%%.*}" -gt "${PS_STABLE_VERSION%%.*}" ]; then PS_STABLE_VERSION="$v"; fi
  done
done
# (Yalnızca test: normal Photoshop'u olan bir makineyi taklit et.)
if [ "$TEST_MODE" = "1" ] && [ -n "${GOKAI_TEST_STABLE_PS_VERSION:-}" ]; then
  HAS_STABLE_PS=1
  PS_STABLE_VERSION="$GOKAI_TEST_STABLE_PS_VERSION"
fi

# ------------------------------------------ 8. Yerine koymadan önce dene ---
# Yeni sunucuları, Claude'un yapacağı gibi başlatıp el sıkışma yap. Burada
# başarısız olursa hiçbir şey değiştirilmeden durulur.
preflight() {
  GOKAI_ROOT="$ROOT" HAS_STABLE_PS="$HAS_STABLE_PS" GOKAI_NO_AUTOSTART=1 \
  "$NODE" - <<'PREFLIGHT_EOF' 2>>"$ILOG"
const path = require("path");
const fs = require("fs");
const os = require("os");
const root = process.env.GOKAI_ROOT;
const { mcpHandshake } = require(path.join(root, "proxy", "gokai-doctor.js"));
const py = path.join(root, "venv", "bin", "python");
const launcher = path.join(root, "mcp", "gokai_mcp.py");
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "gokai-preflight-"));
// Başlatıcı adb-mcp'yi GOKAI_DIR altında arar; henüz yerine konmadığı için geçici kökü göster.
const pyEnv = { GOKAI_DIR: root, GOKAI_NO_AUTOSTART: "1" };
const servers = [
  ["GokAI Illustrator", { command: py, args: ["-I", launcher, "illustrator"], env: pyEnv }, 5],
  ["GokAI Photoshop", {
    command: path.join(root, "node", "bin", "node"),
    args: [path.join(root, "photoshop-mcp", "node_modules", "@alisaitteke", "photoshop-mcp", "dist", "index.js")],
    // Deneme sırasında Photoshop'a dokunma, telemetri gönderme.
    env: { LOG_LEVEL: "1", PSMCP_UPDATE_CHECK: "0", ANALYTICS_DISABLED: "1", PHOTOSHOP_MCP_HOME: scratch },
  }, 50],
];
if (process.env.HAS_STABLE_PS === "1") {
  servers.push(["GokAI Photoshop Plugin", { command: py, args: ["-I", launcher, "photoshop"], env: pyEnv }, 50]);
}
(async () => {
  let bad = 0;
  for (const [name, entry, minTools] of servers) {
    const r = await mcpHandshake(entry, { timeoutMs: 60000 });
    if (r.ok && r.toolCount >= minTools) {
      console.log(`  \x1b[32m✓\x1b[0m ${name}: açıldı, ${r.toolCount} araç (${r.ms < 1000 ? r.ms + " ms" : (r.ms / 1000).toFixed(1) + " sn"})`);
    } else {
      bad++;
      console.log(`  \x1b[31m✗\x1b[0m ${name}: ${r.ok ? "beklenenden az araç (" + r.toolCount + ")" : r.error}`);
      for (const l of String(r.stderrTail || "").split("\n").slice(-6)) if (l.trim()) console.log("      " + l.slice(0, 200));
      console.error(`[preflight] ${name} başarısız: ${r.error}\n${r.stderrTail}`);
    }
  }
  try { fs.rmSync(scratch, { recursive: true, force: true }); } catch (e) {}
  process.exit(bad ? 1 : 0);
})();
PREFLIGHT_EOF
}

stage_all

step "8/10 Yeni sunucular deneniyor (henüz hiçbir şey değiştirilmedi)"
if ! preflight; then
  if [ "$REUSED_ANY" -eq 1 ]; then
    # Yeniden kullanılan (önceki kurulumdan kalan) bir bileşen bozuk olabilir.
    warn "Mevcut bileşenlerle başlatılamadı — her şey sıfırdan indirilip yeniden denenecek"
    REUSE=0
    REUSED_ANY=0
    stage_all
    step "8/10 Yeni sunucular yeniden deneniyor"
    preflight || fail "Yeni sunucular başlatılamadı — kurulum uygulanmadı" \
      "Yukarıdaki hata satırlarını kurulumu yapan kişiye iletin."
  else
    fail "Yeni sunucular başlatılamadı — kurulum uygulanmadı" \
      "Yukarıdaki hata satırlarını kurulumu yapan kişiye iletin."
  fi
fi


# ============================ buradan sonrası yerel ve hızlı ============================

# ------------------------------------------------------ 9. Yerine koy ---
# Yerine koymaya başlamadan önce hazırlanan her parçanın gerçekten var olduğunu
# doğrula: eksik bir parçayla başlamak çalışan kurulumu yarım bırakır.
for part in node uv venv adb-mcp photoshop-mcp proxy/node_modules proxy/gokai-proxy.js \
            proxy/gokai-doctor.js proxy/public/index.html mcp/gokai_mcp.py; do
  [ -e "$ROOT/$part" ] || fail "İç hata: hazırlanan kurulum eksik ($part)" \
    "Hiçbir şey değiştirilmedi. Bu iletiyi kurulumu yapan kişiye iletin."
done

step "9/10 Kurulum uygulanıyor"
APPLIED=1
UID_N="$(id -u)"
if [ "$TEST_MODE" != "1" ]; then
  launchctl bootout "gui/$UID_N/$SERVICE" >/dev/null 2>&1 || true
  # Servisin gerçekten kapanmasını bekle (yoksa yeniden yükleme "I/O error" verir)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_N/$SERVICE" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

# launchd dışında çalışan eski bir GokAI proxy'si kalmışsa kapat (ör. MCP
# sunucusunun doğrudan başlattığı kopya): yeni proxy portu alabilsin. Başka
# programlara dokunulmaz.
# (lsof dinleyen yokken hata kodu döner; `|| true` şart.)
for pid in $( { lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; } | sort -u ); do
  case "$(ps -o command= -p "$pid" 2>/dev/null || true)" in
    *gokai-proxy.js*) kill "$pid" 2>/dev/null || true ;;
  esac
done

for part in node uv venv adb-mcp photoshop-mcp; do
  # Sembolik bağ = mevcut kurulum yeniden kullanıldı, dokunma.
  if [ ! -L "$ROOT/$part" ]; then swap_in "$ROOT/$part" "$GOKAI_DIR/$part"; fi
done
mkdir -p "$GOKAI_DIR/proxy" "$GOKAI_DIR/mcp" "$GOKAI_DIR/bin"
if [ ! -L "$ROOT/proxy/node_modules" ]; then
  swap_in "$ROOT/proxy/node_modules" "$GOKAI_DIR/proxy/node_modules"
fi
cp "$ROOT/proxy/gokai-proxy.js" "$ROOT/proxy/gokai-doctor.js" "$ROOT/proxy/package.json" "$ROOT/proxy/package-lock.json" "$GOKAI_DIR/proxy/"
rm -rf "$GOKAI_DIR/proxy/public"; cp -R "$ROOT/proxy/public" "$GOKAI_DIR/proxy/public"
cp "$ROOT/mcp/gokai_mcp.py" "$ROOT/mcp/requirements.lock" "$GOKAI_DIR/mcp/"
if [ -f "$SRC/doctor.sh" ]; then cp "$SRC/doctor.sh" "$GOKAI_DIR/bin/doctor.sh"; chmod +x "$GOKAI_DIR/bin/doctor.sh"; fi
if [ -f "$SRC/gokai.icns" ]; then cp "$SRC/gokai.icns" "$GOKAI_DIR/gokai.icns"; fi

NODE="$GOKAI_DIR/node/bin/node"
VENV_PY="$GOKAI_DIR/venv/bin/python"
# İlk Claude açılışı hızlı olsun: bayt kodunu şimdi derle (başarısız olursa önemli değil).
"$VENV_PY" -I -m compileall -q "$GOKAI_DIR/venv/lib" "$GOKAI_DIR/adb-mcp/mcp" "$GOKAI_DIR/mcp" </dev/null >>"$ILOG" 2>&1 || true

GOKAI_DIR="$GOKAI_DIR" GOKAI_VERSION="$GOKAI_VERSION" ARCH="$ARCH" NODE_VERSION="$NODE_VERSION" \
UV_VERSION="$UV_VERSION" PYTHON_VERSION="$PYTHON_VERSION" ADB_MCP_COMMIT="$ADB_MCP_COMMIT" \
PS_MCP_VERSION="$PS_MCP_VERSION" HAS_STABLE_PS="$HAS_STABLE_PS" \
"$NODE" - <<'INFO_EOF'
const fs = require("fs"), path = require("path"), e = process.env;
const info = {
  version: e.GOKAI_VERSION,
  installedAt: new Date().toISOString(),
  arch: e.ARCH,
  node: e.NODE_VERSION,
  uv: e.UV_VERSION,
  python: e.PYTHON_VERSION,
  adbMcpCommit: e.ADB_MCP_COMMIT,
  photoshopMcp: e.PS_MCP_VERSION,
  hasStablePhotoshop: e.HAS_STABLE_PS === "1",
};
const file = path.join(e.GOKAI_DIR, "install.json");
fs.writeFileSync(file + ".tmp", JSON.stringify(info, null, 2) + "\n");
fs.renameSync(file + ".tmp", file);
INFO_EOF
ok "Dosyalar yerine kondu (v$GOKAI_VERSION)"

# launchd servisi
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${SERVICE}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$NODE")</string>
        <string>$(xml_escape "$GOKAI_DIR/proxy/gokai-proxy.js")</string>
    </array>
    <key>WorkingDirectory</key><string>$(xml_escape "$GOKAI_DIR/proxy")</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/gokai-proxy.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/gokai-proxy.error.log")</string>
</dict>
</plist>
PLIST_EOF
plutil -lint "$PLIST" >>"$ILOG" 2>&1 || fail "launchd kaydı oluşturulamadı (geçersiz plist)" "$PLIST"

if [ "$TEST_MODE" = "1" ]; then
  # Test modu: kayıt yazıldı ama launchd'ye yüklenmez; proxy doğrudan başlatılır.
  GOKAI_PORT="$PORT" GOKAI_DIR="$GOKAI_DIR" GOKAI_CLAUDE_CONFIG="$CLAUDE_CONFIG" GOKAI_NO_STARTUP_DOCTOR=1 \
    nohup "$NODE" "$GOKAI_DIR/proxy/gokai-proxy.js" </dev/null >>"$LOG_DIR/gokai-proxy.log" 2>&1 &
  skip "Test modu: proxy doğrudan başlatıldı (port $PORT, pid $!)"
else
  # Bir temizlik/optimizasyon uygulaması servisi devre dışı bırakmış olabilir.
  launchctl enable "gui/$UID_N/$SERVICE" >/dev/null 2>&1 || true
  LOADED=0
  for _ in 1 2 3; do
    if launchctl bootstrap "gui/$UID_N" "$PLIST" >>"$ILOG" 2>&1; then LOADED=1; break; fi
    if launchctl print "gui/$UID_N/$SERVICE" >/dev/null 2>&1; then LOADED=1; break; fi
    sleep 2
  done
  if [ "$LOADED" -eq 1 ]; then
    launchctl kickstart "gui/$UID_N/$SERVICE" >/dev/null 2>&1 || true
    ok "Arka plan servisi kuruldu (oturum açılışında otomatik başlar)"
  else
    warn "Arka plan servisi launchd'ye yüklenemedi — MCP sunucuları ilk kullanımda proxy'yi kendileri başlatır"
  fi
fi

# ---------------------------------------------- Claude Desktop config ---
if [ "$HAS_STABLE_PS" -ne 1 ]; then
  warn "Sadece Photoshop Beta bulundu — UXP tabanlı sunucu atlanıyor (AppleScript sunucusu Beta'da tam çalışır)"
fi

MERGE=0
GOKAI_DIR="$GOKAI_DIR" CLAUDE_CONFIG="$CLAUDE_CONFIG" HAS_STABLE_PS="$HAS_STABLE_PS" \
"$NODE" - <<'MERGE_EOF' || MERGE=$?
const fs = require("fs");
const path = require("path");

const gokaiDir = process.env.GOKAI_DIR;
const configPath = process.env.CLAUDE_CONFIG;
const nodeBin = path.join(gokaiDir, "node", "bin");
const python = path.join(gokaiDir, "venv", "bin", "python");
const launcher = path.join(gokaiDir, "mcp", "gokai_mcp.py");

// Sunucular kilitli yerel ortamlardan DOĞRUDAN çalıştırılır: "uv run --with ..."
// ya da "npx -y ..." yok. Claude açılırken hiçbir şey internetten çözülmez; yeni
// çıkan bir paket sürümü ya da internet kesintisi sunucuları bozamaz.
// -I: Python'u kullanıcının PYTHONPATH / site-packages ayarlarından yalıtır.
const adb = (app) => ({ command: python, args: ["-I", launcher, app] });

const entries = {
  "GokAI Photoshop": {
    command: path.join(nodeBin, "node"),
    args: [path.join(gokaiDir, "photoshop-mcp", "node_modules", "@alisaitteke", "photoshop-mcp", "dist", "index.js")],
    // PSMCP_UPDATE_CHECK=0: sürüm bilinçli olarak sabit; "güncelleme var" uyarısı çıkmasın.
    env: { LOG_LEVEL: "1", PSMCP_UPDATE_CHECK: "0", PATH: `${nodeBin}:/usr/bin:/bin:/usr/sbin:/sbin` },
  },
  "GokAI Illustrator": adb("illustrator"),
};

// UXP eklentisi yalnızca normal Photoshop'ta kurulabiliyor; Beta-only makinelerde
// bu sunucu asla bağlanamaz, o yüzden hiç eklenmiyor.
if (process.env.HAS_STABLE_PS === "1") {
  entries["GokAI Photoshop Plugin"] = adb("photoshop");
}

let cfg = {};
let before = null;
if (fs.existsSync(configPath)) {
  before = fs.readFileSync(configPath, "utf8");
  const text = before.replace(/^﻿/, "").trim();
  if (text) {
    try {
      cfg = JSON.parse(text);
    } catch (e) {
      // Bozuk dosyanın üzerine yazmak kullanıcının diğer MCP sunucularını siler.
      console.log(`  \x1b[31m✗\x1b[0m Claude yapılandırması geçerli JSON değil: ${e.message}`);
      console.log(`      ${configPath}`);
      process.exit(3);
    }
  }
}
if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
  console.log("  \x1b[31m✗\x1b[0m Claude yapılandırması beklenen biçimde değil (nesne olmalı)");
  process.exit(3);
}
if (cfg.mcpServers === null || typeof cfg.mcpServers !== "object" || Array.isArray(cfg.mcpServers)) cfg.mcpServers = {};

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

const after = JSON.stringify(cfg, null, 2);
const others = Object.keys(cfg.mcpServers).filter((k) => !k.startsWith("GokAI ")).length;
if (before !== null && before.trim() === after.trim()) {
  console.log(`  \x1b[32m✓\x1b[0m Yapılandırma zaten güncel (${Object.keys(entries).length} GokAI sunucusu)`);
  process.exit(0);
}
fs.mkdirSync(path.dirname(configPath), { recursive: true });
if (before !== null) {
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  fs.writeFileSync(`${configPath}.gokai-backup-${stamp}`, before);
}
// Önce geçici dosyaya yaz, sonra yeniden adlandır: yarım yazılmış config kalmaz.
const tmp = configPath + ".gokai-tmp";
fs.writeFileSync(tmp, after);
fs.renameSync(tmp, configPath);

// Yazdığımızı geri oku ve doğrula
const check = JSON.parse(fs.readFileSync(configPath, "utf8"));
for (const name of Object.keys(entries)) {
  if (!check.mcpServers || !check.mcpServers[name] || check.mcpServers[name].command !== entries[name].command) {
    console.log(`  \x1b[31m✗\x1b[0m Yapılandırma yazıldı ama doğrulanamadı: ${name}`);
    process.exit(4);
  }
}
console.log(`  \x1b[32m✓\x1b[0m ${Object.keys(entries).length} MCP sunucusu yazıldı` +
            (others ? ` (diğer ${others} sunucunuz korundu)` : "") +
            (before !== null ? " — eski hali yedeklendi" : ""));
MERGE_EOF
if [ "$MERGE" -eq 3 ]; then
  fail "Claude yapılandırması bozuk olduğu için değiştirilmedi" \
       "Dosyayı bir metin düzenleyicide düzeltin ya da aynı klasördeki bir yedeği geri yükleyin," \
       "sonra kurulumu yeniden çalıştırın."
elif [ "$MERGE" -ne 0 ]; then
  fail "Claude yapılandırması yazılamadı"
fi

# ------------------------------------------- Illustrator eklentisi (CEP) ---
# Illustrator CEP kullanıyor: klasör bağlantısı + imzasız eklentilere izin.
# UXP'nin aksine bu KALICIDIR — Illustrator her açıldığında tekrar yüklemeye gerek yok.
CEP_DIR="$HOME/Library/Application Support/Adobe/CEP/extensions"
CEP_SRC="$GOKAI_DIR/adb-mcp/cep/com.mikechambers.ai"
CEP_LINK="$CEP_DIR/com.mikechambers.ai"
mkdir -p "$CEP_DIR"
# Elle kopyalanmış eski bir klasör varsa `ln -sfn` bağlantıyı onun İÇİNE kurar.
if [ -e "$CEP_LINK" ] && [ ! -L "$CEP_LINK" ]; then
  mkdir -p "$GOKAI_DIR/.replaced"
  mv "$CEP_LINK" "$GOKAI_DIR/.replaced/com.mikechambers.ai-$(date +%Y%m%d%H%M%S)"
  warn "Elle kurulmuş eski Illustrator eklentisi kenara alındı"
fi
ln -sfn "$CEP_SRC" "$CEP_LINK"
ok "Illustrator eklentisi bağlandı: com.mikechambers.ai"
if [ "$TEST_MODE" != "1" ]; then
  # İmzasız CEP eklentilerinin yüklenmesi için gerekli (CSXS sürümü CC sürümüne göre değişir)
  for v in 9 10 11 12 13 14 15 16; do defaults write "com.adobe.CSXS.$v" PlayerDebugMode 1 2>/dev/null || true; done
  ok "PlayerDebugMode etkinleştirildi"
  if pgrep -f "Illustrator.app/Contents/MacOS" >/dev/null 2>&1; then
    warn "Illustrator açık — yeni eklenti için Illustrator'ı yeniden başlatın"
  fi
fi

# ------------------------------------------- Photoshop eklentisi (UXP/.ccx) ---
# Adobe'nin resmi komut satırı kurucusuyla (UPIA) .ccx paketini kurar.
# Başarılı olursa KALICIDIR — UXP Developer Tools'a hiç gerek kalmaz.
# Photoshop Beta'da çalışmaz (Adobe Beta'yı geçerli hedef saymıyor).
#
# DİKKAT: UPIA başarısız olduğunda da 0 çıkış koduyla biter; sonucu yalnızca
# yazdığı satırdan ("Failed to install, status = -411!") anlaşılır. Çıktısı
# bu yüzden günlüğe yazılır ve neden kullanıcıya gösterilir.
UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
PS_CCX_SRC="$PS_CCX_URL"
if [ "$TEST_MODE" = "1" ]; then
  # Test: gerçek Adobe kurucusuna dokunma; sahte bir kurucu verilmişse onu kullan.
  UPIA="${GOKAI_TEST_UPIA:-}"
  PS_CCX_SRC="${GOKAI_TEST_CCX_URL:-$PS_CCX_URL}"
fi
PS_CCX="$GOKAI_DIR/Photoshop_MCP_Agent.ccx"
UXP_EXTERNAL="$HOME/Library/Application Support/Adobe/UXP/Plugins/External"
UPIA_OUT="$GOKAI_DIR/.upia-output.txt"

# Sonuç: doktor ve panel "neden kurulmadı"yı buradan okur (install.json'a yazılır).
PS_PLUGIN_STATE="not-applicable"     # installed | not-applicable | ps-too-old | no-installer |
                                     # ps-running | download-failed | failed | timeout
PS_PLUGIN_STATUS=""                  # UPIA'nın durum kodu (ör. -411)
PS_PLUGIN_NOTE=""                    # kullanıcıya gösterilen neden + ne yapmalı

ps_plugin_installed() {
  [ -n "$(find "$UXP_EXTERNAL" -maxdepth 1 -iname "*$PS_PLUGIN_NAME*" 2>/dev/null || true)" ]
}

# Normal Photoshop şu an açık mı? Yalnızca ana uygulamaya bakar: Adobe'nin
# arka plan yardımcıları da yolunda "Adobe Photoshop 2026" taşır ve uygulama
# kapalıyken bile `pgrep -f "Adobe Photoshop [0-9]"` ile eşleşebilir.
stable_photoshop_running() {
  if [ "$TEST_MODE" = "1" ]; then
    [ "${GOKAI_TEST_PS_RUNNING:-0}" = "1" ]
    return
  fi
  local procs
  procs="$(ps -Ao comm= | grep -E '/Adobe Photoshop [0-9][^/]*/Adobe Photoshop [0-9][^/]*\.app/Contents/MacOS/Adobe Photoshop [0-9][^/]*$' || true)"
  [ -n "$procs" ]
}

# UPIA'yı süre sınırıyla çalıştırır (bazen takılıyor); çıktısını saklar.
run_upia() { # süre-sn  argümanlar...
  local limit="$1"; shift
  : >"$UPIA_OUT"
  "$UPIA" "$@" </dev/null >"$UPIA_OUT" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$limit" ]; do sleep 1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "GOKAI_TIMEOUT: $limit saniyede bitmedi, durduruldu" >>"$UPIA_OUT"
  fi
  wait "$pid" 2>/dev/null || true
  { echo "--- UPIA $1 ---"; cat "$UPIA_OUT"; } >>"$ILOG"
}

# Eklenti hem diskte hem Adobe'nin kayıtlarında mı? İkisi de tamamsa kurulu ve
# sağlam demektir; kaldırıp yeniden kurmak (yeniden kurulum başarısız olursa)
# çalışan bir eklentiyi yok etmekten başka işe yaramaz.
ps_plugin_registered() {
  ps_plugin_installed || return 1
  run_upia 20 --list all
  grep -qi "$PS_PLUGIN_NAME" "$UPIA_OUT" 2>/dev/null
}

# UPIA'nın son yazdığı durum kodu (yoksa boş).
upia_status() { sed -n 's/.*status = \(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$UPIA_OUT" | tail -1; }

# Durum kodunun anlamı ve ne yapılacağı (Adobe'nin eklenti kurucusu hata kodları).
upia_reason() {
  local again="Sonra kurulum komutunu tekrar çalıştırın."
  case "$1" in
    -411|-458) echo "Adobe kurucusu bu eklentiyle uyumlu bir Photoshop bulamadı (durum kodu $1). Creative Cloud uygulaması bu Photoshop'u tanımıyor olabilir: Creative Cloud'u açıp oturum açın ve Photoshop'u oradan güncelleyin. $again" ;;
    -459)      echo "Kurulu Photoshop sürümü eklentiyle uyumlu değil (durum kodu $1): Photoshop 2025 (v$PS_PLUGIN_MIN_MAJOR) ve üzeri gerekir. Photoshop'u güncelleyin. $again" ;;
    -456)      echo "Bir Adobe uygulaması açık olduğu için kurulamadı (durum kodu $1). Photoshop'u kapatın. $again" ;;
    -412|-418) echo "Aynı adlı bir eklenti zaten kayıtlı ama dosyaları yerinde değil (durum kodu $1). Creative Cloud › Eklentileri yönet bölümünden \"$PS_PLUGIN_NAME\" eklentisini kaldırın. $again" ;;
    "")        echo "Adobe eklenti kurucusu bir sonuç bildirmedi. Creative Cloud uygulamasını açın. $again" ;;
    *)         echo "Adobe eklenti kurucusu hata verdi (durum kodu $1). Bu kodu kurulumu yapan kişiye iletin." ;;
  esac
}

if [ "$TEST_MODE" = "1" ] && [ -z "$UPIA" ]; then
  skip "Test modu: Photoshop eklentisi adımı atlandı"
elif [ "$HAS_STABLE_PS" -eq 0 ]; then
  skip "Photoshop Beta — .ccx kurulumu gerekmiyor (AppleScript sunucusu eklenti istemez)"
elif [ -n "$PS_STABLE_VERSION" ] && [ "${PS_STABLE_VERSION%%.*}" -lt "$PS_PLUGIN_MIN_MAJOR" ]; then
  PS_PLUGIN_STATE="ps-too-old"
  PS_PLUGIN_NOTE="Photoshop $PS_STABLE_VERSION bu eklenti için eski: eklenti Photoshop 2025 (v$PS_PLUGIN_MIN_MAJOR) ve üzerinde yüklenir. Photoshop'u Creative Cloud'dan güncelleyip kurulumu tekrar çalıştırın."
elif [ ! -x "$UPIA" ]; then
  PS_PLUGIN_STATE="no-installer"
  PS_PLUGIN_NOTE="Adobe eklenti kurucusu bu makinede yok (Creative Cloud uygulaması kurulu ve güncel mi?). Creative Cloud'u kurup/güncelleyip kurulumu tekrar çalıştırın."
elif stable_photoshop_running; then
  if ps_plugin_installed; then
    PS_PLUGIN_STATE="installed"
    ok "Photoshop eklentisi zaten kurulu (Photoshop açık olduğu için yenilenmedi)"
  else
    PS_PLUGIN_STATE="ps-running"
    PS_PLUGIN_NOTE="Photoshop açık olduğu için eklenti kurulamadı. Photoshop'u kapatıp kurulum komutunu tekrar çalıştırın (bu kez saniyeler sürer)."
  fi
elif ps_plugin_registered; then
  PS_PLUGIN_STATE="installed"
  ok "Photoshop eklentisi zaten kurulu"
else
  # İndirme başarısız olursa eldeki eski kopya kullanılır (fetch yarım dosya bırakmaz).
  fetch "$PS_CCX_SRC" "$PS_CCX" || true
  if [ ! -s "$PS_CCX" ]; then
    PS_PLUGIN_STATE="download-failed"
    PS_PLUGIN_NOTE="Eklenti paketi indirilemedi (internet?). Kurulum komutunu tekrar çalıştırın."
  else
    # Buraya yalnızca eklenti eksik ya da yarım (dosya var / kayıt yok, ya da tersi)
    # ise gelinir. Eski bir kayıt varsa önce kaldır — yoksa UPIA "başarılı" deyip
    # dosya yazmıyor.
    run_upia 30 --remove "$PS_PLUGIN_NAME"
    UPIA_LIMIT=90
    if [ "$TEST_MODE" = "1" ]; then UPIA_LIMIT="${GOKAI_TEST_UPIA_TIMEOUT:-90}"; fi
    for attempt in 1 2; do
      run_upia "$UPIA_LIMIT" --install "$PS_CCX"
      # UPIA bittikten sonra dosyaların yerine oturmasını kısa süre bekle
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ps_plugin_installed; then break; fi
        sleep 1
      done
      if ps_plugin_installed; then break; fi
      PS_PLUGIN_STATUS="$(upia_status)"
      case "$PS_PLUGIN_STATUS" in
        -411|-458|-459|-456) break ;;     # yeniden denemek sonucu değiştirmez
      esac
      if grep -q "GOKAI_TIMEOUT" "$UPIA_OUT" 2>/dev/null; then break; fi   # takıldı: bir daha bekletme
      if [ "$attempt" -eq 1 ]; then sleep 3; fi
    done
    if ps_plugin_installed; then
      PS_PLUGIN_STATE="installed"
      PS_PLUGIN_STATUS=""
      ok "Photoshop eklentisi kalıcı olarak kuruldu (UDT gerekmiyor)"
    elif grep -q "GOKAI_TIMEOUT" "$UPIA_OUT" 2>/dev/null; then
      PS_PLUGIN_STATE="timeout"
      PS_PLUGIN_NOTE="Adobe eklenti kurucusu yanıt vermedi. Creative Cloud uygulamasını açıp kurulum komutunu tekrar çalıştırın."
    else
      PS_PLUGIN_STATE="failed"
      PS_PLUGIN_NOTE="$(upia_reason "$PS_PLUGIN_STATUS")"
    fi
  fi
fi
rm -f "$UPIA_OUT"

if [ -n "$PS_PLUGIN_NOTE" ]; then
  warn "Photoshop eklentisi (UXP) KURULAMADI"
  warn "  $PS_PLUGIN_NOTE"
fi

# Sonucu install.json'a ekle: doktor ve panel nedeni buradan gösterir.
GOKAI_DIR="$GOKAI_DIR" PS_PLUGIN_STATE="$PS_PLUGIN_STATE" PS_PLUGIN_STATUS="$PS_PLUGIN_STATUS" \
PS_PLUGIN_NOTE="$PS_PLUGIN_NOTE" PS_STABLE_VERSION="$PS_STABLE_VERSION" \
"$NODE" - <<'PLUGIN_EOF' || true
const fs = require("fs"), path = require("path"), e = process.env;
const file = path.join(e.GOKAI_DIR, "install.json");
const info = JSON.parse(fs.readFileSync(file, "utf8"));
info.photoshopVersion = e.PS_STABLE_VERSION || null;
info.photoshopPlugin = {
  state: e.PS_PLUGIN_STATE,
  upiaStatus: e.PS_PLUGIN_STATUS || null,
  note: e.PS_PLUGIN_NOTE || null,
  at: new Date().toISOString(),
};
fs.writeFileSync(file + ".tmp", JSON.stringify(info, null, 2) + "\n");
fs.renameSync(file + ".tmp", file);
PLUGIN_EOF

# ----------------------------------------------------- GokAI.app kısayolu ---
APP="$HOME/Applications/GokAI.app"
rm -rf "$APP"
if osacompile -e "do shell script \"open http://localhost:$PORT\"" -o "$APP" </dev/null >>"$ILOG" 2>&1; then
  # Yerelde oluşturulduğu için Gatekeeper karantinası YOK.
  # Özel ikon uygula
  if [ -f "$GOKAI_DIR/gokai.icns" ] && [ -d "$APP/Contents/Resources" ]; then
    cp "$GOKAI_DIR/gokai.icns" "$APP/Contents/Resources/applet.icns"
    touch "$APP"
  fi
  ok "~/Applications/GokAI.app hazır (durum panelini açar)"
else
  warn "GokAI.app oluşturulamadı — panel adresi: http://localhost:$PORT"
fi

rm -rf "$STAGE" "$CACHE_DIR" 2>/dev/null || true

# ----------------------------------------------------------- 10. Doğrulama ---
step "10/10 Uçtan uca doğrulama (GokAI Doktor)"
# Proxy'nin ayağa kalkmasını bekle
UP=0
for _ in $(seq 1 40); do
  ST="$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT/status" 2>/dev/null </dev/null || true)"
  case "$ST" in
    *"\"version\":\"$GOKAI_VERSION\""*) UP=1; break ;;
  esac
  sleep 0.5
done
if [ "$UP" -ne 1 ]; then warn "Proxy 20 saniyede yanıt vermedi — ayrıntı aşağıdaki raporda"; fi

DOCTOR=0
GOKAI_DIR="$GOKAI_DIR" GOKAI_PORT="$PORT" GOKAI_CLAUDE_CONFIG="$CLAUDE_CONFIG" \
  "$NODE" "$GOKAI_DIR/proxy/gokai-doctor.js" --color </dev/null || DOCTOR=$?

if [ "$DOCTOR" -ne 0 ]; then
  printf "\033[1;31mKurulum dosyaları yerinde ama doğrulama sorun buldu.\033[0m\n"
  echo "Yukarıdaki ✗ satırlarını kurulumu yapan kişiye iletin."
  echo "Günlük: $ILOG"
  echo ""
  exit 1
fi

if [ -n "$PS_PLUGIN_NOTE" ]; then
  # Eksik kalan bir şey varsa "her şey tamam" deme; en sonda, gözden kaçmayacak yerde söyle.
  printf "\033[1;33mKurulum tamamlandı — bir eksikle:\033[0m\n\n"
  printf "  \033[33m!\033[0m \033[1mPhotoshop eklentisi (UXP) kurulamadı.\033[0m\n"
  echo "    $PS_PLUGIN_NOTE"
  echo "    (Bu arada 'GokAI Photoshop' sunucusu eklentisiz çalışır; eksik olan 'GokAI Photoshop Plugin'.)"
  echo ""
else
  printf "\033[1;32mKurulum tamamlandı ve doğrulandı!\033[0m\n\n"
fi
echo "Sonraki adımlar (makine başına bir kez):"
if [ "$CLAUDE_RUNNING" -eq 1 ]; then
  printf "  1. \033[1;33mClaude açıkken kuruldu:\033[0m Claude Desktop'ı Cmd+Q ile kapatıp açın; sunucular\n"
  echo "     görünmezse Claude kapalıyken kurulumu bir kez daha çalıştırın."
else
  echo "  1. Claude Desktop'ı açın"
fi
echo "  2. Illustrator: yeniden başlat → bir dosya aç → Pencere › Uzantılar › Illustrator MCP Agent"
echo "     (panel açılınca kendiliğinden bağlanır; açık bıraktığınız sürece her seferinde bağlanır)"
if [ "$HAS_STABLE_PS" -eq 1 ] && [ "$PS_PLUGIN_STATE" = "installed" ]; then
  echo "  3. Photoshop: yeniden başlat → Eklentiler › Photoshop MCP Agent → Connect → Connect on Launch ✓"
elif [ "$HAS_STABLE_PS" -eq 1 ]; then
  echo "  3. Photoshop: önce yukarıdaki eklenti eksiğini giderin"
else
  echo "  3. Photoshop: yapacak bir şey yok — Beta'da eklentisiz çalışır"
fi
echo "  4. Durum paneli: GokAI.app  →  http://localhost:$PORT"
echo ""
echo "Bir sorun olursa tanı için:"
echo "  curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/doctor.sh | bash"
echo ""
if [ "$TEST_MODE" != "1" ]; then open "http://localhost:$PORT" 2>/dev/null || true; fi
