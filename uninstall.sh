#!/bin/bash
# GokAI Kaldırma — kurulumun yaptığı her şeyi geri alır.
set -uo pipefail

GOKAI_DIR="$HOME/Library/Application Support/GokAI"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PLIST="$HOME/Library/LaunchAgents/com.gokai.proxy.plist"

echo "[GokAI] Arka plan servisi durduruluyor..."
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "[GokAI] Claude Desktop yapılandırmasından GokAI girdileri siliniyor..."
NODE_BIN="$GOKAI_DIR/node/bin/node"
if [ -x "$NODE_BIN" ] && [ -f "$CLAUDE_CONFIG" ]; then
  cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.gokai-uninstall-backup"
  CLAUDE_CONFIG="$CLAUDE_CONFIG" "$NODE_BIN" -e '
    const fs = require("fs");
    const p = process.env.CLAUDE_CONFIG;
    const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
    for (const k of ["GokAI Photoshop","GokAI Photoshop Plugin","GokAI Illustrator","GokAI InDesign"])
      delete (cfg.mcpServers || {})[k];
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
    console.log("  GokAI girdileri silindi (diğer ayarlar korundu)");
  '
fi

echo "[GokAI] Dosyalar siliniyor..."
rm -rf "$GOKAI_DIR"
rm -rf "$HOME/Applications/GokAI.app"
rm -f "$HOME/Library/Logs/gokai-proxy.log" "$HOME/Library/Logs/gokai-proxy.error.log"

echo "[GokAI] Kaldırma tamamlandı. (UXP/CEP eklentileri elle kaldırılmalı.)"
