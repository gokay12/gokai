#!/bin/bash
# GokAI kurulum betiği — senaryo testleri (mevcut bir sandbox kurulumu üzerinde).
# install.sh'taki HER değişiklikten sonra çalıştırılmalı: yeniden çalıştırma,
# internet kesintisi, bozuk Claude ayarı, yarıda kesilme, geri alma.
# tests/run.sh üzerinden çalıştırılır; gerçek kuruluma dokunmaz.
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
H="${GOKAI_SANDBOX_HOME:?GOKAI_SANDBOX_HOME gerekli (tests/run.sh kullanın)}"
S="$(mktemp -d "${TMPDIR:-/tmp}/gokai-install-test.XXXXXX")"
trap 'rm -rf "$S"' EXIT
G="$H/Library/Application Support/GokAI"
CFG="$H/Library/Application Support/Claude/claude_desktop_config.json"
PORT=3907
PASS=0; FAIL=0
LOG="$S/ti.log"

ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; if [ -f "$LOG" ]; then sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "✗|adım:|HATA|Error|error" | head -5 | sed 's/^/        | /'; fi; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

install() { ( cd "$R" && HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT "$@" bash install.sh ) >"$LOG" 2>&1; }
proxy_pid() { { lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true; } | sort -u | head -1; }
kill_proxy() { local p; for p in $({ lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true; } | sort -u); do kill "$p" 2>/dev/null; done; sleep 0.7; }
doctor_ok() {
  HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT GOKAI_DIR="$G" GOKAI_CLAUDE_CONFIG="$CFG" \
    "$G/node/bin/node" "$G/proxy/gokai-doctor.js" --json >"$S/td.json" 2>/dev/null
  /usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['counts']['fail']==0 else 1)" "$S/td.json"
}
intact() {  # tüm bileşenler yerinde, artık yok
  local p
  for p in node/bin/node uv/uv venv/bin/python adb-mcp/mcp/ai-mcp.py photoshop-mcp/node_modules proxy/node_modules proxy/gokai-proxy.js mcp/gokai_mcp.py install.json; do
    [ -e "$G/$p" ] || { echo "        eksik: $p"; return 1; }
  done
  [ -z "$(ls -a "$G" "$G/proxy" | grep -E '\.old-|^\.stage$' || true)" ] || { echo "        artık kaldı: $(ls -a "$G" "$G/proxy" | grep -E '\.old-|^\.stage$' | tr '\n' ' ')"; return 1; }
}
backups() { ls "$(dirname "$CFG")" | grep -c "gokai-backup" || true; }

echo ""; echo "== S0. Önceki çalıştırma yer değiştirirken kesilmiş (bileşen .old- adında kalmış) =="
kill_proxy
if ! ls -d "$G"/*.old-* >/dev/null 2>&1; then mv "$G/node" "$G/node.old-4242"; fi
ls -d "$G"/*.old-* | sed "s|$G/|        başlangıç: |"
install; RC=$?
check "kurulum kesilmiş yer değiştirmeyi geri alıp tamamlandı" "[ $RC -eq 0 ] && intact"
check "doktor: sorun yok" "doctor_ok"

echo ""; echo "== S1. Sağlıklı kurulumda yeniden çalıştırma =="
kill_proxy
B0=$(backups); T0=$(date +%s)
install; RC=$?
check "portta dinleyen YOKKEN: başarılı (lsof'un hata kodu kurulumu bozmuyor)" "[ $RC -eq 0 ] && intact"
check "hızlı (yeniden indirme yok): $(( $(date +%s) - T0 )) sn" "[ $(( $(date +%s) - T0 )) -lt 30 ]"
P1=$(proxy_pid)
install; RC=$?
P2=$(proxy_pid)
check "portta eski proxy VARKEN: başarılı, proxy yenisiyle değişti (pid $P1 → $P2)" "[ $RC -eq 0 ] && intact && [ -n \"$P2\" ] && [ \"$P1\" != \"$P2\" ]"
check "yapılandırma değişmediği için yeni yedek alınmadı" "[ $(backups) -eq $B0 ]"
check "doktor: sorun yok" "doctor_ok"

echo ""; echo "== S2. İndirme sırasında internet kesilirse =="
cp "$G/venv/.gokai-lock-sha256" "$S/venv.marker"; rm -f "$G/venv/.gokai-lock-sha256"
install env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9; RC=$?
cp "$S/venv.marker" "$G/venv/.gokai-lock-sha256"
check "anlaşılır hatayla durdu (kod $RC)" "[ $RC -eq 1 ] && grep -q 'Python paketleri indirilemedi' '$LOG' && grep -q 'dokunulmadı' '$LOG'"
check "çalışan kurulum olduğu gibi duruyor" "intact && doctor_ok"

echo ""; echo "== S3. Claude yapılandırması bozuk =="
cp "$CFG" "$S/cfg.keep"; printf '{ "mcpServers": { BOZUK' >"$CFG"; SUM=$(shasum "$CFG" | cut -d' ' -f1); M0=$(stat -f %m "$G/install.json")
install; RC=$?
check "hiçbir şeyi değiştirmeden durdu (kod $RC)" "[ $RC -eq 1 ] && grep -q 'yapılandırma dosyası bozuk' '$LOG' && [ \"$SUM\" = \"\$(shasum '$CFG' | cut -d' ' -f1)\" ] && [ $M0 -eq \$(stat -f %m '$G/install.json') ]"
cp "$S/cfg.keep" "$CFG"
check "kurulum sağlam" "intact"

echo ""; echo "== S4. Uzun indirme sırasında kurulum kesilirse (SIGTERM) =="
cp "$G/photoshop-mcp/.gokai-lock-sha256" "$S/ps.marker"; rm -f "$G/photoshop-mcp/.gokai-lock-sha256"   # 350 MB'lık adımı zorla
( cd "$R" && HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT bash install.sh >"$LOG" 2>&1 ) &
WRAP=$!
# npm ci başlayana kadar bekle
for _ in $(seq 1 60); do grep -q "7/10" "$LOG" 2>/dev/null && pgrep -f "$G/.stage/root/node/bin" >/dev/null 2>&1 && break; sleep 0.5; done
sleep 3
IPID=$(pgrep -f "bash install.sh" | while read -r p; do [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = "$WRAP" ] && echo "$p"; done | head -1)
NPM_BEFORE=$(pgrep -f "$G/.stage" | wc -l | tr -d ' ')
kill -TERM "$IPID" 2>/dev/null; wait $WRAP; RC=$?
sleep 1.5
NPM_AFTER=$(pgrep -f "$G/.stage" | wc -l | tr -d ' ')
cp "$S/ps.marker" "$G/photoshop-mcp/.gokai-lock-sha256"
check "kesildi: çıkış kodu 130, 'durduruldu' iletisi" "[ $RC -eq 130 ] && grep -q 'Kurulum durduruldu' '$LOG'" "kod=$RC"
check "arka plandaki indirme de durdu (süreç: $NPM_BEFORE → $NPM_AFTER)" "[ $NPM_BEFORE -gt 0 ] && [ $NPM_AFTER -eq 0 ]"
check "hazırlık klasörü silindi, çalışan kurulum sağlam" "intact && doctor_ok"

echo ""; echo "== S5. Hazırlanan bileşen kaybolursa (iç hata) hiçbir şeye dokunmadan durur =="
# preflight'tan sonra, yerine koymadan önce ROOT/venv'i sil: bunu taklit etmek için
# install.sh'ın bir kopyasında 9. adımdan hemen önce bir satır ekliyoruz.
sed 's|^# Yerine koymaya başlamadan önce hazırlanan her parçanın gerçekten var olduğunu|rm -rf "$ROOT/venv"\n&|' "$R/install.sh" >"$S/install-sabote.sh"
mkdir -p "$S/sabote" && ( cd "$R" && tar -cf - --exclude node_modules --exclude .git . ) | ( cd "$S/sabote" && tar -xf - ) && cp "$S/install-sabote.sh" "$S/sabote/install.sh"
M0=$(stat -f %m "$G/install.json")
( cd "$S/sabote" && HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT bash install.sh ) >"$LOG" 2>&1; RC=$?
check "eksik parçayı fark edip durdu (kod $RC)" "[ $RC -eq 1 ] && grep -q 'hazırlanan kurulum eksik' '$LOG'"
check "çalışan kuruluma dokunulmadı" "intact && [ $M0 -eq \$(stat -f %m '$G/install.json') ] && doctor_ok"
rm -rf "$S/sabote" "$S/install-sabote.sh"

# ---------------------------------------------------------------------------
# Normal (Beta olmayan) Photoshop'lu makine: UXP eklenti adımı.
# Bu makinede normal Photoshop olmayabilir; sahte bir Adobe kurucusu
# (tests/fake-upia.sh) ve GOKAI_TEST_STABLE_PS_VERSION ile taklit edilir.
FAKE="$R/tests/fake-upia.sh"
CCX="$S/sahte.ccx"; echo "sahte eklenti paketi" >"$CCX"
CALLS="$S/upia.calls"
UXP_EXT="$H/Library/Application Support/Adobe/UXP/Plugins/External"
ps_env() { echo GOKAI_TEST_UPIA="$FAKE" GOKAI_TEST_CCX_URL="file://$CCX" GOKAI_TEST_UPIA_TIMEOUT=3 GOKAI_FAKE_UPIA_LOG="$CALLS"; }
ps_install() { : >"$CALLS"; install env GOKAI_TEST_UPIA="$FAKE" GOKAI_TEST_CCX_URL="file://$CCX" GOKAI_TEST_UPIA_TIMEOUT=3 GOKAI_FAKE_UPIA_LOG="$CALLS" "$@"; }
plugin() { /usr/bin/python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get('photoshopPlugin') or {}).get(sys.argv[2]) or '')" "$G/install.json" "$1"; }
has_plugin_entry() { grep -q '"GokAI Photoshop Plugin"' "$CFG"; }
doctor_line() {  # ortam değişkenleri…  → doktorun Photoshop eklentisi satırı (durum:başlık)
  env HOME="$H" GOKAI_TEST_MODE=1 GOKAI_PORT=$PORT GOKAI_DIR="$G" GOKAI_CLAUDE_CONFIG="$CFG" GOKAI_TEST_UPIA="$FAKE" "$@" \
    "$G/node/bin/node" "$G/proxy/gokai-doctor.js" --quick --json 2>/dev/null \
    | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(' | '.join(c['status']+':'+c['title'] for c in d['checks'] if 'eklentisi (UXP)' in c['title']))"
}

echo ""; echo "== P1. Normal Photoshop 27 + Adobe kurucusu başarılı =="
rm -rf "$UXP_EXT"
ps_install GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_MODE=ok; RC=$?
check "kurulum başarılı, eklenti kuruldu" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = installed ] && grep -q 'kalıcı olarak kuruldu' '$LOG' && grep -q 'tamamlandı ve doğrulandı' '$LOG'" "state=$(plugin state)"
check "Claude'a 'GokAI Photoshop Plugin' eklendi ve sunucusu denendi" "has_plugin_entry && grep -q 'GokAI Photoshop Plugin: açıldı' '$LOG'"
check "doktor: eklenti kurulu" "[ \"\$(doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0)\" = 'ok:Photoshop eklentisi (UXP) kurulu' ]" "$(doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0)"
check "doktor: kurulu ama devre dışıysa söyler" "doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_LIST_STATUS=Disabled | grep -q 'warn:.*devre dışı'"

echo ""; echo "== P1b. Eklenti zaten kurulu ve kayıtlıyken yeniden çalıştırma =="
# Kurucu bu kez başarısız olacak şekilde ayarlı: çağrılırsa çalışan eklentiyi kaybederiz.
ps_install GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_MODE=fail411; RC=$?
check "çalışan eklentiye dokunulmadı (kaldır/kur çağrılmadı)" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = installed ] && ! grep -q -E -- '--(remove|install)' '$CALLS' && [ -d '$UXP_EXT/Photoshop MCP Agent_0.85.3' ] && grep -q 'zaten kurulu' '$LOG'" "state=$(plugin state) çağrılar: $(tr '\n' ';' <"$CALLS")"

echo ""; echo "== P2. Adobe kurucusu başarısız (durum kodu -411; çıkış kodu yine 0) =="
rm -rf "$UXP_EXT"
ps_install GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_MODE=fail411; RC=$?
check "neden yakalandı ve gösterildi" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = failed ] && [ \"\$(plugin upiaStatus)\" = -411 ] && grep -q 'KURULAMADI' '$LOG' && grep -q 'durum kodu -411' '$LOG'" "state=$(plugin state) status=$(plugin upiaStatus)"
check "kurulum sonunda 'her şey tamam' denmiyor, eksik en sonda söyleniyor" "grep -q 'bir eksikle' '$LOG' && ! grep -q 'tamamlandı ve doğrulandı' '$LOG'"
check "doktor: nedenini söyleyen uyarı (hata değil)" "doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0 | grep -q '^warn:Photoshop eklentisi (UXP) kurulu değil'" "$(doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0)"
check "doktor: Creative Cloud Photoshop'u tanımıyorsa bunu söyler" "doctor_line GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_NO_PS=1 | grep -q 'tanımıyor'"

echo ""; echo "== P3. Photoshop açıkken =="
ps_install GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_MODE=ok GOKAI_TEST_PS_RUNNING=1; RC=$?
check "kurucu çağrılmadı, neden açıkça söylendi" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = ps-running ] && ! grep -q -- '--install' '$CALLS' && grep -q 'Photoshop açık olduğu için' '$LOG'" "state=$(plugin state)"

echo ""; echo "== P4. Photoshop eklenti için eski (v25) =="
ps_install GOKAI_TEST_STABLE_PS_VERSION=25.9.1 GOKAI_FAKE_UPIA_MODE=ok; RC=$?
check "kurucu çağrılmadı, sürüm nedeni söylendi" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = ps-too-old ] && ! grep -q -E -- '--(remove|install)' '$CALLS' && grep -q 'Photoshop 25.9.1 bu eklenti için eski' '$LOG'" "state=$(plugin state)"
check "doktor: sürüm nedeniyle kurulamaz" "doctor_line GOKAI_TEST_STABLE_PS_VERSION=25.9.1 | grep -q 'warn:.*25.9.1 eski'" "$(doctor_line GOKAI_TEST_STABLE_PS_VERSION=25.9.1)"

echo ""; echo "== P5. Adobe kurucusu takılırsa =="
T0=$(date +%s)
ps_install GOKAI_TEST_STABLE_PS_VERSION=27.1.0 GOKAI_FAKE_UPIA_MODE=hang; RC=$?
check "süre sınırında durduruldu, kurulum asılı kalmadı ($(( $(date +%s) - T0 )) sn)" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = timeout ] && [ $(( $(date +%s) - T0 )) -lt 40 ]" "state=$(plugin state)"
check "takılan kurucu süreci geride kalmadı" "! pgrep -f 'sleep 600' >/dev/null"

echo ""; echo "== P6. Adobe kurucusu yok / paket indirilemiyor =="
: >"$CALLS"; install env GOKAI_TEST_UPIA="/yok/boyle/bir/kurucu" GOKAI_TEST_CCX_URL="file://$CCX" GOKAI_TEST_STABLE_PS_VERSION=27.1.0; RC=$?
check "kurucu yoksa: neden söylendi" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = no-installer ]" "state=$(plugin state)"
rm -f "$G/Photoshop_MCP_Agent.ccx"
: >"$CALLS"; install env GOKAI_TEST_UPIA="$FAKE" GOKAI_TEST_CCX_URL="file://$S/yok.ccx" GOKAI_FAKE_UPIA_LOG="$CALLS" GOKAI_TEST_STABLE_PS_VERSION=27.1.0; RC=$?
check "paket indirilemezse: neden söylendi, kurucu çağrılmadı" "[ $RC -eq 0 ] && [ \"\$(plugin state)\" = download-failed ] && ! grep -q -E -- '--(remove|install)' '$CALLS'" "state=$(plugin state)"

echo ""; echo "== P7. Yeniden yalnızca Beta'lı makine =="
install; RC=$?
check "eski 'GokAI Photoshop Plugin' girdisi kaldırıldı" "[ $RC -eq 0 ] && ! has_plugin_entry && [ \"\$(plugin state)\" = not-applicable ]" "state=$(plugin state)"
rm -rf "$UXP_EXT"

kill_proxy
echo ""
if [ "$FAIL" -eq 0 ]; then echo "TÜM KURULUM SENARYOLARI GEÇTİ ($PASS geçti)"; else echo "$FAIL SENARYO KONTROLÜ BAŞARISIZ ($PASS geçti)"; fi
exit "$FAIL"
