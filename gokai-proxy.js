#!/usr/bin/env node

/*
 * GokAI Proxy — Adobe MCP köprüsü + durum paneli
 *
 * Temel proxy protokolü adb-mcp projesinden alınmıştır:
 * https://github.com/mikechambers/adb-mcp (adb-proxy-socket)
 * Eklentiler ve MCP sunucuları açısından protokol orijinaliyle aynıdır.
 *
 * GokAI eklemeleri:
 *   - Yalnızca bu makineden erişilir (127.0.0.1 / ::1); ağdaki başka cihazlar
 *     ya da ziyaret edilen web sayfaları komut gönderemez.
 *   - Eklenti bağlı değilse komut 20 sn asılı kalmaz; nedenini söyleyen bir
 *     hata hemen döner. Eklenti yeniden bağlanıyorsa kısa süre beklenir.
 *   - Bir uygulama için birden fazla eklenti kaydı varsa komut tek birine
 *     gider (aynı işlem iki kez çalışmaz).
 *   - Hatalı bir paket ya da beklenmeyen bir istisna süreci düşüremez.
 *   - /status, /doctor, durum paneli, günlük boyutu sınırı.
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
const net = require("net");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { execFile } = require("child_process");
const { Server } = require("socket.io");

const VERSION = "3.0.0";
const PORT = parseInt(process.env.GOKAI_PORT || "3001", 10);
const START_TIME = Date.now();

// Kurulu kopyada bu dosya <GokAI>/proxy/ içindedir.
const GOKAI_DIR = process.env.GOKAI_DIR ||
    (path.basename(__dirname) === "proxy"
        ? path.dirname(__dirname)
        : path.join(os.homedir(), "Library/Application Support/GokAI"));

// Eklenti bağlı değilken gelen komut için: uygulama açıksa eklentinin (yeniden)
// bağlanmasını bu kadar bekle. Proxy yeniden başladıktan ya da uykudan sonra
// eklentiler 1-5 sn içinde kendiliğinden geri gelir.
const RECONNECT_GRACE_MS = 6000;
// Komut eklentideyken eklenti bağlantısı koparsa: geri gelmesini bu kadar bekle.
const TARGET_LOST_GRACE_MS = 8000;

function log(message) {
    console.log(new Date().toISOString() + " " + message);
}

// Doktor modülü proxy ile aynı klasörde durur; eksikse proxy yine de çalışsın.
let doctor = null;
try {
    doctor = require("./gokai-doctor.js");
} catch (e) {
    log("uyarı: gokai-doctor.js yüklenemedi (" + e.message + ") — /doctor devre dışı");
}

const APP_PROCESS_RE = (doctor && doctor.APP_PROCESS_RE) || {
    photoshop: /\/Adobe Photoshop[^/]*\.app\/Contents\/MacOS\/Adobe Photoshop[^/]*$/m,
    illustrator: /\/Adobe Illustrator[^/]*\.app\/Contents\/MacOS\/Adobe Illustrator$/m,
};

// Beklenmeyen bir hata bağlı eklentileri düşürmesin: kaydet, çalışmaya devam et.
process.on("uncaughtException", (err) => {
    log("yakalanmamış istisna: " + (err && err.stack || err));
});
process.on("unhandledRejection", (err) => {
    log("yakalanmamış reddetme: " + (err && err.stack || err));
});

// Panelde kişisel selamlama için makine sahibinin adı.
// `id -F` macOS'ta tam adı verir ("Gökay K"); ilk kelimeyi kullanıyoruz.
// Alınamazsa selamlama isimsiz gösterilir — panel yine çalışır.
let OWNER_NAME = "";
execFile("/usr/bin/id", ["-F"], { encoding: "utf8", timeout: 2000 }, (err, stdout) => {
    if (err) return;
    const first = String(stdout).trim().split(/\s+/)[0];
    if (first && first.length <= 24) OWNER_NAME = first;
});

// --- Kimden istek kabul ediyoruz ---------------------------------------------

// Host başlığı yerel değilse isteği reddet: kötü niyetli bir sayfanın alan adını
// 127.0.0.1'e çözdürüp (DNS rebinding) köprüye erişmesini engeller.
function isLocalHostHeader(req) {
    const host = String((req.headers && req.headers.host) || "").toLowerCase();
    const name = host.startsWith("[") ? host.slice(0, host.indexOf("]") + 1) : host.split(":")[0];
    return name === "localhost" || name === "127.0.0.1" || name === "[::1]";
}

// Origin bir web sayfasına aitse (http/https) ve bu panel değilse "yabancı"dır.
// file://, boş ya da http dışı kaynaklar (eklentiler, MCP sunucuları) web sayfası
// değildir.
function isForeignWebOrigin(origin) {
    if (!origin) return false;
    const m = /^https?:\/\/([^/]+)/i.exec(String(origin));
    if (!m) return false;
    const host = m[1].toLowerCase();
    return !(host === "localhost:" + PORT || host === "127.0.0.1:" + PORT || host === "[::1]:" + PORT);
}

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    transports: ["websocket", "polling"],
    maxHttpBufferSize: 50 * 1024 * 1024,
    // Uzun bir işlem sırasında eklentinin JS iş parçacığı bir süre yanıt
    // veremeyebilir; varsayılan 20 sn'lik ping süresi bağlantıyı boşuna koparır.
    // Toplam 70 sn: tek bir komutun azami süresinin (55 sn) biraz üstü. Daha
    // uzun tutma — bu değer, karşı tarafı kaybolmuş bir bağlantının ne kadar
    // geç fark edileceğini de belirler.
    pingInterval: 25000,
    pingTimeout: 45000,
    allowRequest: (req, callback) => callback(null, isLocalHostHeader(req)),
});

// --- adb-mcp proxy protokolü --------------------------------------------------

// uygulama adı -> kayıtlı eklenti soketleri (eskiden yeniye)
const registered = new Map();
// komutu gönderen soket -> { app, targetId, action, at }
const pending = new Map();
// uygulama adı -> eklentinin bağlanmasını bekleyen komutlar
const waiting = new Map();
// GokAI: son görülme zamanları (panel için)
const lastSeen = {};
const stats = { commands: 0, failures: 0, lastCommandAt: null, lastError: null };

const APP_LABEL = { photoshop: "Photoshop", illustrator: "Illustrator" };
// Belirtme hâli ("…'ı açın"): ünlü uyumu uygulamaya göre değişiyor.
const APP_ACCUSATIVE = { photoshop: "Photoshop'u", illustrator: "Illustrator'ı" };
const PLUGIN_MENU = {
    photoshop: "Photoshop'ta Eklentiler › Photoshop MCP Agent panelini açıp Connect'e basın",
    illustrator: "Illustrator'da bir belge açın, sonra Pencere › Uzantılar › Illustrator MCP Agent panelini açın",
};

function labelOf(application) {
    return APP_LABEL[application] || application;
}

// Bir uygulamanın komut gönderilecek eklentisi: hâlâ bağlı olan EN YENİ kayıt.
// Aynı ad için iki kayıt varsa (ör. Photoshop'un normal ve Beta sürümü birlikte
// açık) komut ikisine birden gitmez; orijinal proxy hepsine yolluyordu.
function targetFor(application) {
    const list = registered.get(application);
    if (!list) return null;
    for (let i = list.length - 1; i >= 0; i--) {
        if (io.sockets.sockets.has(list[i])) return list[i];
        list.splice(i, 1);
    }
    if (list.length === 0) registered.delete(application);
    return null;
}

function connectedCount(application) {
    targetFor(application); // ölü kayıtları temizler
    const list = registered.get(application);
    return list ? list.length : 0;
}

function failTo(senderId, application, message) {
    stats.failures++;
    stats.lastError = { at: Date.now(), app: application, message };
    log("hata → " + application + ": " + message);
    // adb-mcp istemcisi status === "FAILURE" görünce message'ı Claude'a iletir.
    io.to(senderId).emit("packet_response", { senderId, status: "FAILURE", message });
}

function deliver(packet, targetId) {
    const action = packet.command && packet.command.action;
    pending.set(packet.senderId, {
        app: packet.application, targetId, action, at: Date.now(),
    });
    log("komut → " + packet.application + ": " + (action || "?"));
    io.to(targetId).emit("command_packet", packet);
}

let runningCache = { at: 0, promise: null };
function runningApps() {
    if (Date.now() - runningCache.at < 1500 && runningCache.promise) return runningCache.promise;
    runningCache = {
        at: Date.now(),
        promise: new Promise((resolve) => {
            execFile("/bin/ps", ["-Ao", "comm="], { encoding: "utf8", timeout: 3000, maxBuffer: 4 * 1024 * 1024 },
                (err, stdout) => {
                    const out = {};
                    for (const k of Object.keys(APP_PROCESS_RE)) {
                        out[k] = !err && APP_PROCESS_RE[k].test(String(stdout));
                    }
                    resolve(out);
                });
        }),
    };
    return runningCache.promise;
}

function dispatch(packet) {
    const application = packet.application;
    const target = targetFor(application);
    if (target) return deliver(packet, target);

    runningApps().then((running) => {
        if (!io.sockets.sockets.has(packet.senderId)) return;   // gönderen vazgeçti
        const now = targetFor(application);
        if (now) return deliver(packet, now);

        const label = labelOf(application);
        if (running[application] === false) {
            return failTo(packet.senderId, application,
                label + " açık değil. " + (APP_ACCUSATIVE[application] || label) +
                " açın; MCP Agent paneli açıkken eklenti kendiliğinden bağlanır. " +
                "(" + (PLUGIN_MENU[application] || "Eklenti panelini açın") + ".)");
        }

        // Uygulama açık: eklenti şu an yeniden bağlanıyor olabilir.
        const entry = { packet, timer: null };
        entry.timer = setTimeout(() => {
            const list = waiting.get(application) || [];
            const i = list.indexOf(entry);
            if (i >= 0) list.splice(i, 1);
            failTo(packet.senderId, application,
                label + " açık ama MCP Agent eklentisi GokAI'ye bağlı değil. " +
                (PLUGIN_MENU[application] || "Eklenti panelini açıp Connect'e basın") +
                ". Durum paneli: http://localhost:" + PORT);
        }, RECONNECT_GRACE_MS);
        if (!waiting.has(application)) waiting.set(application, []);
        waiting.get(application).push(entry);
    });
}

function flushWaiting(application) {
    const list = waiting.get(application);
    if (!list || list.length === 0) return;
    waiting.delete(application);
    const target = targetFor(application);
    for (const entry of list) {
        clearTimeout(entry.timer);
        if (target && io.sockets.sockets.has(entry.packet.senderId)) deliver(entry.packet, target);
    }
}

// Bir işleyicideki hata süreci düşürmesin (hatalı/eksik paketler dahil).
function safe(name, fn) {
    return (...args) => {
        try {
            fn(...args);
        } catch (e) {
            log("işleyici hatası (" + name + "): " + (e && e.stack || e));
        }
    };
}

io.on("connection", (socket) => {
    socket.on("register", safe("register", (payload) => {
        const application = payload && typeof payload.application === "string" ? payload.application : null;
        if (!application) return;

        socket.data.application = application;
        const list = registered.get(application) || [];
        if (!list.includes(socket.id)) list.push(socket.id);
        registered.set(application, list);
        lastSeen[application] = Date.now();
        log("eklenti bağlandı: " + application + " (" + socket.id +
            ", origin=" + (socket.handshake.headers.origin || "-") + ", toplam " + list.length + ")");

        socket.emit("registration_response", {
            type: "registration",
            status: "success",
            message: `Registered for ${application}`,
        });

        // Yanıtı beklenen komutlar yeni bağlantıdan gelebilir.
        for (const p of pending.values()) {
            if (p.app === application && !io.sockets.sockets.has(p.targetId)) p.targetId = socket.id;
        }
        flushWaiting(application);
    }));

    socket.on("command_packet_response", safe("command_packet_response", (payload) => {
        const packet = payload && payload.packet;
        if (!packet || !packet.senderId) {
            log("yanıt paketinde gönderen kimliği yok, atlandı");
            return;
        }
        if (socket.data.application) lastSeen[socket.data.application] = Date.now();
        pending.delete(packet.senderId);
        io.to(packet.senderId).emit("packet_response", packet);
    }));

    socket.on("command_packet", safe("command_packet", (payload) => {
        const application = payload && payload.application;
        const command = payload && payload.command;
        if (typeof application !== "string" || !command) return;

        // Komutları yalnızca yerel MCP sunucuları gönderir. Tarayıcıda açık bir
        // web sayfası WebSocket ile buraya bağlanıp Adobe uygulamasına komut
        // (ör. betik çalıştırma) gönderemesin.
        const origin = socket.handshake.headers.origin;
        if (isForeignWebOrigin(origin)) {
            log("REDDEDİLDİ: yabancı kaynaktan komut (" + origin + ")");
            return failTo(socket.id, application, "Bu kaynaktan komut kabul edilmiyor.");
        }

        stats.commands++;
        stats.lastCommandAt = Date.now();
        dispatch({ senderId: socket.id, application, command });
    }));

    socket.on("disconnect", safe("disconnect", (reason) => {
        // Komut gönderen bir istemciyse: bekleyen kayıtlarını temizle.
        pending.delete(socket.id);
        for (const list of waiting.values()) {
            for (let i = list.length - 1; i >= 0; i--) {
                if (list[i].packet.senderId === socket.id) {
                    clearTimeout(list[i].timer);
                    list.splice(i, 1);
                }
            }
        }

        // Bir eklentiyse: kaydını sil, elindeki komutların sahiplerini bilgilendir.
        const application = socket.data.application;
        if (!application) return;

        const list = registered.get(application);
        if (list) {
            const i = list.indexOf(socket.id);
            if (i >= 0) list.splice(i, 1);
            if (list.length === 0) registered.delete(application);
        }
        lastSeen[application] = Date.now();
        log("eklenti ayrıldı: " + application + " (" + socket.id + ", " + reason + ")");

        const orphaned = [];
        for (const [senderId, p] of pending) if (p.targetId === socket.id) orphaned.push(senderId);
        if (orphaned.length === 0) return;

        // Eklenti meşgulken bağlantısı kısa süreliğine düşmüş olabilir; yeniden
        // bağlanırsa yanıt yine gelir. Geri gelmezse uygulama kapanmış demektir.
        setTimeout(() => {
            for (const senderId of orphaned) {
                const p = pending.get(senderId);
                if (!p || io.sockets.sockets.has(p.targetId)) continue;
                pending.delete(senderId);
                failTo(senderId, application,
                    labelOf(application) + " eklentisinin bağlantısı işlem sırasında koptu " +
                    "(uygulama kapanmış ya da çökmüş olabilir). İşlem tamamlanmamış olabilir; " +
                    "belgeyi kontrol edip yeniden deneyin.");
            }
        }, TARGET_LOST_GRACE_MS);
    }));
});

// --- GokAI: durum API'si ve panel ---------------------------------------------

// Yalnızca yerel Host başlığıyla gelen istekler.
app.use((req, res, next) => {
    if (isLocalHostHeader(req)) return next();
    res.status(403).json({ ok: false, error: "forbidden_host" });
});

// Durumu değiştiren uçlar yalnızca panelin kendisinden (ya da tarayıcı dışı bir
// yerel araçtan) çağrılabilir; başka bir web sayfası proxy'yi yeniden başlatıp
// bağlantıları düşüremesin.
function requireLocalOrigin(req, res, next) {
    if (isForeignWebOrigin(req.get("origin"))) {
        return res.status(403).json({ ok: false, error: "forbidden_origin" });
    }
    next();
}

const CLAUDE_CONFIG_PATH = process.env.GOKAI_CLAUDE_CONFIG || path.join(
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
        const raw = fs.readFileSync(CLAUDE_CONFIG_PATH, "utf8").replace(/^﻿/, "");
        const cfg = JSON.parse(raw);
        const servers = cfg.mcpServers || {};
        const present = Object.keys(servers).filter((k) => k.startsWith("GokAI "));
        const entries = {};
        for (const key of GOKAI_CORE_KEYS) {
            entries[key] = Object.prototype.hasOwnProperty.call(servers, key);
        }
        // Girdi var ama gösterdiği komut bu makinede yoksa Claude sunucuyu açamaz.
        const broken = present.filter((k) => {
            const cmd = servers[k] && servers[k].command;
            return !cmd || !fs.existsSync(cmd);
        });
        return {
            found: true,
            entries,                                        // çekirdek sunucular
            present,                                        // bu makinede kurulu olanlar
            broken,
            photoshopPlugin: present.includes("GokAI Photoshop Plugin"),
        };
    } catch (e) {
        return { found: false, entries: {}, present: [], broken: [], photoshopPlugin: false,
                 error: e.code || String(e) };
    }
}

function readInstallInfo() {
    try {
        return JSON.parse(fs.readFileSync(path.join(GOKAI_DIR, "install.json"), "utf8"));
    } catch (e) {
        return null;
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

// --- Tanı (doktor) ------------------------------------------------------------
// Sonuç bir süre saklanır; aynı anda yalnızca bir tanı çalışır.
let doctorLast = null;     // { at, report }
let doctorRunning = null;

function runDoctorOnce() {
    if (!doctor) return Promise.reject(new Error("doctor_unavailable"));
    if (!doctorRunning) {
        doctorRunning = doctor.runDoctor({ gokaiDir: GOKAI_DIR, port: PORT, claudeConfig: CLAUDE_CONFIG_PATH })
            .then((report) => {
                doctorLast = { at: Date.now(), report };
                if (!report.ok) log("tanı: " + report.counts.fail + " sorun bulundu");
                return report;
            })
            .finally(() => { doctorRunning = null; });
    }
    return doctorRunning;
}

app.get("/status", async (req, res) => {
    const running = await runningApps();
    const apps = {};
    for (const name of ["photoshop", "illustrator"]) {
        const clients = connectedCount(name);
        apps[name] = {
            connected: clients > 0,
            clients,
            lastSeen: lastSeen[name] || null,
            running: !!running[name],
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
        // AppleScript sunucusu proxy'den geçmediği için bağlantı durumu
        // göremiyoruz; en azından uygulamanın açık olup olmadığını bildirelim.
        photoshopRunning: !!running.photoshop,
        claude: readClaudeConfigStatus(),
        install: readInstallInfo(),
        stats: {
            commands: stats.commands,
            failures: stats.failures,
            pending: pending.size,
            lastCommandAt: stats.lastCommandAt,
            lastError: stats.lastError,
        },
        doctor: doctorLast
            ? { at: doctorLast.at, ok: doctorLast.report.ok, counts: doctorLast.report.counts }
            : null,
    });
});

// Tam tanı: MCP sunucularını gerçekten başlatıp el sıkışma yapar (birkaç saniye).
app.get("/doctor", async (req, res) => {
    if (!doctor) return res.status(503).json({ ok: false, error: "doctor_unavailable" });
    const fresh = req.query.fresh === "1";
    if (!fresh && doctorLast && Date.now() - doctorLast.at < 30000) {
        return res.json(doctorLast.report);
    }
    try {
        res.json(await runDoctorOnce());
    } catch (e) {
        res.status(500).json({ ok: false, error: String(e && e.message || e) });
    }
});

app.post("/open/:app", requireLocalOrigin, (req, res) => {
    const key = req.params.app;
    if (!LAUNCHABLE.includes(key)) {
        return res.status(400).json({ ok: false, error: "unknown_app" });
    }
    // Uygulama sonradan kurulmuş olabilir — bulunamazsa bir kez daha tara
    if (!APP_PATHS[key]) APP_PATHS = resolveApps();
    const target = APP_PATHS[key];
    if (!target) return res.status(404).json({ ok: false, error: "not_installed" });

    // execFile: kabuk yok, argüman enjeksiyonu mümkün değil
    execFile("/usr/bin/open", ["-a", target], (err) => {
        if (err) log("GokAI: " + key + " açılamadı: " + err.message);
    });
    log("GokAI: " + key + " açılıyor → " + target);
    res.json({ ok: true, app: key });
});

// launchd KeepAlive=true olduğu için çıkış = temiz yeniden başlatma.
// Eklentiler birkaç saniye içinde kendiliğinden yeniden bağlanır.
app.post("/restart", requireLocalOrigin, (req, res) => {
    res.json({ ok: true, message: "Proxy yeniden başlatılıyor..." });
    log("GokAI: panel üzerinden yeniden başlatma istendi");
    setTimeout(() => process.exit(0), 300);
});

app.use(express.static(path.join(__dirname, "public")));

// --- Günlük boyutu ------------------------------------------------------------
// launchd çıktıyı dosyaya ekleyerek yazar ve dosyayı kendisi döndürmez; aylarca
// açık kalan bir makinede sınırsız büyümesin. (launchd dosyayı O_APPEND ile
// açtığı için kırpmadan sonra yazmaya dosya sonundan devam eder.)
const LOG_FILES = [
    path.join(os.homedir(), "Library/Logs/gokai-proxy.log"),
    path.join(os.homedir(), "Library/Logs/gokai-proxy.error.log"),
];
const LOG_MAX_BYTES = 2 * 1024 * 1024;
const LOG_KEEP_BYTES = 256 * 1024;

function trimLogs() {
    for (const file of LOG_FILES) {
        try {
            const size = fs.statSync(file).size;
            if (size <= LOG_MAX_BYTES) continue;
            const fd = fs.openSync(file, "r");
            const keep = Buffer.alloc(LOG_KEEP_BYTES);
            fs.readSync(fd, keep, 0, LOG_KEEP_BYTES, size - LOG_KEEP_BYTES);
            fs.closeSync(fd);
            const firstNewline = keep.indexOf(0x0a);
            fs.writeFileSync(file, keep.subarray(firstNewline + 1));
        } catch (e) { /* dosya yoksa ya da okunamıyorsa atla */ }
    }
}

// --- Başlatma -------------------------------------------------------------------

function startListening() {
    server.on("error", (err) => {
        if (err.code !== "EADDRINUSE") {
            log("sunucu hatası: " + (err.stack || err));
            return;
        }
        // Port dolu. Dinleyen başka bir GokAI proxy'siyse (ör. MCP başlatıcısının
        // doğrudan açtığı kopya) işimiz yok; değilse sorunu günlüğe yaz. Her iki
        // durumda da hemen çıkma: launchd bizi 10 sn'de bir yeniden başlatıp
        // günlüğü doldurmasın. Bir süre sonra çık ki port boşaldıysa devralalım.
        const req = http.get({ host: "127.0.0.1", port: PORT, path: "/status", timeout: 2000 }, (res) => {
            let body = "";
            res.on("data", (c) => { body += c; });
            res.on("end", () => {
                let other = null;
                try { other = JSON.parse(body); } catch (e) { /* GokAI değil */ }
                if (other && other.ok && other.version) {
                    log("port " + PORT + " başka bir GokAI proxy'si (v" + other.version + ") tarafından kullanılıyor; beklemede");
                } else {
                    log("HATA: port " + PORT + " başka bir program tarafından kullanılıyor — GokAI proxy başlayamıyor");
                }
            });
        });
        req.on("timeout", () => req.destroy());
        req.on("error", () => {
            log("HATA: port " + PORT + " dolu ve yanıt vermiyor — GokAI proxy başlayamıyor");
        });
        setTimeout(() => process.exit(1), 30000);
    });

    // Yalnızca bu makineden erişilsin: 127.0.0.1'i dinle…
    server.listen(PORT, "127.0.0.1", () => {
        log("GokAI proxy v" + VERSION + " çalışıyor: http://localhost:" + PORT + " (ws + panel)");

        // …ve "localhost" adını ::1'e çözen istemciler için IPv6 geri döngüsünü
        // IPv4 dinleyicisine aktar. IPv6 kapalıysa sorun değil; istemciler IPv4'e düşer.
        const v6 = net.createServer((client) => {
            const upstream = net.connect(PORT, "127.0.0.1");
            client.on("error", () => upstream.destroy());
            upstream.on("error", () => client.destroy());
            client.pipe(upstream);
            upstream.pipe(client);
        });
        v6.on("error", (err) => log("IPv6 geri döngü dinleyicisi açılamadı (" + err.code + ") — IPv4 ile devam"));
        v6.listen({ port: PORT, host: "::1", ipv6Only: true });

        trimLogs();
        setInterval(trimLogs, 6 * 3600 * 1000).unref();

        // Açılıştan kısa süre sonra bir tanı çalıştır: sorun varsa panel,
        // kullanıcı Claude'da hatayla karşılaşmadan önce göstersin.
        if (doctor && process.env.GOKAI_NO_STARTUP_DOCTOR !== "1") {
            setTimeout(() => { runDoctorOnce().catch(() => {}); }, 15000).unref();
        }
    });
}

for (const signal of ["SIGTERM", "SIGINT"]) {
    process.on(signal, () => {
        log(signal + " alındı, kapanıyor");
        process.exit(0);
    });
}

startListening();
