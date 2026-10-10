// Illustrator CEP paneli (GokAI sürümü): gerçek bir Chromium'da; CSInterface sahte.
//
// GokAI testlerinin parçası — tests/run.sh üzerinden çalıştırılır.
// GOKAI_SANDBOX_HOME: `GOKAI_TEST_MODE=1` ile kurulmuş sahte ev klasörü.
// Gerçek kuruluma (3001 portu, com.gokai.proxy servisi, Claude ayarları) dokunmaz.
const path = require("path");
const H = process.env.GOKAI_SANDBOX_HOME;
if (!H) { console.error("GOKAI_SANDBOX_HOME gerekli (tests/run.sh kullanın)"); process.exit(2); }
const G = path.join(H, "Library/Application Support/GokAI");
const { spawn } = require("child_process");
const http = require("http");
const fs = require("fs");
const os = require("os");

// Tarayıcı testi isteğe bağlı bir geliştirme bağımlılığı ister:
//   GOKAI_TEST_PUPPETEER = puppeteer-core modül klasörü
//   GOKAI_TEST_CHROME    = chrome / chrome-headless-shell çalıştırılabilir dosyası
const PPTR = process.env.GOKAI_TEST_PUPPETEER, CHROME = process.env.GOKAI_TEST_CHROME;
if (!PPTR || !CHROME || !fs.existsSync(PPTR) || !fs.existsSync(CHROME)) {
    console.log("\nATLANDI: panel testi için GOKAI_TEST_PUPPETEER ve GOKAI_TEST_CHROME gerekli\n");
    process.exit(0);
}
const puppeteer = require(PPTR);
const SB = G;
const SBHOME = H;
const NODE = SB + "/node/bin/node";
const PY = SB + "/venv/bin/python";
const PORT = 3907;

// KURULU eklenti klasörünün kopyası: yalnızca CSInterface sahte, port test portu.
const PANEL = fs.mkdtempSync(path.join(os.tmpdir(), "gokai-panel-"));
fs.cpSync(fs.realpathSync(path.join(H, "Library/Application Support/Adobe/CEP/extensions/com.mikechambers.ai")), PANEL, { recursive: true });
fs.writeFileSync(PANEL + "/main.js", fs.readFileSync(PANEL + "/main.js", "utf8").replace("http://localhost:3001", "http://localhost:" + PORT));
fs.writeFileSync(PANEL + "/lib/CSInterface.js", `
window.__evalCalls = []; window.__evalDelay = 0;
var SystemPath = { EXTENSION: "extension" };
function CSInterface() {}
CSInterface.prototype.getSystemPath = function () { return "/stub"; };
CSInterface.prototype.evalScript = function (script, cb) {
    window.__evalCalls.push(script.slice(0, 60));
    setTimeout(function () { if (cb) cb(JSON.stringify([{ name: "stub.ai" }])); }, window.__evalDelay);
};`);
process.on("exit", () => { try { fs.rmSync(PANEL, { recursive: true, force: true }); } catch (e) {} });

let passed = 0, failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function check(name, cond, extra) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (extra !== undefined ? "\n        " + String(extra).slice(0, 500) : "")); }
}
function status() {
    return new Promise((resolve) => {
        const req = http.get({ host: "127.0.0.1", port: PORT, path: "/status", timeout: 2000 }, (res) => {
            let b = ""; res.on("data", (c) => b += c); res.on("end", () => { try { resolve(JSON.parse(b)); } catch (e) { resolve(null); } });
        });
        req.on("error", () => resolve(null)); req.on("timeout", () => { req.destroy(); resolve(null); });
    });
}
let proxy = null, proxyLog = "";
function startProxy() {
    proxy = spawn(NODE, [SB + "/proxy/gokai-proxy.js"], {
        env: { ...process.env, HOME: SBHOME, GOKAI_PORT: String(PORT), GOKAI_DIR: SB, GOKAI_NO_STARTUP_DOCTOR: "1", GOKAI_TEST_MODE: "1" },
        stdio: ["ignore", "pipe", "pipe"],
    });
    proxy.exited = new Promise((r) => proxy.on("exit", r));
    proxy.stdout.on("data", (c) => proxyLog += c); proxy.stderr.on("data", (c) => proxyLog += c);
}
async function stopProxy() { if (!proxy) return; const p = proxy; proxy = null; p.kill("SIGTERM"); await p.exited; }
async function until(fn, ms = 10000, step = 150) { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(step); } return null; }

class Mcp {
    constructor() {
        this.buf = ""; this.w = new Map(); this.id = 0; this.stderr = "";
        this.child = spawn(PY, ["-I", SB + "/mcp/gokai_mcp.py", "illustrator"], {
            env: { HOME: SBHOME, PATH: "/usr/bin:/bin", GOKAI_PORT: String(PORT), GOKAI_DIR: SB, GOKAI_TEST_MODE: "1", GOKAI_NO_AUTOSTART: "1" },
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

(async () => {
    startProxy();
    await until(status);
    const browser = await puppeteer.launch({ executablePath: CHROME, args: ["--allow-file-access-from-files", "--no-sandbox"] });
    const page = await browser.newPage();
    const pageErrors = [];
    const failedRequests = [];
    page.on("pageerror", (e) => pageErrors.push(String(e)));
    page.on("requestfailed", (r) => failedRequests.push(r.url()));
    const requested = [];
    page.on("request", (r) => requested.push(r.url()));

    console.log("\n== 1. Panel yüklenir, internete gitmeden kendiliğinden bağlanır ==");
    await page.goto("file://" + PANEL + "/index.html");
    const connected = await until(async () => { const s = await status(); return s && s.apps.illustrator.connected; });
    check("panel açılınca kendiliğinden bağlandı (kutuyu işaretlemeye gerek yok)", !!connected);
    check("hiçbir dış adrese istek yok (CDN bağımlılığı kalktı)", requested.every((u) => u.startsWith("file://") || u.includes("localhost:" + PORT)), requested.filter((u) => !u.startsWith("file://")).join(", "));
    check("sayfada JavaScript hatası yok", pageErrors.length === 0, pageErrors.join(" | "));
    const ui = await page.evaluate(() => ({ t: document.getElementById("statusText").textContent, b: document.getElementById("btnConnect").textContent, c: document.getElementById("chkConnectOnLaunch").checked }));
    check("arayüz: Connected / Disconnect / otomatik bağlanma işaretli", ui.t === "Connected" && ui.b === "Disconnect" && ui.c === true, JSON.stringify(ui));
    check("proxy günlüğü: file:// kaynağı eklenti olarak kabul edildi", /eklenti bağlandı: illustrator/.test(proxyLog), proxyLog.slice(-300));

    console.log("\n== 2. Gerçek MCP sunucusu → proxy → panel → (sahte) Illustrator ==");
    const mcp = new Mcp();
    await mcp.init();
    let r = await mcp.call("get_documents");
    check("araç çağrısı panelden yanıt aldı", !r.isError && /stub\.ai/.test(r.text), r.text);

    console.log("\n== 3. Proxy yeniden başlar: panel kendiliğinden geri bağlanır ==");
    await stopProxy();
    await until(async () => (await page.evaluate(() => document.getElementById("statusText").textContent)) !== "Connected", 5000);
    const during = await page.evaluate(() => ({ t: document.getElementById("statusText").textContent, b: document.getElementById("btnConnect").textContent }));
    check("kopukken durum 'Connecting…' (düğme Disconnect kalır)", during.t === "Connecting…" && during.b === "Disconnect", JSON.stringify(during));

    console.log("\n== 4. Yeniden bağlanma sürerken Connect'e basmak ikinci bağlantı açmaz ==");
    // Eski sürümde bu durumda Connect'e her basış yeni bir soket açıyordu.
    for (let i = 0; i < 4; i++) {
        await page.evaluate(() => { connectToServer(); });
        await sleep(200);
    }
    startProxy();
    const back = await until(async () => { const s = await status(); return s && s.apps.illustrator.connected ? s : null; }, 15000);
    check("proxy geri gelince panel kendiliğinden bağlandı", !!back);
    await sleep(2500);
    const s4 = await status();
    check("tek bir eklenti bağlantısı var", s4.apps.illustrator.clients === 1, "clients=" + s4.apps.illustrator.clients);
    const before = await page.evaluate(() => window.__evalCalls.filter((c) => c.includes("(function()")).length);
    r = await mcp.call("get_documents");
    const after = await page.evaluate(() => window.__evalCalls.filter((c) => c.includes("(function()")).length);
    // get_documents: 1 komut betiği + 1 etkin belge bilgisi betiği
    check("yeniden bağlandıktan sonra komut çalışıyor ve tam bir kez yürütülüyor", !r.isError && after - before === 2, "evalScript çağrısı: " + (after - before) + " / " + r.text);

    console.log("\n== 5. Komut sürerken bağlantı anlık koparsa yanıt kaybolmaz ==");
    await page.evaluate(() => { window.__evalDelay = 1500; });
    const pending = mcp.call("get_documents");
    await sleep(500);
    await page.evaluate(() => { socket.io.engine.close(); });   // taşıyıcıyı kopar
    r = await pending;
    check("yanıt yeniden bağlanınca iletildi (hata yok)", !r.isError && /stub\.ai/.test(r.text), r.ms + " ms: " + r.text);
    await page.evaluate(() => { window.__evalDelay = 0; });

    console.log("\n== 6. Disconnect / Connect düğmesi ==");
    await page.click("#btnConnect");
    const off = await until(async () => { const s = await status(); return s && !s.apps.illustrator.connected; }, 5000);
    const uiOff = await page.evaluate(() => ({ t: document.getElementById("statusText").textContent, b: document.getElementById("btnConnect").textContent }));
    check("Disconnect bağlantıyı kesti", !!off && uiOff.t === "Disconnected" && uiOff.b === "Connect", JSON.stringify(uiOff));
    await sleep(6000);
    check("kullanıcı kestiyse kendiliğinden yeniden bağlanmıyor", !(await status()).apps.illustrator.connected);
    await page.click("#btnConnect");
    const on = await until(async () => { const s = await status(); return s && s.apps.illustrator.connected; }, 5000);
    check("Connect yeniden bağladı (tek bağlantı)", !!on && (await status()).apps.illustrator.clients === 1);

    console.log("\n== 7. Ayar kalıcılığı ve günlük sınırı ==");
    await page.click("#chkConnectOnLaunch");
    await page.reload();
    await sleep(2500);
    const afterReload = await page.evaluate(() => ({ c: document.getElementById("chkConnectOnLaunch").checked, t: document.getElementById("statusText").textContent }));
    check("kutu kapatıldıysa panel açılışta bağlanmıyor (kullanıcı tercihi korunur)", afterReload.c === false && afterReload.t === "Disconnected", JSON.stringify(afterReload));
    const lines = await page.evaluate(() => { for (let i = 0; i < 1000; i++) log("satır " + i); return document.getElementById("messageLog").value.split("\n").length; });
    check("mesaj günlüğü 300 satırla sınırlı", lines <= 300, lines);
    check("test boyunca JavaScript hatası yok", pageErrors.length === 0, pageErrors.join(" | "));

    mcp.close();
    await browser.close();
    await stopProxy();
    console.log("\n" + (failed === 0 ? "TÜM TESTLER GEÇTİ" : failed + " TEST BAŞARISIZ") + " (" + passed + " geçti, " + failed + " kaldı)\n");
    process.exit(failed === 0 ? 0 : 1);
})().catch(async (e) => { console.error("TEST ÇATISI HATASI", e); if (proxy) proxy.kill("SIGKILL"); process.exit(2); });
