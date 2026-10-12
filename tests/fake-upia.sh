#!/bin/bash
#
# Sahte Adobe eklenti kurucusu (UnifiedPluginInstallerAgent) — yalnızca testler için.
#
# Normal (Beta olmayan) Photoshop'u olmayan bir makinede de kurulumun UXP eklenti
# adımını deneyebilmek için. Gerçek kurucunun gözlenen davranışını taklit eder
# (UPIA 8.5): başarısızlıkta da 0 ile çıkar; sonucu yalnızca yazdığı satır belirtir.
#
#   GOKAI_FAKE_UPIA_MODE        ok | fail411 | fail456 | hang | silent
#   GOKAI_FAKE_UPIA_LIST_STATUS Enabled | Disabled   (--list çıktısındaki durum)
#   GOKAI_FAKE_UPIA_NO_PS=1     --list çıktısında Photoshop hiç görünmesin
#   GOKAI_FAKE_UPIA_LOG         çağrıların yazılacağı dosya

EXT="$HOME/Library/Application Support/Adobe/UXP/Plugins/External"
NAME="Photoshop MCP Agent"
DIR="$EXT/${NAME}_0.85.3"
MODE="${GOKAI_FAKE_UPIA_MODE:-ok}"

if [ -n "${GOKAI_FAKE_UPIA_LOG:-}" ]; then echo "$*" >>"$GOKAI_FAKE_UPIA_LOG"; fi

case "${1:-}" in
  --list)
    echo "0 extension installed for Illustrator 2026 (ver 30.8.1)"
    echo " Status                        Extension Name                         Version"
    echo "=========  =======================================================  =========="
    echo ""
    if [ "${GOKAI_FAKE_UPIA_NO_PS:-0}" != "1" ]; then
      n=0; if [ -d "$DIR" ]; then n=1; fi
      echo "$n extension installed for Photoshop 2026 (ver ${GOKAI_TEST_STABLE_PS_VERSION:-27.1.0})"
      echo " Status                        Extension Name                         Version"
      echo "=========  =======================================================  =========="
      if [ "$n" -eq 1 ]; then echo " ${GOKAI_FAKE_UPIA_LIST_STATUS:-Enabled}    $NAME                                      0.85.3"; fi
      echo ""
    fi
    ;;
  --remove)
    echo "Removing $2"
    if [ -d "$DIR" ]; then rm -rf "$DIR"; else echo "Failed to remove $2, status = -406"; fi
    ;;
  --install)
    echo "Installing extension with file path = $2"
    case "$MODE" in
      ok)      mkdir -p "$DIR"; echo '{"id":"Photoshop MCP Agent"}' >"$DIR/manifest.json" ;;
      fail411) echo "Failed to install, status = -411!" ;;
      fail456) echo "Failed to install, status = -456!" ;;
      hang)    exec sleep 600 ;;
      silent)  : ;;
    esac
    ;;
esac
exit 0
