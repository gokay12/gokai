// Başlatıcının launchd kurtarma yolları (test modu KAPALI).
// Geçici bir etiket kullanır: com.gokai.proxy-test, port 3907.
// Kullanıcının launchd alanına geçici bir servis yükler ve test sonunda kaldırır.
//
// GokAI testlerinin parçası — tests/run.sh üzerinden çalıştırılır.
// GOKAI_SANDBOX_HOME: `GOKAI_TEST_MODE=1` ile kurulmuş sahte ev klasörü.
// Gerçek kuruluma (3001 portu, com.gokai.proxy servisi, Claude ayarları) dokunmaz.
const path = require("path");
const H = process.env.GOKAI_SANDBOX_HOME;
if (!H) { console.error("GOKAI_SANDBOX_HOME gerekli (tests/run.sh kullanın)"); process.exit(2); }
const G = path.join(H, "Library/Application Support/GokAI");
const { spawn, execFileSync } = require("child_process");
const fs = require("fs");
const http = require("http");
const os = require("os");
const PY = G + "/venv/bin/python";
const LABEL = "com.gokai.proxy-test";
const PORT = 3907;
const UID = os.userInfo().uid;
const PLIST = os.homedir() + "/Library/LaunchAgents/" + LABEL + ".plist";   // başlatıcı burada arar
const SRC_PLIST = path.join(H, "Library/LaunchAgents/com.gokai.proxy.plist");   // kurulumun ürettiği plist

let passed = 0, failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function check(name, cond, extra) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (extra !== undefined ? "\n        " + String(extra).slice(0, 500) : "")); }
}
const sh = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); } catch (e) { return ""; } };
const loaded = () => sh("/bin/launchctl", ["print", "gui/" + UID + "/" + LABEL]).includes("state =");
const listenerPid = () => (sh("/usr/sbin/lsof", ["-nP", "-tiTCP:" + PORT, "-sTCP:LISTEN"]).trim().split("\n")[0] || "");
function status() {
    return new Promise((resolve) => {
        const req = http.get({ host: "127.0.0.1", port: PORT, path: "/status", timeout: 1500 }, (res) => {
            let b = ""; res.on("data", (c) => b += c); res.on("end", () => { try { resolve(JSON.parse(b)); } catch (e) { resolve(null); } });
        });
        req.on("error", () => resolve(null)); req.on("timeout", () => { req.destroy(); resolve(null); });
    });
}
class Mcp {
    constructor() {
        this.buf = ""; this.w = new Map(); this.id = 0; this.stderr = "";
        // GOKAI_TEST_MODE yok: başlatıcı launchctl kullanır
        this.child = spawn(PY, ["-I", G + "/mcp/gokai_mcp.py", "photoshop"], {
            env: { HOME: os.homedir(), PATH: "/usr/bin:/bin", GOKAI_PORT: String(PORT), GOKAI_SERVICE_LABEL: LABEL, GOKAI_DIR: G },
            stdio: ["pipe", "pipe", "pipe"],
        });
        this.child.stderr.on("data", (c) => this.stderr += c);
        this.child.stdout.on("data", (c) => {
            this.buf += c; let nl;
            while ((nl = this.buf.indexOf("\n")) >= 0) {
                const line = this.buf.slice(0, nl).trim(); this.buf = this.buf.slice(nl + 1);
                let m; try { m = JSON.parse(line); } catch (e) { continue; }
                if (m.id && this.w.has(m.id)) { this.w.get(m.id)(m); this.w.delete(m.id); }
            }
        });
    }
    req(method, params) { const id = ++this.id; return new Promise((res) => { this.w.set(id, res); this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); }); }
    async init() { await this.req("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "1" } }); this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n"); }
    async call(name) { const t0 = Date.now(); const r = await this.req("tools/call", { name, arguments: {} }); const res = r.result || {}; return { isError: !!res.isError, text: (res.content || []).map((c) => c.text || "").join(" "), ms: Date.now() - t0 }; }
    close() { try { this.child.stdin.end(); } catch (e) {} }
}
function cleanup() {
    sh("/bin/launchctl", ["bootout", "gui/" + UID + "/" + LABEL]);
    try { fs.unlinkSync(PLIST); } catch (e) {}
}

(async () => {
    cleanup();
    // test plist'i: kurulumun ürettiği plist + test etiketi + test portu
    fs.copyFileSync(SRC_PLIST, PLIST);
    for (const c of ["Set :Label " + LABEL, "Add :EnvironmentVariables dict", "Add :EnvironmentVariables:GOKAI_PORT string " + PORT, "Add :EnvironmentVariables:GOKAI_NO_STARTUP_DOCTOR string 1"]) {
        execFileSync("/usr/libexec/PlistBuddy", ["-c", c, PLIST]);
    }

    console.log("\n== A. Servis launchd'de YÜKLÜ DEĞİL (ör. bir temizlik uygulaması kaldırmış) ==");
    check("başlangıç: servis yüklü değil, port kapalı", !loaded() && !(await status()));
    const a = new Mcp();
    await a.init();
    let r = await a.call("get_documents");
    check("araç çağrısı proxy'ye ulaştı (başlatıcı servisi kendisi yükledi)", r.isError && /Photoshop açık değil/.test(r.text), r.ms + " ms: " + r.text + "\n" + a.stderr.slice(-300));
    check("servis artık launchd'de yüklü ve çalışıyor", loaded() && !!(await status()));
    console.log("        (ilk çağrı " + r.ms + " ms sürdü; sonraki çağrılar anında)");

    console.log("\n== B. Proxy TAKILDI (port açık ama yanıt vermiyor) ==");
    const pid1 = listenerPid();
    process.kill(parseInt(pid1, 10), "SIGSTOP");      // süreci dondur
    await sleep(500);
    check("proxy donduruldu: port açık, HTTP yanıt yok", !(await status()) && listenerPid() === pid1);
    r = await a.call("get_documents");
    const pid2 = listenerPid();
    check("başlatıcı takılan proxy'yi yeniden başlattı, komut ulaştı", r.isError && /Photoshop açık değil/.test(r.text) && pid2 && pid2 !== pid1, r.ms + " ms, pid " + pid1 + "→" + pid2 + ": " + r.text + "\n" + a.stderr.slice(-300));
    console.log("        (kurtarma dahil çağrı süresi: " + r.ms + " ms)");

    console.log("\n== C. Servis DEVRE DIŞI bırakılmış + kaldırılmış ==");
    sh("/bin/launchctl", ["bootout", "gui/" + UID + "/" + LABEL]);
    sh("/bin/launchctl", ["disable", "gui/" + UID + "/" + LABEL]);
    await sleep(1500);
    check("servis devre dışı ve kapalı", !loaded() && !(await status()));
    const c = new Mcp();
    await c.init();
    r = await c.call("get_documents");
    check("başlatıcı servisi yeniden etkinleştirip başlattı", r.isError && /Photoshop açık değil/.test(r.text) && !!(await status()), r.ms + " ms: " + r.text + "\n" + c.stderr.slice(-300));
    a.close(); c.close();

    cleanup();
    sh("/bin/launchctl", ["enable", "gui/" + UID + "/" + LABEL]);   // devre dışı kaydını geri al
    await sleep(1000);
    // launchd kaldırılsa bile doğrudan başlatılmış bir kopya kalmış olabilir
    const left = listenerPid();
    if (left) { try { process.kill(parseInt(left, 10), "SIGTERM"); } catch (e) {} }
    await sleep(500);
    check("temizlik: test servisi ve plist kaldırıldı, port boş", !loaded() && !fs.existsSync(PLIST) && !listenerPid());
    console.log("\n" + (failed === 0 ? "TÜM TESTLER GEÇTİ" : failed + " TEST BAŞARISIZ") + " (" + passed + " geçti, " + failed + " kaldı)\n");
    process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.error("TEST ÇATISI HATASI", e); cleanup(); process.exit(2); });
