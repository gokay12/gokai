#!/usr/bin/env node

/*
 * GokAI Proxy — Adobe MCP köprüsü + durum paneli
 *
 * Temel proxy mantığı adb-mcp projesinden alınmıştır:
 * https://github.com/mikechambers/adb-mcp (adb-proxy-socket)
 * GokAI eklentileri: /status API, web durum paneli, /restart ucu.
 *
 * Orijinal kod lisansı:
 *
 * MIT License
 *
 * Copyright (c) 2025 Mike Chambers
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

const express = require("express");
const http = require("http");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    transports: ["websocket", "polling"],
    maxHttpBufferSize: 50 * 1024 * 1024,
});

const PORT = 3001;
const START_TIME = Date.now();
const VERSION = "1.1.0";

// Panelde kişisel selamlama için makine sahibinin adı.
// `id -F` macOS'ta tam adı verir ("Gökay K"); ilk kelimeyi kullanıyoruz.
// Alınamazsa selamlama isimsiz gösterilir — panel yine çalışır.
const OWNER_NAME = (() => {
    try {
        const full = require("child_process")
            .execSync("id -F", { encoding: "utf8", timeout: 2000 })
            .trim();
        const first = full.split(/\s+/)[0];
        return first && first.length <= 24 ? first : "";
    } catch (e) {
        return "";
    }
})();

// --- adb-mcp proxy protokolü (orijinaliyle birebir aynı) -------------------

const applicationClients = {};
// GokAI: son görülme zamanları (panel için)
const lastSeen = {};

io.on("connection", (socket) => {
    console.log(`User connected: ${socket.id}`);

    socket.on("register", ({ application }) => {
        console.log(`Client ${socket.id} registered for application: ${application}`);
        socket.data.application = application;
        if (!applicationClients[application]) {
            applicationClients[application] = new Set();
        }
        applicationClients[application].add(socket.id);
        lastSeen[application] = Date.now();

        socket.emit("registration_response", {
            type: "registration",
            status: "success",
            message: `Registered for ${application}`,
        });
    });

    socket.on("command_packet_response", ({ packet }) => {
        const senderId = packet.senderId;
        if (senderId) {
            io.to(senderId).emit("packet_response", packet);
            console.log(`Sent confirmation to client ${senderId}`);
        } else {
            console.log(`No sender ID provided in packet`);
        }
    });

    socket.on("command_packet", ({ application, command }) => {
        console.log(`Command from ${socket.id} for application ${application}:`, command);
        let packet = { senderId: socket.id, application: application, command: command };
        sendToApplication(packet);
    });

    socket.on("disconnect", () => {
        console.log(`User disconnected: ${socket.id}`);
        for (const app in applicationClients) {
            applicationClients[app].delete(socket.id);
            if (applicationClients[app].size === 0) {
                delete applicationClients[app];
            }
        }
    });
});

function sendToApplication(packet) {
    let application = packet.application;
    if (applicationClients[application]) {
        console.log(`Sending to ${applicationClients[application].size} clients for ${application}`);
        applicationClients[application].forEach((clientId) => {
            io.to(clientId).emit("command_packet", packet);
        });
        return true;
    }
    console.log(`No clients registered for application: ${application}`);
    return false;
}

// --- GokAI: durum API'si ve panel ------------------------------------------

const CLAUDE_CONFIG_PATH = path.join(
    os.homedir(),
    "Library/Application Support/Claude/claude_desktop_config.json"
);

// Her makinede aynı sunucular olmayabilir: Photoshop Beta'da UXP eklentisi
// kurulamadığı için "GokAI Photoshop Plugin" hiç eklenmez. Bu yüzden sabit bir
// liste beklemek yerine yapılandırmada NE VARSA onu bildiriyoruz; panel de
// gösterilecek kartları buna göre belirliyor.
const GOKAI_CORE_KEYS = ["GokAI Photoshop", "GokAI Illustrator"];

function readClaudeConfigStatus() {
    try {
        const raw = fs.readFileSync(CLAUDE_CONFIG_PATH, "utf8");
        const cfg = JSON.parse(raw);
        const servers = cfg.mcpServers || {};
        const present = Object.keys(servers).filter((k) => k.startsWith("GokAI "));
        const entries = {};
        for (const key of GOKAI_CORE_KEYS) {
            entries[key] = Object.prototype.hasOwnProperty.call(servers, key);
        }
        return {
            found: true,
            entries,                                        // çekirdek sunucular
            present,                                        // bu makinede kurulu olanlar
            photoshopPlugin: present.includes("GokAI Photoshop Plugin"),
        };
    } catch (e) {
        return { found: false, entries: {}, present: [], photoshopPlugin: false,
                 error: e.code || String(e) };
    }
}

// --- Uygulama başlatma ------------------------------------------------------
// Panelden çift tıklayınca uygulamayı açmak için. Tarayıcı doğrudan uygulama
// başlatamaz, bu yüzden proxy yapıyor. Güvenlik: sabit beyaz liste (kullanıcıdan
// gelen isim/yol asla `open`'a geçmez) + Origin kontrolü (kötü niyetli bir web
// sayfası localhost'a POST atıp uygulama açtıramasın).
const LAUNCHABLE = ["photoshop", "illustrator", "claude"];

// Uygulama yollarını dosya sisteminden çöz. Kabuk kullanmıyoruz: "Adobe
// Photoshop 2026" gibi boşluklu klasör adları glob'da bozuluyor.
function resolveApps() {
    const found = {};
    let entries = [];
    try { entries = fs.readdirSync("/Applications"); } catch (e) { return found; }

    // Klasör ya da doğrudan .app olabilir; sürümlü klasörse içindeki .app'i al
    const pick = (matches) => {
        const hits = entries.filter(matches).sort();
        // Beta ve normal sürüm birlikteyse normal olanı tercih et
        hits.sort((a, b) => (a.includes("(Beta)") ? 1 : 0) - (b.includes("(Beta)") ? 1 : 0));
        for (const e of hits) {
            const full = "/Applications/" + e;
            if (e.endsWith(".app")) return full;
            try {
                const inner = fs.readdirSync(full).find((f) => f.endsWith(".app"));
                if (inner) return full + "/" + inner;
            } catch (e2) { /* okunamadı, sıradakine geç */ }
        }
        return null;
    };

    const ps = pick((e) => e.startsWith("Adobe Photoshop"));
    const ai = pick((e) => e.startsWith("Adobe Illustrator"));
    const cl = pick((e) => e === "Claude.app");
    if (ps) found.photoshop = ps;
    if (ai) found.illustrator = ai;
    if (cl) found.claude = cl;
    return found;
}
let APP_PATHS = resolveApps();

// Photoshop açık mı? AppleScript sunucusu proxy'den geçmediği için bağlantı
// durumu göremiyoruz; en azından uygulamanın çalışıp çalışmadığını bildirelim.
function isPhotoshopRunning() {
    try {
        require("child_process").execSync(
            'pgrep -f "Adobe Photoshop [0-9]" >/dev/null 2>&1',
            { timeout: 2000 }
        );
        return true;
    } catch (e) {
        return false;
    }
}

app.get("/status", (req, res) => {
    const apps = {};
    for (const name of ["photoshop", "illustrator"]) {
        apps[name] = {
            connected: !!(applicationClients[name] && applicationClients[name].size > 0),
            clients: applicationClients[name] ? applicationClients[name].size : 0,
            lastSeen: lastSeen[name] || null,
        };
    }
    res.json({
        ok: true,
        version: VERSION,
        port: PORT,
        uptimeSec: Math.floor((Date.now() - START_TIME) / 1000),
        apps,
        owner: OWNER_NAME,
        launchable: Object.keys(APP_PATHS),
        photoshopRunning: isPhotoshopRunning(),
        claude: readClaudeConfigStatus(),
    });
});

app.post("/open/:app", express.json(), (req, res) => {
    // Sadece kendi panelimizden gelen istekleri kabul et
    const origin = req.get("origin") || "";
    if (origin && !/^http:\/\/(localhost|127\.0\.0\.1):3001$/.test(origin)) {
        return res.status(403).json({ ok: false, error: "forbidden_origin" });
    }
    const key = req.params.app;
    if (!LAUNCHABLE.includes(key)) {
        return res.status(400).json({ ok: false, error: "unknown_app" });
    }
    // Uygulama sonradan kurulmuş olabilir — bulunamazsa bir kez daha tara
    if (!APP_PATHS[key]) APP_PATHS = resolveApps();
    const target = APP_PATHS[key];
    if (!target) return res.status(404).json({ ok: false, error: "not_installed" });

    // execFile: kabuk yok, argüman enjeksiyonu mümkün değil
    require("child_process").execFile("/usr/bin/open", ["-a", target], (err) => {
        if (err) console.log(`GokAI: ${key} açılamadı: ${err.message}`);
    });
    console.log(`GokAI: ${key} açılıyor → ${target}`);
    res.json({ ok: true, app: key });
});

// launchd KeepAlive=true olduğu için çıkış = temiz yeniden başlatma
app.post("/restart", (req, res) => {
    res.json({ ok: true, message: "Proxy yeniden başlatılıyor..." });
    console.log("GokAI: panel üzerinden yeniden başlatma istendi");
    setTimeout(() => process.exit(0), 300);
});

app.use(express.static(path.join(__dirname, "public")));

server.listen(PORT, () => {
    console.log(`GokAI proxy çalışıyor: http://localhost:${PORT} (ws + panel)`);
});
