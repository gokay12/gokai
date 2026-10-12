#!/usr/bin/env node
/*
 * GokAI Doktor — uçtan uca tanı
 *
 * Kurulumu, arka plan servisini, Claude Desktop yapılandırmasını, Adobe
 * eklentilerini ve MCP sunucularını kontrol eder. MCP sunucularını Claude'un
 * çalıştırdığı komutla GERÇEKTEN başlatıp el sıkışma yapar; "dosya yerinde mi"
 * diye bakmakla yetinmez.
 *
 * Bağımlılığı yoktur (yalnızca Node çekirdeği): tek dosya olarak indirilip
 * eski/bozuk bir kurulumun üzerinde de çalıştırılabilir.
 *
 * Kullanım:
 *   node gokai-doctor.js            okunabilir rapor (sorun varsa çıkış kodu 1)
 *   node gokai-doctor.js --json     JSON çıktı
 *   node gokai-doctor.js --quick    MCP el sıkışmasını ve günlük taramasını atla
 */

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { spawn, execFile } = require("child_process");

const DOCTOR_VERSION = "2.0.1";
const SERVICE_LABEL = "com.gokai.proxy";
// Kurulum betiği yeni sürümü önce hazırlayıp dener, sonra yerine koyar; bu yüzden
// onarım için de güvenle çalıştırılabilir (reset.sh'ın aksine önce silmez).
const FIX_CMD =
    "curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash";

// Illustrator CEP eklentisinin manifest'i 28.0 (2024) ve üzerini hedefliyor.
const MIN_ILLUSTRATOR_MAJOR = 28;
// Photoshop UXP eklentisinin (.ccx) manifest'i 26.0 (2025) ve üzerini hedefliyor.
const MIN_PHOTOSHOP_PLUGIN_MAJOR = 26;
// Adobe'nin eklenti kurucusu (Creative Cloud ile gelir).
const UPIA_PATH = "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/" +
    "UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent";

// ------------------------------------------------------------------ yollar ---

function resolvePaths(opts = {}) {
    const home = os.homedir();
    return {
        home,
        gokai: opts.gokaiDir || process.env.GOKAI_DIR ||
            path.join(home, "Library/Application Support/GokAI"),
        claudeConfig: opts.claudeConfig || process.env.GOKAI_CLAUDE_CONFIG ||
            path.join(home, "Library/Application Support/Claude/claude_desktop_config.json"),
        claudeLogs: opts.claudeLogDir || process.env.GOKAI_CLAUDE_LOG_DIR ||
            path.join(home, "Library/Logs/Claude"),
        plist: path.join(home, "Library/LaunchAgents", SERVICE_LABEL + ".plist"),
        cepExt: path.join(home, "Library/Application Support/Adobe/CEP/extensions/com.mikechambers.ai"),
        uxpExternal: path.join(home, "Library/Application Support/Adobe/UXP/Plugins/External"),
        port: opts.port || parseInt(process.env.GOKAI_PORT || "3001", 10),
        testMode: process.env.GOKAI_TEST_MODE === "1",
    };
}

// --------------------------------------------------------------- yardımcılar ---

function run(cmd, args, timeoutMs = 4000) {
    return new Promise((resolve) => {
        execFile(cmd, args, { timeout: timeoutMs, encoding: "utf8", maxBuffer: 4 * 1024 * 1024 },
            (err, stdout, stderr) => {
                resolve({
                    ok: !err,
                    code: err ? (typeof err.code === "number" ? err.code : -1) : 0,
                    out: (stdout || "").trim(),
                    err: (stderr || "").trim(),
                });
            });
    });
}

function exists(p) {
    try { fs.accessSync(p); return true; } catch (e) { return false; }
}

function isExecutable(p) {
    try { fs.accessSync(p, fs.constants.X_OK); return fs.statSync(p).isFile(); } catch (e) { return false; }
}

function readJson(p) {
    // Bazı düzenleyiciler dosyanın başına BOM ekliyor; JSON.parse bunu kabul etmez.
    const raw = fs.readFileSync(p, "utf8").replace(/^\uFEFF/, "");
    return JSON.parse(raw);
}

function httpGetJson(url, timeoutMs = 3000) {
    return new Promise((resolve) => {
        let done = false;
        const finish = (v) => { if (!done) { done = true; resolve(v); } };
        try {
            const req = http.get(url, { timeout: timeoutMs }, (res) => {
                let body = "";
                res.setEncoding("utf8");
                res.on("data", (c) => { body += c; });
                res.on("end", () => {
                    try { finish({ ok: res.statusCode === 200, status: res.statusCode, json: JSON.parse(body) }); }
                    catch (e) { finish({ ok: false, status: res.statusCode, error: "geçersiz yanıt" }); }
                });
            });
            req.on("timeout", () => { req.destroy(); finish({ ok: false, error: "zaman aşımı" }); });
            req.on("error", (e) => finish({ ok: false, error: e.code || e.message }));
        } catch (e) {
            finish({ ok: false, error: e.message });
        }
    });
}

function fmtMs(ms) {
    return ms < 1000 ? ms + " ms" : (ms / 1000).toFixed(1) + " sn";
}

function tail(text, lines) {
    const arr = String(text || "").split("\n").filter((l) => l.trim() !== "");
    return arr.slice(-lines).join("\n");
}

// Normal (Beta olmayan) Photoshop uygulamaları. Klasörün var olması yetmez:
// kaldırılmış bir sürümden kalan boş "Adobe Photoshop 2025" klasörü sayılmaz;
// Elements ve Lightroom da "Adobe Photoshop …" adını taşır ama Photoshop değildir.
function stablePhotoshopApps() {
    const out = [];
    let names = [];
    try { names = fs.readdirSync("/Applications"); } catch (e) { return out; }
    for (const n of names) {
        if (!/^Adobe Photoshop/.test(n) || /\(Beta\)|Elements|Lightroom/.test(n)) continue;
        const dir = "/Applications/" + n;
        let inner = [];
        try { inner = fs.readdirSync(dir); } catch (e) { continue; }
        for (const f of inner) {
            if (/^Adobe Photoshop.*\.app$/.test(f) && exists(path.join(dir, f, "Contents/MacOS"))) {
                out.push(path.join(dir, f));
            }
        }
    }
    return out;
}

// Adobe uygulamaları çalışıyor mu? Hem normal hem Beta sürümleri yakalar
// ("Adobe Photoshop 2026" ve "Adobe Photoshop (Beta)").
const APP_PROCESS_RE = {
    photoshop: /\/Adobe Photoshop[^/]*\.app\/Contents\/MacOS\/Adobe Photoshop[^/]*$/m,
    illustrator: /\/Adobe Illustrator[^/]*\.app\/Contents\/MacOS\/Adobe Illustrator$/m,
};

async function runningApps() {
    const ps = await run("/bin/ps", ["-Ao", "comm="]);
    const out = {};
    for (const k of Object.keys(APP_PROCESS_RE)) out[k] = APP_PROCESS_RE[k].test(ps.out);
    return out;
}

// ------------------------------------------------- bilinen hata imzaları ---
// Hem el sıkışma hatalarında hem Claude günlük taramasında kullanılır.

const SIGNATURES = [
    {
        id: "pydantic",
        re: /cannot import name 'eval_type_backport'/,
        title: "Python paket uyumsuzluğu (mcp 1.5.0 ↔ pydantic 2.14+)",
        detail: "Sunucu her açılışta paketleri internetten çözüyor; yeni çıkan pydantic sürümü mcp 1.5.0 ile uyumsuz olduğu için sunucu açılırken çöküyor.",
    },
    {
        id: "pypi-offline",
        re: /Failed to fetch: `https:\/\/pypi\.org|error sending request for url \(https:\/\/pypi\.org|failed to lookup address information/,
        title: "Açılışta internet gerekti ve ulaşılamadı (PyPI)",
        detail: "Sunucu açılırken Python paketlerini indirmeye çalıştı; o an internet yoktu.",
    },
    {
        id: "npx-race",
        re: /npm error code ENOTEMPTY/,
        title: "npx önbellek çakışması (ENOTEMPTY)",
        detail: "Claude sunucunun iki kopyasını aynı anda başlattı; ikisi de npx önbelleğini güncellemeye çalışıp çakıştı.",
    },
    {
        id: "npm-network",
        re: /npm error (?:code )?(?:ENOTFOUND|ETIMEDOUT|ECONNRESET|EAI_AGAIN|ECONNREFUSED|E40\d|E50\d)/,
        title: "Açılışta internet gerekti ve ulaşılamadı (npm)",
        detail: "Sunucu açılırken npm'den paket indirmeye çalıştı ve başaramadı.",
    },
    {
        id: "python-version",
        re: /does not satisfy Python>=3\.10|No solution found when resolving/,
        title: "Yanlış Python sürümü seçildi",
        detail: "uv sistemdeki eski Python'u (3.9) seçti; adb-mcp 3.10+ istiyor.",
    },
    {
        id: "fastmcp-missing",
        re: /No module named 'mcp\.server\.fastmcp'/,
        title: "mcp paketi uyumsuz sürüme yükselmiş",
        detail: "mcp paketi sabitlenmediği için fastmcp modülü olmayan yeni sürüm kurulmuş.",
    },
    {
        id: "module-missing",
        re: /ModuleNotFoundError: No module named '([^']+)'/,
        title: "Python modülü eksik",
        detail: "Sunucunun Python ortamı eksik ya da bozuk.",
    },
    {
        id: "spawn-enoent",
        re: /spawn .* ENOENT|No such file or directory \(os error 2\)/,
        title: "Sunucu komutu bulunamadı",
        detail: "Claude yapılandırmasındaki komut yolu bu makinede yok.",
    },
    {
        id: "slow-start",
        re: /Not ready after 60 seconds|Error: Request timed out/,
        title: "Sunucu 60 saniyede açılamadı",
        detail: "Sunucu açılışta paket indirip çözmeye çalışırken Claude'un bekleme süresi doldu.",
    },
];

function matchSignature(text) {
    for (const s of SIGNATURES) {
        const m = s.re.exec(text || "");
        if (m) return { ...s, match: m[1] || null };
    }
    return null;
}

// ------------------------------------------------------- MCP el sıkışması ---
// Sunucuyu Claude Desktop'ın yaptığı gibi başlatır: aynı komut, aynı argümanlar,
// aynı env; stdio üzerinden initialize → tools/list. Araç listesi geldiyse
// sunucu Claude'da da açılır.

function mcpHandshake(entry, opts = {}) {
    const timeoutMs = opts.timeoutMs || 30000;
    const started = Date.now();

    return new Promise((resolve) => {
        const result = {
            ok: false, ms: 0, toolCount: 0, serverName: null, protocolVersion: null,
            error: null, stderrTail: "", stdoutNoise: 0,
        };
        let settled = false;
        let child = null;
        let stderr = "";
        let buf = "";
        let timer = null;

        const finish = (ok, error) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            result.ok = ok;
            result.error = error || null;
            result.ms = Date.now() - started;
            result.stderrTail = tail(stderr, 12);
            // Nazikçe kapat: stdin'i kapatınca stdio sunucuları kendiliğinden çıkar.
            if (child) {
                try { child.stdin.end(); } catch (e) { /* zaten kapalı */ }
                const pid = child.pid;
                setTimeout(() => { try { process.kill(pid, "SIGTERM"); } catch (e) { /* çıkmış */ } }, 1500).unref();
                setTimeout(() => { try { process.kill(pid, "SIGKILL"); } catch (e) { /* çıkmış */ } }, 4000).unref();
            }
            resolve(result);
        };

        if (!entry || !entry.command) return finish(false, "yapılandırmada komut yok");
        if (!exists(entry.command)) return finish(false, "komut bulunamadı: " + entry.command);

        // Claude Desktop Dock'tan açıldığında kabuk ortamı yoktur; yalın bir
        // ortamla denemek PATH'e gizli bağımlılıkları da yakalar.
        const env = {
            HOME: os.homedir(),
            USER: os.userInfo().username,
            LOGNAME: os.userInfo().username,
            TMPDIR: os.tmpdir(),
            PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
            LANG: process.env.LANG || "en_US.UTF-8",
        };
        for (const k of ["GOKAI_PORT", "GOKAI_TEST_MODE", "GOKAI_NO_AUTOSTART", "GOKAI_DIR"]) {
            if (process.env[k]) env[k] = process.env[k];
        }
        Object.assign(env, entry.env || {}, opts.extraEnv || {});

        try {
            child = spawn(entry.command, entry.args || [], { env, stdio: ["pipe", "pipe", "pipe"] });
        } catch (e) {
            return finish(false, "başlatılamadı: " + e.message);
        }

        timer = setTimeout(() => finish(false, fmtMs(timeoutMs) + " içinde yanıt vermedi"), timeoutMs);

        child.on("error", (e) => finish(false, "başlatılamadı: " + (e.code || e.message)));
        child.on("exit", (code, signal) => {
            if (!settled) finish(false, "sunucu açılırken kapandı (çıkış kodu " + (code === null ? signal : code) + ")");
        });
        child.stdin.on("error", () => { /* sunucu erken kapandıysa EPIPE gelir; exit zaten yakalıyor */ });
        child.stderr.setEncoding("utf8");
        child.stderr.on("data", (c) => { stderr = (stderr + c).slice(-20000); });

        const send = (obj) => { try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch (e) { /* exit yakalar */ } };

        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk) => {
            buf += chunk;
            let nl;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line) continue;
                let msg;
                try { msg = JSON.parse(line); } catch (e) { result.stdoutNoise++; continue; }
                if (msg.id === 1) {
                    if (msg.error) return finish(false, "initialize reddedildi: " + (msg.error.message || "hata"));
                    result.protocolVersion = msg.result && msg.result.protocolVersion;
                    result.serverName = msg.result && msg.result.serverInfo && msg.result.serverInfo.name;
                    send({ jsonrpc: "2.0", method: "notifications/initialized" });
                    send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
                } else if (msg.id === 2) {
                    if (msg.error) return finish(false, "tools/list reddedildi: " + (msg.error.message || "hata"));
                    const tools = (msg.result && msg.result.tools) || [];
                    result.toolCount = tools.length;
                    if (tools.length === 0) return finish(false, "sunucu açıldı ama hiç araç bildirmedi");
                    return finish(true);
                }
            }
        });

        send({
            jsonrpc: "2.0", id: 1, method: "initialize",
            params: {
                protocolVersion: "2024-11-05",
                capabilities: {},
                clientInfo: { name: "gokai-doctor", version: DOCTOR_VERSION },
            },
        });
    });
}

// Bir Claude yapılandırma girdisinin NASIL başlatıldığını sınıflandırır.
function classifyEntry(entry) {
    const cmd = (entry && entry.command) || "";
    const base = path.basename(cmd);
    const args = (entry && entry.args) || [];
    if (base === "uv" || base === "uvx") return "legacy-uv";
    if (base === "npx" || base === "npm") return "legacy-npx";
    if (args.some((a) => /gokai_mcp\.py$/.test(String(a)))) return "locked-python";
    if (base === "node" && args.some((a) => /photoshop-mcp\/dist\/index\.js$/.test(String(a)))) return "locked-node";
    return "unknown";
}

// ------------------------------------------------------- günlük taraması ---

function scanClaudeLog(file, cutoffMs) {
    const out = { file, hits: {}, lastStart: null, lastDisconnect: null, lastOk: null };
    let text;
    try {
        const st = fs.statSync(file);
        const size = Math.min(st.size, 800 * 1024);
        const fd = fs.openSync(file, "r");
        const b = Buffer.alloc(size);
        fs.readSync(fd, b, 0, size, st.size - size);
        fs.closeSync(fd);
        text = b.toString("utf8");
    } catch (e) {
        return out;
    }
    const tsRe = /^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)/;
    let ts = 0;
    for (const line of text.split("\n")) {
        const m = tsRe.exec(line);
        if (m) ts = Date.parse(m[1]) || ts;
        if (!ts || ts < cutoffMs) continue;

        if (/Server started and connected successfully/.test(line)) out.lastStart = ts;
        if (/Message from server: id=\d+ result/.test(line)) out.lastOk = ts;
        if (/Server disconnected\. For troubleshooting guidance|Couldn't start (this server )?for Cowork and Code sessions/.test(line)) {
            out.lastDisconnect = ts;
        }
        const sig = matchSignature(line);
        if (sig) {
            const h = out.hits[sig.id] || (out.hits[sig.id] = { sig, count: 0, last: 0 });
            h.count++;
            h.last = ts;
        }
    }
    return out;
}

function fmtDate(ms) {
    if (!ms) return "?";
    const d = new Date(ms);
    const p = (n) => String(n).padStart(2, "0");
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
}

// ------------------------------------------------------------------ doktor ---

async function runDoctor(opts = {}) {
    const P = resolvePaths(opts);
    const deep = opts.deep !== false;
    const checks = [];
    const add = (group, status, title, detail, fix) => {
        checks.push({ group, status, title, detail: detail || "", fix: fix || "" });
    };

    // ---- Sistem -----------------------------------------------------------
    const G_SYS = "Sistem";
    const sw = await run("/usr/bin/sw_vers", ["-productVersion"]);
    const arm = await run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"]);
    const arch = arm.ok && arm.out === "1" ? "Apple Silicon" : "Intel";
    add(G_SYS, "info", "macOS " + (sw.out || "?") + " · " + arch + " · kullanıcı " + os.userInfo().username);
    const macMajor = parseInt((sw.out || "0").split(".")[0], 10);
    if (macMajor && macMajor < 12) {
        add(G_SYS, "warn", "macOS sürümü eski (" + sw.out + ")",
            "Güncel Adobe uygulamaları ve Python paketleri macOS 12+ bekliyor.");
    }
    try {
        const st = fs.statfsSync(P.home);
        const freeGb = (st.bavail * st.bsize) / 1e9;
        if (freeGb < 1.5) {
            add(G_SYS, "fail", "Disk dolmak üzere (" + freeGb.toFixed(1) + " GB boş)",
                "Kurulum ve sunucular düzgün çalışmak için boş alan ister.", "Diskte en az 2 GB yer açın.");
        } else {
            add(G_SYS, "ok", "Boş disk alanı: " + freeGb.toFixed(0) + " GB");
        }
    } catch (e) { /* statfs yoksa (çok eski Node) atla */ }

    // ---- Kurulum ----------------------------------------------------------
    const G_INST = "Kurulum";
    let install = null;
    const nodeBin = path.join(P.gokai, "node/bin/node");
    const venvPy = path.join(P.gokai, "venv/bin/python");
    const adbMcp = path.join(P.gokai, "adb-mcp/mcp");
    const launcher = path.join(P.gokai, "mcp/gokai_mcp.py");
    const psPkg = path.join(P.gokai, "photoshop-mcp/node_modules/@alisaitteke/photoshop-mcp");
    let legacyInstall = false;
    // Hiç kurulu değilse tek bir net sonuç ver; "servis yok, config yok…" diye
    // aynı nedeni on kez tekrarlama.
    // (Yarıda kalmış bir ilk kurulum boş bir klasör bırakabilir; o da "kurulu değil"dir.)
    const notInstalled = !exists(path.join(P.gokai, "install.json")) &&
        !exists(path.join(P.gokai, "proxy", "gokai-proxy.js"));

    if (notInstalled) {
        add(G_INST, "fail", "GokAI bu makinede kurulu değil", P.gokai + " bulunamadı.", FIX_CMD);
    } else {
        try { install = readJson(path.join(P.gokai, "install.json")); } catch (e) { install = null; }
        if (install) {
            add(G_INST, "ok", "GokAI v" + install.version + " kurulu",
                "kurulum: " + fmtDate(Date.parse(install.installedAt)) +
                " · adb-mcp " + String(install.adbMcpCommit || "?").slice(0, 7) +
                " · photoshop-mcp " + (install.photoshopMcp || "?"));
        } else {
            legacyInstall = true;
            add(G_INST, "fail", "Eski GokAI sürümü kurulu (v1.x)",
                "Bu sürüm MCP sunucularını her Claude açılışında internetten çözüyor; paket sürümleri kilitli değil. " +
                "Yeni bir paket sürümü çıktığında ya da internet yokken sunucular açılmıyor.",
                FIX_CMD);
        }

        // Node
        if (isExecutable(nodeBin)) {
            const v = await run(nodeBin, ["-v"]);
            if (v.ok) add(G_INST, "ok", "Node.js " + v.out + " (özel kopya)");
            else add(G_INST, "fail", "Node.js çalışmıyor", v.err || "node -v başarısız", FIX_CMD);
        } else {
            add(G_INST, "fail", "Node.js bulunamadı", nodeBin, FIX_CMD);
        }

        if (!legacyInstall) {
            // Python ortamı: kilitli sürümler gerçekten içe aktarılabiliyor mu?
            if (isExecutable(venvPy)) {
                const code =
                    "import sys, importlib.metadata as m\n" +
                    "import mcp, pydantic, numpy, PIL, socketio, requests, websocket, fontTools\n" +
                    "from mcp.server.fastmcp import FastMCP, Image\n" +
                    "print(sys.version.split()[0], m.version('mcp'), pydantic.VERSION, numpy.__version__)\n";
                const r = await run(venvPy, ["-I", "-c", code], 30000);
                if (r.ok) {
                    const [py, mcpV, pyd, np] = r.out.split(/\s+/);
                    add(G_INST, "ok", "Python " + py + " ortamı sağlam",
                        "mcp " + mcpV + " · pydantic " + pyd + " · numpy " + np + " (kilitli sürümler)");
                } else {
                    const sig = matchSignature(r.err);
                    add(G_INST, "fail", "Python ortamı bozuk" + (sig ? ": " + sig.title : ""),
                        tail(r.err, 3), FIX_CMD);
                }
            } else {
                add(G_INST, "fail", "Python ortamı bulunamadı", venvPy, FIX_CMD);
            }

            const missing = ["ai-mcp.py", "ps-mcp.py", "socket_client.py", "core.py"]
                .filter((f) => !exists(path.join(adbMcp, f)));
            if (missing.length) add(G_INST, "fail", "adb-mcp dosyaları eksik", missing.join(", "), FIX_CMD);
            else add(G_INST, "ok", "adb-mcp kaynakları yerinde");

            if (!exists(launcher)) add(G_INST, "fail", "MCP başlatıcı bulunamadı", launcher, FIX_CMD);

            try {
                const pkg = readJson(path.join(psPkg, "package.json"));
                if (install && install.photoshopMcp && pkg.version !== install.photoshopMcp) {
                    add(G_INST, "warn", "photoshop-mcp sürümü beklenenden farklı",
                        "kurulu " + pkg.version + ", beklenen " + install.photoshopMcp);
                } else {
                    add(G_INST, "ok", "photoshop-mcp " + pkg.version + " (yerel, sabit sürüm)");
                }
                if (!exists(path.join(psPkg, "dist/index.js"))) {
                    add(G_INST, "fail", "photoshop-mcp eksik kurulmuş", "dist/index.js yok", FIX_CMD);
                }
            } catch (e) {
                add(G_INST, "fail", "photoshop-mcp bulunamadı", psPkg, FIX_CMD);
            }
        }
    }

    // ---- Arka plan servisi --------------------------------------------------
    const G_SVC = "Arka plan servisi";
    const uid = os.userInfo().uid;
    let status = null;

    const st4 = notInstalled ? { ok: false } : await httpGetJson("http://127.0.0.1:" + P.port + "/status");
    if (notInstalled) {
        // kurulum yok: servis kontrolleri anlamsız
    } else if (st4.ok && st4.json && st4.json.ok) {
        status = st4.json;
        const stale = status.version !== DOCTOR_VERSION;
        add(G_SVC, stale ? "warn" : "ok",
            "Proxy yanıt veriyor (v" + status.version + ", port " + P.port + ")",
            stale ? "Çalışan proxy eski sürüm; bu doktor v" + DOCTOR_VERSION + ". Yeniden kurulum önerilir."
                  : "çalışma süresi " + Math.floor((status.uptimeSec || 0) / 60) + " dk",
            stale ? FIX_CMD : "");
    } else {
        add(G_SVC, "fail", "Proxy yanıt vermiyor (port " + P.port + ")",
            "http://127.0.0.1:" + P.port + "/status → " + (st4.error || "HTTP " + st4.status),
            "Bilgisayarı yeniden başlatın; düzelmezse: " + FIX_CMD);
    }

    // Eklentiler "localhost" adını kullanıyor; ad çözümlemesi bozuksa bağlanamazlar.
    const stL = status ? await httpGetJson("http://localhost:" + P.port + "/status") : { ok: false };
    if (status && !(stL.ok && stL.json && stL.json.ok)) {
        add(G_SVC, "fail", "'localhost' adı proxy'ye ulaşmıyor",
            "127.0.0.1 çalışıyor ama localhost çalışmıyor (" + (stL.error || "hata") + "). Adobe eklentileri localhost'u kullanır.",
            "/etc/hosts dosyasında '127.0.0.1 localhost' satırının bulunduğunu kontrol edin.");
    }

    // Portu kim dinliyor?
    const lsof = await run("/usr/sbin/lsof", ["-nP", "-iTCP:" + P.port, "-sTCP:LISTEN", "-Fpc"]);
    const pids = [...new Set((lsof.out.match(/^p(\d+)$/gm) || []).map((s) => s.slice(1)))];
    for (const pid of pids) {
        const ps = await run("/bin/ps", ["-o", "command=", "-p", pid]);
        if (ps.out && !/gokai-proxy\.js/.test(ps.out)) {
            add(G_SVC, "fail", "Port " + P.port + " başka bir program tarafından kullanılıyor",
                "PID " + pid + ": " + ps.out.slice(0, 120),
                "O programı kapatın, sonra: " + FIX_CMD);
        }
    }

    if (notInstalled) {
        // kurulum yok
    } else if (P.testMode) {
        add(G_SVC, "info", "launchd kontrolleri atlandı (test modu)");
    } else {
        if (!exists(P.plist)) {
            add(G_SVC, "fail", "Otomatik başlatma kaydı yok", P.plist + " bulunamadı.", FIX_CMD);
        }
        const lc = await run("/bin/launchctl", ["print", "gui/" + uid + "/" + SERVICE_LABEL]);
        if (lc.ok) {
            const state = (/^\s*state = (.+)$/m.exec(lc.out) || [])[1] || "?";
            const lastExit = (/last exit code = (.+)$/m.exec(lc.out) || [])[1] || "";
            if (state === "running") add(G_SVC, "ok", "launchd servisi çalışıyor (oturum açılışında otomatik başlar)");
            else add(G_SVC, "fail", "launchd servisi çalışmıyor (durum: " + state + ")",
                lastExit ? "son çıkış kodu: " + lastExit : "",
                "launchctl kickstart -k gui/" + uid + "/" + SERVICE_LABEL);
        } else {
            add(G_SVC, "fail", "launchd servisi yüklü değil",
                "Servis oturum açılışında başlamayacak.", FIX_CMD);
        }
        const dis = await run("/bin/launchctl", ["print-disabled", "gui/" + uid]);
        if (new RegExp('"' + SERVICE_LABEL.replace(/\./g, "\\.") + '" => (disabled|true)').test(dis.out)) {
            add(G_SVC, "fail", "Servis devre dışı bırakılmış",
                "Bir temizlik/optimizasyon uygulaması GokAI servisini kapatmış olabilir.",
                "launchctl enable gui/" + uid + "/" + SERVICE_LABEL + " && " + FIX_CMD);
        }
    }

    // ---- Claude Desktop -----------------------------------------------------
    const G_CL = "Claude Desktop";
    let gokaiEntries = {};
    let cfgOk = false;
    if (notInstalled && !exists(P.claudeConfig)) {
        // kurulum yok; Claude hiç açılmamış da olabilir
    } else if (!exists(P.claudeConfig)) {
        add(G_CL, "fail", "Claude yapılandırması bulunamadı", P.claudeConfig, FIX_CMD);
    } else {
        try {
            const cfg = readJson(P.claudeConfig);
            cfgOk = true;
            const servers = (cfg && cfg.mcpServers) || {};
            for (const k of Object.keys(servers)) if (k.startsWith("GokAI ")) gokaiEntries[k] = servers[k];
        } catch (e) {
            add(G_CL, "fail", "Claude yapılandırması geçersiz JSON",
                String(e.message).slice(0, 160),
                "Dosyayı düzeltin ya da yedekten geri yükleyin (aynı klasörde *.gokai-backup-*).");
        }
    }

    const stablePsApps = stablePhotoshopApps();
    // (Yalnızca test: normal Photoshop'u olan bir makineyi taklit et.)
    const fakeStablePs = P.testMode ? (process.env.GOKAI_TEST_STABLE_PS_VERSION || "") : "";
    const hasStablePs = stablePsApps.length > 0 || !!fakeStablePs;

    if (cfgOk) {
        const names = Object.keys(gokaiEntries);
        if (names.length === 0 && notInstalled) {
            // kurulum yok: girdi olmaması beklenen durum
        } else if (names.length === 0) {
            add(G_CL, "fail", "Yapılandırmada GokAI sunucusu yok",
                "Kurulum sırasında Claude açık kaldıysa Claude yapılandırmayı geri yazmış olabilir.",
                "Claude Desktop'ı Cmd+Q ile kapatın, sonra: " + FIX_CMD);
        }
        for (const need of ["GokAI Photoshop", "GokAI Illustrator"]) {
            if (names.length && !names.includes(need)) {
                add(G_CL, "fail", "'" + need + "' girdisi eksik", "", FIX_CMD);
            }
        }
        for (const name of names) {
            const e = gokaiEntries[name];
            const kind = classifyEntry(e);
            if (!e.command || !isExecutable(e.command)) {
                add(G_CL, "fail", name + ": komut bulunamadı", String(e.command), FIX_CMD);
                continue;
            }
            const missingArg = (e.args || []).find((a) => /^\//.test(String(a)) && !exists(String(a)));
            if (missingArg) {
                add(G_CL, "fail", name + ": dosya bulunamadı", missingArg, FIX_CMD);
                continue;
            }
            if (kind === "legacy-uv") {
                add(G_CL, "fail", name + ": açılışta internetten çözülüyor (uv run --with)",
                    "Paket sürümleri kilitli değil. Yeni bir sürüm çıktığında ya da internet yokken sunucu açılmaz; " +
                    "Claude 'Server disconnected / troubleshooting' hatası gösterir.", FIX_CMD);
            } else if (kind === "legacy-npx") {
                add(G_CL, "fail", name + ": her açılışta npm'den indiriliyor (npx -y)",
                    "İnternet yokken açılmaz; Claude iki kopya başlattığında önbellek çakışır (ENOTEMPTY).", FIX_CMD);
            } else if (kind === "unknown") {
                add(G_CL, "warn", name + ": tanınmayan başlatma komutu", path.basename(e.command) + " " + (e.args || []).join(" ").slice(0, 100));
            } else {
                add(G_CL, "ok", name + ": yerel ve kilitli (açılışta internet gerekmez)");
            }
        }

        // Claude yapılandırmayı yalnızca açılışta okur. (Dosyanın değişme zamanına
        // bakmıyoruz: Claude kendi tercihlerini de bu dosyaya yazıyor.)
        const psl = await run("/bin/ps", ["-Ao", "lstart=,comm="]);
        const cl = psl.out.split("\n").find((l) => /Applications\/Claude\.app\/Contents\/MacOS\/Claude$/.test(l));
        const installedAtMs = install ? Date.parse(install.installedAt) || 0 : 0;
        if (cl && installedAtMs) {
            const startedAt = Date.parse(cl.trim().slice(0, 24));
            if (startedAt && installedAtMs > startedAt) {
                add(G_CL, "warn", "Claude Desktop yeniden başlatılmalı",
                    "Claude, son GokAI kurulumundan önce açılmış; yeni sunucuları ancak yeniden açılınca görür.",
                    "Claude Desktop'ı Cmd+Q ile tamamen kapatıp yeniden açın.");
            }
        }
    }

    // ---- MCP sunucuları (gerçek el sıkışma) -----------------------------------
    const G_MCP = "MCP sunucuları";
    if (deep && cfgOk) {
        const names = Object.keys(gokaiEntries);
        // AppleScript tabanlı Photoshop sunucusu, önbelleğinde Photoshop kaydı varsa
        // açılır açılmaz Photoshop'a sorgu atıyor. Tanı sırasında bunu istemiyoruz
        // (izin penceresi çıkarabilir); geçici bir durum klasörü vererek sunucunun
        // Photoshop'a dokunmadan açılmasını sağlıyoruz. Telemetri de gönderilmez.
        const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "gokai-doctor-"));
        const results = await Promise.all(names.map((name) => {
            const kind = classifyEntry(gokaiEntries[name]);
            // Eski tarz girdiler açılışta paket indirir; onlara daha uzun süre tanı.
            const timeoutMs = kind.startsWith("legacy") ? 90000 : 30000;
            const extraEnv = (kind === "locked-node" || kind === "legacy-npx")
                ? { PHOTOSHOP_MCP_HOME: scratch, ANALYTICS_DISABLED: "1", PSMCP_UPDATE_CHECK: "0" }
                : {};
            return mcpHandshake(gokaiEntries[name], { timeoutMs, extraEnv });
        }));
        const cleanup = () => { try { fs.rmSync(scratch, { recursive: true, force: true }); } catch (e) { /* kalabilir */ } };
        process.once("exit", cleanup);
        setTimeout(() => { cleanup(); process.removeListener("exit", cleanup); }, 6000).unref();
        names.forEach((name, i) => {
            const r = results[i];
            if (r.ok) {
                const slow = r.ms > 10000;
                add(G_MCP, slow ? "warn" : "ok",
                    name + ": açıldı, " + r.toolCount + " araç (" + fmtMs(r.ms) + ")",
                    slow ? "Açılış yavaş; Claude 60 saniyede açılmayan sunucuyu bırakır." : "");
                if (r.stdoutNoise > 0) {
                    add(G_MCP, "warn", name + ": stdout'a protokol dışı çıktı yazıyor",
                        r.stdoutNoise + " satır. Bazı istemcilerde bağlantıyı bozabilir.");
                }
            } else {
                const sig = matchSignature(r.stderrTail);
                add(G_MCP, "fail",
                    name + ": AÇILAMADI — " + (sig ? sig.title : r.error),
                    (sig ? sig.detail + "\n" : "") + (r.stderrTail ? tail(r.stderrTail, 4) : r.error),
                    FIX_CMD);
            }
        });
    } else if (!deep) {
        add(G_MCP, "info", "El sıkışma testi atlandı (--quick)");
    }

    // ---- Adobe ----------------------------------------------------------------
    const G_AD = "Adobe";
    let apps = [];
    try { apps = fs.readdirSync("/Applications"); } catch (e) { /* okunamadı */ }
    const findApp = (prefix) => {
        const out = [];
        for (const n of apps.filter((x) => x.startsWith(prefix))) {
            const full = "/Applications/" + n;
            if (n.endsWith(".app")) { out.push(full); continue; }
            try {
                const inner = fs.readdirSync(full).find((f) => f.endsWith(".app") && f.startsWith(prefix));
                if (inner) out.push(full + "/" + inner);
            } catch (e) { /* okunamadı */ }
        }
        return out;
    };
    const appVersion = async (appPath) => {
        const r = await run("/usr/bin/defaults", ["read", appPath + "/Contents/Info", "CFBundleShortVersionString"]);
        return r.ok ? r.out : "?";
    };

    const aiApps = findApp("Adobe Illustrator");
    if (aiApps.length === 0) {
        add(G_AD, "warn", "Illustrator kurulu değil", "GokAI Illustrator sunucusu açılır ama kullanılamaz.");
    } else {
        for (const a of aiApps) {
            const v = await appVersion(a);
            const major = parseInt(v.split(".")[0], 10);
            if (major && major < MIN_ILLUSTRATOR_MAJOR) {
                add(G_AD, "fail", "Illustrator " + v + " çok eski",
                    "MCP Agent eklentisi Illustrator " + MIN_ILLUSTRATOR_MAJOR + " (2024) ve üzerinde yüklenir.",
                    "Illustrator'ı Creative Cloud'dan güncelleyin.");
            } else {
                add(G_AD, "ok", "Illustrator " + v);
            }
        }

        // CEP eklentisi
        let real = null;
        try { real = fs.realpathSync(P.cepExt); } catch (e) { real = null; }
        if (notInstalled) {
            // kurulum yok
        } else if (!real || !exists(path.join(real, "index.html"))) {
            add(G_AD, "fail", "Illustrator eklentisi kurulu değil", P.cepExt, FIX_CMD);
        } else {
            let html = "";
            try { html = fs.readFileSync(path.join(real, "index.html"), "utf8"); } catch (e) { /* okunamadı */ }
            if (/<script[^>]+src=["']https?:\/\//i.test(html)) {
                add(G_AD, "fail", "Illustrator eklentisi Socket.IO'yu internetten yüklüyor",
                    "İnternet yokken ya da CDN engelliyken eklentide Connect'e basmak hiçbir şey yapmaz.", FIX_CMD);
            } else if (!exists(path.join(real, "lib/socket.io.min.js"))) {
                add(G_AD, "fail", "Illustrator eklentisinin Socket.IO dosyası eksik", "lib/socket.io.min.js", FIX_CMD);
            } else {
                add(G_AD, "ok", "Illustrator eklentisi kurulu (çevrimdışı çalışır)");
            }
        }

        // İmzasız CEP eklentileri yalnızca PlayerDebugMode açıkken yüklenir.
        const on = [];
        for (let v = 9; v <= 16; v++) {
            const r = await run("/usr/bin/defaults", ["read", "com.adobe.CSXS." + v, "PlayerDebugMode"]);
            if (r.ok && r.out === "1") on.push(v);
        }
        if (notInstalled) {
            // kurulum yok
        } else if (!on.includes(11) || !on.includes(12)) {
            add(G_AD, "fail", "CEP PlayerDebugMode kapalı",
                "Açık olanlar: " + (on.length ? on.map((v) => "CSXS." + v).join(", ") : "yok") +
                ". Kapalıyken Illustrator eklentiyi menüde göstermez.", FIX_CMD);
        } else {
            add(G_AD, "ok", "CEP PlayerDebugMode açık");
        }
    }

    const psApps = findApp("Adobe Photoshop");
    if (psApps.length === 0) {
        add(G_AD, "warn", "Photoshop kurulu değil");
    } else {
        for (const a of psApps) add(G_AD, "ok", path.basename(a, ".app").replace("Adobe ", "") + " " + (await appVersion(a)));
        if (notInstalled) {
            // kurulum yok
        } else if (hasStablePs) {
            let found = false;
            try { found = fs.readdirSync(P.uxpExternal).some((n) => /Photoshop MCP Agent/i.test(n)); } catch (e) { found = false; }

            // Kurulu normal Photoshop'ların en yükseği
            let stableVersion = fakeStablePs;
            for (const a of stablePsApps) {
                const v = await appVersion(a);
                if (parseInt(v, 10) > (parseInt(stableVersion, 10) || 0)) stableVersion = v;
            }
            const major = parseInt(stableVersion, 10) || 0;

            // Adobe'nin kurucusu ne diyor: Photoshop'u tanıyor mu, eklenti kayıtlı mı?
            const upia = P.testMode ? (process.env.GOKAI_TEST_UPIA || "") : UPIA_PATH;
            const hasUpia = !!upia && isExecutable(upia);
            let listing = "";
            if (hasUpia) listing = (await run(upia, ["--list", "all"], 20000)).out;
            const knowsPhotoshop = listing ? /installed for (Adobe )?Photoshop/i.test(listing) : null;
            const row = listing.split("\n").find((l) => /Photoshop MCP Agent/i.test(l)) || "";
            const disabled = /^\s*disabled/i.test(row);

            const record = (install && install.photoshopPlugin) || null;
            // Uzaktan teşhis için: Adobe'nin kurucusu hangi Photoshop'u görüyor?
            const seen = (listing.match(/installed for ((?:Adobe )?Photoshop[^\n]*)/gi) || [])
                .map((l) => l.replace(/^installed for /i, "").trim());
            const facts = "Kurulu Photoshop: " + (stableVersion || "?") +
                (hasUpia ? " · Adobe kurucusunun gördüğü: " + (seen.length ? seen.join(", ") : "Photoshop yok") : "") + ".";
            const fallbackNote = facts + "\n'GokAI Photoshop' (AppleScript) sunucusu eklentisiz çalışır; eksik olan 'GokAI Photoshop Plugin'.";

            if (found && disabled) {
                add(G_AD, "warn", "Photoshop eklentisi (UXP) kurulu ama devre dışı",
                    "", "Creative Cloud uygulaması › Stock ve Market Yeri › Eklentiler › Eklentileri yönet bölümünden \"Photoshop MCP Agent\" eklentisini etkinleştirin.");
            } else if (found) {
                add(G_AD, "ok", "Photoshop eklentisi (UXP) kurulu");
            } else if (major && major < MIN_PHOTOSHOP_PLUGIN_MAJOR) {
                add(G_AD, "warn", "Photoshop eklentisi (UXP) kurulamaz: Photoshop " + stableVersion + " eski",
                    "Eklenti Photoshop 2025 (v" + MIN_PHOTOSHOP_PLUGIN_MAJOR + ") ve üzerinde yüklenir. " + fallbackNote,
                    "Photoshop'u Creative Cloud'dan güncelleyin, sonra: " + FIX_CMD);
            } else if (!hasUpia) {
                add(G_AD, "warn", "Photoshop eklentisi (UXP) kurulu değil: Adobe eklenti kurucusu yok",
                    "Creative Cloud uygulaması kurulu ve güncel mi? " + fallbackNote,
                    "Creative Cloud'u kurun/güncelleyin, sonra: " + FIX_CMD);
            } else if (knowsPhotoshop === false) {
                add(G_AD, "warn", "Photoshop eklentisi (UXP) kurulu değil: Creative Cloud bu Photoshop'u tanımıyor",
                    "Adobe'nin eklenti kurucusu ürün listesinde Photoshop'u göstermiyor; bu yüzden eklentiyi kuramıyor. " + fallbackNote,
                    "Creative Cloud uygulamasını açıp oturum açın ve Photoshop'u oradan güncelleyin/onarın, sonra: " + FIX_CMD);
            } else {
                add(G_AD, "warn", "Photoshop eklentisi (UXP) kurulu değil",
                    ((record && record.note) ? "Son kurulumda: " + record.note + "\n" : "") + fallbackNote,
                    "Photoshop'u kapatıp kurulumu tekrar çalıştırın: " + FIX_CMD);
            }
        } else {
            add(G_AD, "info", "Yalnızca Photoshop Beta var — AppleScript sunucusu kullanılıyor (eklenti gerekmez)");
        }
    }

    // Eklentilerin canlı bağlantı durumu
    const running = await runningApps();
    if (status && status.apps) {
        const label = { illustrator: "Illustrator", photoshop: "Photoshop" };
        for (const key of ["illustrator", "photoshop"]) {
            const a = status.apps[key];
            if (!a) continue;
            if (key === "photoshop" && !gokaiEntries["GokAI Photoshop Plugin"]) continue;
            if (a.connected) {
                add(G_AD, "ok", label[key] + " eklentisi bağlı");
            } else if (running[key]) {
                add(G_AD, "warn", label[key] + " açık ama eklenti bağlı değil",
                    "",
                    key === "illustrator"
                        ? "Illustrator'da bir belge açın → Pencere › Uzantılar › Illustrator MCP Agent"
                        : "Photoshop'ta Eklentiler › Photoshop MCP Agent → Connect");
            } else {
                add(G_AD, "info", label[key] + " kapalı (açılınca eklenti kendiliğinden bağlanır)");
            }
        }
    }

    // ---- Claude günlükleri ------------------------------------------------------
    const G_LOG = "Claude günlükleri";
    if (deep) {
        // Son kurulumdan ÖNCEKİ hatalar zaten çözülmüş sayılır; yeniden raporlama.
        const installedAt = install ? Date.parse(install.installedAt) || 0 : 0;
        const cutoff = installedAt || Date.now() - 14 * 24 * 3600 * 1000;
        let files = [];
        try {
            files = fs.readdirSync(P.claudeLogs)
                .filter((n) => /^mcp-server-GokAI .*\.log$/.test(n))
                .map((n) => path.join(P.claudeLogs, n));
        } catch (e) { files = []; }

        let anyHit = false;
        for (const f of files) {
            const name = path.basename(f).replace(/^mcp-server-/, "").replace(/\.log$/, "");
            if (cfgOk && !gokaiEntries[name]) continue;   // artık yapılandırmada olmayan sunucu
            const s = scanClaudeLog(f, cutoff);
            const ids = Object.keys(s.hits);
            const failedLast = s.lastDisconnect && (!s.lastOk || s.lastDisconnect > s.lastOk);
            for (const id of ids) {
                const h = s.hits[id];
                anyHit = true;
                add(G_LOG, "fail",
                    name + ": " + h.sig.title + " (" + h.count + " kez, son: " + fmtDate(h.last) + ")",
                    h.sig.detail, FIX_CMD);
            }
            if (failedLast && ids.length === 0) {
                anyHit = true;
                add(G_LOG, "fail", name + ": Claude'un son başlatma denemesi başarısız (" + fmtDate(s.lastDisconnect) + ")",
                    "Claude 'Server disconnected / troubleshooting' hatası gösterdi. Ayrıntı: " + f, FIX_CMD);
            } else if (s.lastOk && !failedLast) {
                add(G_LOG, "ok", name + ": Claude en son başarıyla bağlandı (" + fmtDate(s.lastOk) + ")");
            }
        }
        if (!anyHit && files.length === 0) add(G_LOG, "info", "GokAI sunucu günlüğü bulunamadı (Claude henüz açılmamış olabilir)");
        else if (!anyHit) add(G_LOG, "ok", installedAt ? "Son kurulumdan beri hata kaydı yok" : "Son 14 günde hata kaydı yok");
    }

    const counts = { ok: 0, warn: 0, fail: 0, info: 0 };
    for (const c of checks) counts[c.status]++;
    return {
        version: DOCTOR_VERSION,
        generatedAt: new Date().toISOString(),
        ok: counts.fail === 0,
        counts,
        checks,
        fix: counts.fail > 0 ? FIX_CMD : "",
    };
}

// ------------------------------------------------------------------- rapor ---

function formatReport(report, color = true) {
    const c = (code, s) => (color ? "\x1b[" + code + "m" + s + "\x1b[0m" : s);
    const mark = { ok: c("32", "✓"), warn: c("33", "!"), fail: c("31", "✗"), info: c("90", "·") };
    const lines = [];
    lines.push("");
    lines.push(c("1", "  GokAI Doktor v" + report.version) + c("90", "  ·  " + fmtDate(Date.parse(report.generatedAt))));
    let group = null;
    for (const ch of report.checks) {
        if (ch.group !== group) {
            group = ch.group;
            lines.push("");
            lines.push(c("1;35", "  " + group));
        }
        lines.push("    " + mark[ch.status] + " " + (ch.status === "fail" ? c("1", ch.title) : ch.title));
        if (ch.detail && ch.status !== "ok") {
            for (const l of ch.detail.split("\n")) lines.push(c("90", "        " + l));
        } else if (ch.detail) {
            lines.push(c("90", "        " + ch.detail));
        }
        if (ch.fix && ch.fix !== report.fix) lines.push("        " + c("36", "→ " + ch.fix));
    }
    lines.push("");
    const n = report.counts;
    if (n.fail === 0 && n.warn === 0) {
        lines.push(c("1;32", "  Her şey yolunda.") + c("90", "  (" + n.ok + " kontrol)"));
    } else if (n.fail === 0) {
        lines.push(c("1;33", "  Çalışıyor, " + n.warn + " uyarı var.") + c("90", "  (" + n.ok + " kontrol sorunsuz)"));
    } else {
        lines.push(c("1;31", "  " + n.fail + " sorun bulundu") + (n.warn ? c("33", ", " + n.warn + " uyarı") : "") + ".");
        lines.push("");
        lines.push("  Çözüm — Claude Desktop, Photoshop ve Illustrator'ı kapatıp şunu çalıştırın:");
        lines.push("    " + c("36", report.fix));
    }
    lines.push("");
    return lines.join("\n");
}

module.exports = {
    DOCTOR_VERSION, FIX_CMD, APP_PROCESS_RE, runDoctor, formatReport, mcpHandshake, classifyEntry,
    matchSignature, runningApps,
};

if (require.main === module) {
    const args = process.argv.slice(2);
    const json = args.includes("--json");
    const quick = args.includes("--quick");
    runDoctor({ deep: !quick }).then((report) => {
        if (json) process.stdout.write(JSON.stringify(report, null, 2) + "\n");
        else process.stdout.write(formatReport(report, process.stdout.isTTY || args.includes("--color")));
        process.exit(report.ok ? 0 : 1);
    }).catch((e) => {
        process.stderr.write("GokAI Doktor çalışamadı: " + (e && e.stack || e) + "\n");
        process.exit(2);
    });
}
