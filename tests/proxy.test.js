// Proxy + MCP başlatıcı: gerçek MCP sunucusu → proxy → sahte eklenti, uçtan uca.
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
const { io } = require(G + "/proxy/node_modules/socket.io-client");

const SB = G;
const NODE = SB + "/node/bin/node";
const PY = SB + "/venv/bin/python";
const PORT = parseInt(process.env.TPORT || "3907", 10);
const URL = "http://127.0.0.1:" + PORT;
const SBHOME = H;
// Premiere köprü klasörü: gerçek /tmp/premiere-mcp-bridge'e dokunmamak için geçici klasör (proxy env'den okur)
const fs = require("fs");
process.env.PREMIERE_TEMP_DIR = fs.mkdtempSync(path.join(require("os").tmpdir(), "gokai-pr-"));

let passed = 0, failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function check(name, cond, extra) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (extra ? "\n        " + String(extra).slice(0, 2500) : "")); }
}

function get(pathname, headers = {}, host = "127.0.0.1") {
    return new Promise((resolve) => {
        const req = http.request({ host, port: PORT, path: pathname, method: "GET", headers, timeout: 3000 }, (res) => {
            let b = ""; res.on("data", (c) => b += c);
            res.on("end", () => { let j = null; try { j = JSON.parse(b); } catch (e) {} resolve({ status: res.statusCode, json: j, body: b }); });
        });
        req.on("error", (e) => resolve({ status: 0, error: e.code }));
        req.on("timeout", () => { req.destroy(); resolve({ status: 0, error: "timeout" }); });
        req.end();
    });
}
function post(pathname, headers = {}) {
    return new Promise((resolve) => {
        const req = http.request({ host: "127.0.0.1", port: PORT, path: pathname, method: "POST", headers, timeout: 3000 }, (res) => {
            let b = ""; res.on("data", (c) => b += c); res.on("end", () => resolve({ status: res.statusCode, body: b }));
        });
        req.on("error", (e) => resolve({ status: 0, error: e.code }));
        req.end();
    });
}

let proxy = null, proxyLog = "";
function startProxy(env = {}) {
    proxyLog = "";
    proxy = spawn(NODE, [SB + "/proxy/gokai-proxy.js"], {
        env: { ...process.env, HOME: SBHOME, GOKAI_PORT: String(PORT), GOKAI_DIR: SB, GOKAI_NO_STARTUP_DOCTOR: "1", GOKAI_TEST_MODE: "1", ...env },
        stdio: ["ignore", "pipe", "pipe"],
    });
    proxy.exited = new Promise((r) => proxy.on("exit", (code) => r(code)));
    proxy.stdout.on("data", (c) => proxyLog += c);
    proxy.stderr.on("data", (c) => proxyLog += c);
    return proxy;
}
async function waitUp(ms = 8000) {
    const end = Date.now() + ms;
    while (Date.now() < end) { const r = await get("/status"); if (r.json && r.json.ok) return r.json; await sleep(150); }
    return null;
}
async function stopProxy() {
    if (!proxy) return;
    const p = proxy; proxy = null;
    p.kill("SIGTERM"); await p.exited;
}

function fakePlugin(application, opts = {}) {
    const sock = io(URL, { transports: ["websocket"], extraHeaders: opts.headers || {}, reconnectionDelay: 300, reconnectionDelayMax: 800 });
    sock.executed = [];
    sock.registered = 0;
    sock.on("connect", () => sock.emit("register", { application }));
    sock.on("registration_response", () => { sock.registered++; });
    sock.on("command_packet", async (packet) => {
        sock.executed.push(packet.command.action);
        if (opts.silent) return;
        if (opts.delayMs) await sleep(opts.delayMs);
        sock.emit("command_packet_response", {
            packet: { senderId: packet.senderId, status: "SUCCESS", response: opts.response || [{ name: "test.ai" }], document: null },
        });
    });
    return sock;
}
const untilRegistered = async (sock, n = 1) => { for (let i = 0; i < 60 && sock.registered < n; i++) await sleep(100); return sock.registered >= n; };

class Mcp {
    constructor(appKey, env = {}) {
        this.buf = ""; this.waiters = new Map(); this.id = 0; this.stderr = "";
        this.child = spawn(PY, ["-I", SB + "/mcp/gokai_mcp.py", appKey], {
            env: { HOME: SBHOME, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", GOKAI_PORT: String(PORT), GOKAI_DIR: SB, GOKAI_TEST_MODE: "1", GOKAI_NO_AUTOSTART: "1", ...env },
            stdio: ["pipe", "pipe", "pipe"],
        });
        this.child.stderr.on("data", (c) => this.stderr += c);
        this.noise = 0;
        this.child.stdout.on("data", (c) => {
            this.buf += c; let nl;
            while ((nl = this.buf.indexOf("\n")) >= 0) {
                const line = this.buf.slice(0, nl).trim(); this.buf = this.buf.slice(nl + 1);
                if (!line) continue;
                let m; try { m = JSON.parse(line); } catch (e) { this.noise++; continue; }
                if (m.id && this.waiters.has(m.id)) { this.waiters.get(m.id)(m); this.waiters.delete(m.id); }
            }
        });
    }
    req(method, params, timeoutMs = 90000) {
        const id = ++this.id;
        return new Promise((resolve) => {
            const t = setTimeout(() => { this.waiters.delete(id); resolve({ timeout: true }); }, timeoutMs);
            this.waiters.set(id, (m) => { clearTimeout(t); resolve(m); });
            this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
        });
    }
    async init() {
        const r = await this.req("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "1" } });
        this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
        return r;
    }
    async call(name, args = {}) {
        const t0 = Date.now();
        const r = await this.req("tools/call", { name, arguments: args });
        const res = r.result || {};
        const text = (res.content || []).map((c) => c.text || "").join(" ");
        return { isError: !!res.isError || !!r.error || !!r.timeout, text: text || JSON.stringify(r.error || r), ms: Date.now() - t0 };
    }
    close() { try { this.child.stdin.end(); } catch (e) {} setTimeout(() => { try { this.child.kill("SIGKILL"); } catch (e) {} }, 1500); }
}

(async () => {
    console.log("\n== 1. Açılış, yerel bağlama ==");
    startProxy();
    const st = await waitUp();
    check("proxy açıldı ve /status yanıt veriyor", st && /^\d+\.\d+\.\d+$/.test(st.version), proxyLog);
    check("/status yeni alanları içeriyor (stats, install, apps.running)", st && st.stats && "install" in st && typeof st.apps.illustrator.running === "boolean");
    const viaLocalhost = await get("/status", {}, "localhost");
    check("'localhost' adıyla erişiliyor", viaLocalhost.json && viaLocalhost.json.ok);
    const via6 = await get("/status", {}, "::1");
    check("IPv6 geri döngü (::1) üzerinden erişiliyor", via6.json && via6.json.ok, JSON.stringify(via6));
    const lsof = require("child_process").execFileSync("/usr/sbin/lsof", ["-nP", "-iTCP:" + PORT, "-sTCP:LISTEN"], { encoding: "utf8" });
    check("yalnızca geri döngü adreslerini dinliyor (ağa açık değil)", !/\*:\d+/.test(lsof) && /127\.0\.0\.1:/.test(lsof), lsof);
    const evilHost = await get("/status", { Host: "evil.example:" + PORT });
    check("yabancı Host başlığı reddediliyor (DNS rebinding)", evilHost.status === 403);
    const panel = await get("/");
    check("panel sayfası sunuluyor", panel.status === 200 && /GokAI/.test(panel.body));

    console.log("\n== 1b. Premiere / After Effects: kendi köprülerinden durum ==");
    const beat = (t) => fs.writeFileSync(path.join(process.env.PREMIERE_TEMP_DIR, "bridge-heartbeat.json"), JSON.stringify({ t, started: true }));
    beat(Date.now());
    let sv = (await get("/status")).json;
    check("Premiere: taze heartbeat → bağlı", sv.apps.premiere && sv.apps.premiere.connected === true, JSON.stringify(sv.apps.premiere));
    beat(Date.now() - 60000);
    sv = (await get("/status")).json;
    check("Premiere: eski heartbeat → bağlı değil, son görülme korunuyor", sv.apps.premiere.connected === false && sv.apps.premiere.lastSeen > 0);
    // After Effects panelini taklit et: /health yanıtlar, portunu panel gibi dosyaya yazar
    const aePanel = http.createServer((q, r) => { r.setHeader("content-type", "application/json"); r.end(JSON.stringify({ ok: true, bundleLoaded: true })); });
    await new Promise((r) => aePanel.listen(0, "127.0.0.1", r));
    fs.mkdirSync(path.join(SBHOME, ".engineroom-ae-mcp"), { recursive: true });
    fs.writeFileSync(path.join(SBHOME, ".engineroom-ae-mcp", "port"), String(aePanel.address().port));
    sv = (await get("/status")).json;
    check("After Effects: panel /health yanıtlıyor → bağlı", sv.apps.aftereffects && sv.apps.aftereffects.connected === true, JSON.stringify(sv.apps.aftereffects));
    await new Promise((r) => aePanel.close(r));
    sv = (await get("/status")).json;
    check("After Effects: panel kapandı (port dosyası kaldı) → bağlı değil", sv.apps.aftereffects.connected === false && sv.apps.aftereffects.lastSeen > 0);
    fs.rmSync(path.join(SBHOME, ".engineroom-ae-mcp"), { recursive: true, force: true });

    console.log("\n== 2. Komut gidiş-dönüş (gerçek MCP sunucusu → proxy → eklenti) ==");
    const ai = new Mcp("illustrator");
    const init = await ai.init();
    check("Illustrator MCP sunucusu el sıkıştı", init.result && init.result.serverInfo, ai.stderr);
    const plug = fakePlugin("illustrator");
    await untilRegistered(plug);
    let r = await ai.call("get_documents");
    check("eklenti bağlıyken araç çağrısı yanıt alıyor", !r.isError && /test\.ai/.test(r.text), r.text);
    check("komut tam bir kez çalıştı", plug.executed.length === 1);
    const st2 = (await get("/status")).json;
    check("/status eklentiyi bağlı gösteriyor ve komutu sayıyor", st2.apps.illustrator.connected && st2.stats.commands === 1 && st2.stats.pending === 0);

    console.log("\n== 3. Çift kayıt: komut tek eklentiye gider ==");
    const plug2 = fakePlugin("illustrator");
    await untilRegistered(plug2);
    r = await ai.call("get_documents");
    check("iki kayıt varken çağrı başarılı", !r.isError, r.text);
    check("komut yalnızca EN YENİ kayda gitti (çift çalıştırma yok)", plug.executed.length === 1 && plug2.executed.length === 1,
        "eski=" + plug.executed.length + " yeni=" + plug2.executed.length);
    plug2.close(); await sleep(300);
    r = await ai.call("get_documents");
    check("yeni kayıt ayrılınca eskisine geri dönüyor", !r.isError && plug.executed.length === 2, r.text);

    console.log("\n== 4. Eklenti bağlı değil: hızlı ve açıklayıcı hata ==");
    const ps = new Mcp("photoshop");
    await ps.init();
    r = await ps.call("get_documents");
    check("Photoshop kapalıyken hata anında dönüyor (<3 sn, eskiden 20 sn)", r.isError && r.ms < 3000, r.ms + " ms: " + r.text);
    check("hata nedeni söylüyor: 'Photoshop açık değil'", /Photoshop açık değil/.test(r.text), r.text);
    ps.close();

    plug.close(); await sleep(300);
    // Bu makinede gerçek Illustrator açık: "uygulama açık ama eklenti bağlı değil" dalı
    const running = (await get("/status")).json.apps.illustrator.running;
    if (running) {
        r = await ai.call("get_documents");
        check("Illustrator açık + eklenti yok: bekleme süresi sonunda açıklayıcı hata", r.isError && /eklentisi GokAI'ye bağlı değil/.test(r.text) && r.ms >= 5000 && r.ms < 9000, r.ms + " ms: " + r.text);

        console.log("\n== 5. Eklenti bekleme süresi içinde bağlanırsa komut kaybolmaz ==");
        const callP = ai.call("get_documents");
        await sleep(2000);
        const late = fakePlugin("illustrator");
        r = await callP;
        check("komut, geç bağlanan eklentiye teslim edildi", !r.isError && late.executed.length === 1, r.ms + " ms: " + r.text);

        console.log("\n== 6. Proxy yeniden başlarsa eklenti kendiliğinden geri gelir ==");
        await stopProxy();
        await sleep(500);
        startProxy();
        await waitUp();
        const back = await untilRegistered(late, 2);
        check("eklenti yeniden bağlanıp kayıt oldu (elle Connect gerekmedi)", back);
        r = await ai.call("get_documents");
        check("yeniden başlatma sonrası araç çağrısı çalışıyor", !r.isError && late.executed.length === 2, r.text);

        console.log("\n== 7. Eklenti işlem sırasında koparsa ==");
        late.close(); await sleep(300);
        const silent = fakePlugin("illustrator", { silent: true });
        await untilRegistered(silent);
        const p7 = ai.call("get_documents");
        await sleep(1000);
        silent.close();
        r = await p7;
        check("bağlantı kopunca 20-55 sn beklemeden hata dönüyor", r.isError && /bağlantısı işlem sırasında koptu/.test(r.text) && r.ms < 12000, r.ms + " ms: " + r.text);
    } else {
        console.log("  (Illustrator açık değil: 4b-7 adımları atlandı)");
    }

    console.log("\n== 8. Eklenti bağlı ama yanıt vermiyor (zaman aşımı iletisi) ==");
    const ai2 = new Mcp("illustrator", { GOKAI_PROXY_TIMEOUT: "3" });
    await ai2.init();
    const mute = fakePlugin("illustrator", { silent: true });
    await untilRegistered(mute);
    r = await ai2.call("get_documents");
    check("zaman aşımı nedeni açıklıyor ve yeniden denemiyor", r.isError && /yanıt vermedi\. Eklenti bağlı/.test(r.text) && mute.executed.length === 1, r.ms + " ms / çalıştırma=" + mute.executed.length + ": " + r.text);
    mute.close(); ai2.close();

    console.log("\n== 8b. Proxy birkaç saniye yanıt veremezse (meşgul makine) komut yine tamamlanır ==");
    // Render / büyük dosya sırasında proxy saniyelerce işlemci alamayabilir.
    // Eski davranış: 1,5 sn yanıt gelmezse "proxy bozuk" deyip hata veriyor
    // (canlıda: sağlam proxy'yi öldürüp yeniden başlatıyor) du.
    {
        const busy = fakePlugin("illustrator");
        await untilRegistered(busy);
        const pid = proxy.pid;
        process.kill(pid, "SIGSTOP");
        setTimeout(() => { try { process.kill(pid, "SIGCONT"); } catch (e) {} }, 3000);
        r = await ai.call("get_documents");
        try { process.kill(pid, "SIGCONT"); } catch (e) {}
        check("3 sn donan proxy toparlanınca komut tamamlandı (" + r.ms + " ms)", !r.isError && /test\.ai/.test(r.text) && r.ms >= 2500 && r.ms < 15000,
            r.ms + " ms: " + r.text + "\n" + ai.stderr.slice(-500));
        check("komut tam bir kez çalıştı (yeniden deneme çift çalıştırmadı)", busy.executed.length === 1, "çalıştırma: " + busy.executed.length);
        busy.close();
        await sleep(300);
    }

    console.log("\n== 9. Hatalı paketler proxy'yi düşüremez ==");
    const bad = io(URL, { transports: ["websocket"] });
    await new Promise((res) => bad.on("connect", res));
    bad.emit("register");
    bad.emit("register", null);
    bad.emit("command_packet_response");
    bad.emit("command_packet_response", { packet: null });
    bad.emit("command_packet", null);
    bad.emit("command_packet", { application: 42 });
    await sleep(500);
    const alive = await get("/status");
    check("hatalı paketlerden sonra proxy ayakta", alive.json && alive.json.ok && proxy.exitCode === null, proxyLog.slice(-400));
    bad.close();

    console.log("\n== 10. Yabancı web sayfası komut gönderemez ==");
    const victim = fakePlugin("illustrator");
    await untilRegistered(victim);
    const evil = io(URL, { transports: ["websocket"], extraHeaders: { Origin: "https://evil.example" } });
    await new Promise((res) => evil.on("connect", res));
    const evilResp = new Promise((res) => { evil.on("packet_response", res); setTimeout(() => res(null), 2500); });
    evil.emit("command_packet", { type: "command", application: "illustrator", command: { application: "illustrator", action: "executeExtendScript", options: {} } });
    const er = await evilResp;
    check("yabancı kaynaktan gelen komut eklentiye ULAŞMADI", victim.executed.length === 0 && er && er.status === "FAILURE", JSON.stringify(er));
    evil.close();
    r = await ai.call("get_documents");
    check("yerel MCP sunucusunun komutu hâlâ çalışıyor", !r.isError && victim.executed.length === 1, r.text);
    const evilWs = await new Promise((res) => {
        const s = io(URL, { transports: ["websocket"], extraHeaders: { Host: "evil.example:" + PORT }, reconnection: false, timeout: 2000 });
        s.on("connect", () => { s.close(); res("connected"); });
        s.on("connect_error", () => res("refused"));
    });
    check("yabancı Host başlığıyla WebSocket bağlantısı reddediliyor", evilWs === "refused", evilWs);

    console.log("\n== 11. İkinci proxy kopyası çalışanı bozmaz ==");
    const second = spawn(NODE, [SB + "/proxy/gokai-proxy.js"], { env: { ...process.env, HOME: SBHOME, GOKAI_PORT: String(PORT), GOKAI_DIR: SB, GOKAI_NO_STARTUP_DOCTOR: "1" }, stdio: ["ignore", "pipe", "pipe"] });
    let secondLog = ""; second.stdout.on("data", (c) => secondLog += c); second.stderr.on("data", (c) => secondLog += c);
    await sleep(2500);
    check("ikinci kopya portu alamadı ve nedenini yazdı", /başka bir GokAI proxy'si/.test(secondLog), secondLog);
    r = await ai.call("get_documents");
    check("ilk proxy etkilenmedi", !r.isError && victim.executed.length === 2,
        r.ms + " ms: " + r.text + "\n--- eklenti çalıştırma sayısı: " + victim.executed.length + ", bağlı: " + victim.connected +
        "\n--- MCP stderr:\n" + ai.stderr.slice(-900) + "\n--- proxy:\n" + proxyLog.slice(-700) + "\n--- ikinci proxy:\n" + secondLog);
    second.kill("SIGKILL");

    console.log("\n== 12. /restart yalnızca panelden ==");
    const rEvil = await post("/restart", { Origin: "https://evil.example" });
    await sleep(600);
    check("yabancı kaynaktan /restart reddedildi, proxy ayakta", rEvil.status === 403 && proxy.exitCode === null);
    const rOk = await post("/restart", { Origin: "http://localhost:" + PORT });
    const code = await Promise.race([proxy.exited, sleep(3000).then(() => "still-running")]);
    check("panelden /restart temiz çıkış yaptı (launchd yeniden başlatır)", rOk.status === 200 && code === 0, "code=" + code);
    proxy = null;
    victim.close();

    console.log("\n== 12b. Karşı taraf yanıtı iletip donarsa çağrı asılı kalmaz ==");
    // adb-mcp'nin kendi gönderme fonksiyonu yanıt geldikten sonra bağlantıyı
    // BEKLEYEREK kapatıyordu; karşı taraf kapanışı onaylamazsa başarılı komutun
    // sonucu bile ping süresi kadar gecikiyordu. Burada sahte bir proxy yanıtı
    // gönderir göndermez kendini dondurur (SIGSTOP): kapanış asla onaylanmaz.
    {
        const FPORT = PORT + 7;
        const fakeSrc = `
            const http = require("http");
            const { Server } = require(process.argv[1] + "/socket.io");
            const srv = http.createServer((req, res) => {
                res.setHeader("content-type", "application/json");
                res.end(JSON.stringify({ ok: true, version: "sahte", apps: { illustrator: { connected: true, running: true } } }));
            });
            const io = new Server(srv, { transports: ["websocket"] });
            io.on("connection", (socket) => {
                socket.on("command_packet", () => {
                    socket.emit("packet_response", { senderId: socket.id, status: "SUCCESS", response: [{ name: "donmus.ai" }], document: null });
                    // yanıt çekirdeğe yazılınca kendini dondur
                    socket.conn.once("drain", () => process.kill(process.pid, "SIGSTOP"));
                });
            });
            srv.listen(${FPORT}, "127.0.0.1", () => console.log("hazir"));
        `;
        const fake = spawn(NODE, ["-e", fakeSrc, SB + "/proxy/node_modules"], { stdio: ["ignore", "pipe", "pipe"] });
        await new Promise((res) => { fake.stdout.on("data", (c) => { if (String(c).includes("hazir")) res(); }); setTimeout(res, 5000); });
        const frozen = new Mcp("illustrator", { GOKAI_PORT: String(FPORT) });
        await frozen.init();
        r = await frozen.call("get_documents");
        check("yanıt gelir gelmez döndü (" + r.ms + " ms), kapanış beklenmedi", !r.isError && /donmus\.ai/.test(r.text) && r.ms < 5000,
            r.ms + " ms: " + r.text + "\n" + frozen.stderr.slice(-400));
        frozen.close();
        try { process.kill(fake.pid, "SIGCONT"); } catch (e) {}
        fake.kill("SIGKILL");
    }

    console.log("\n== 13. Proxy kapalıyken başlatıcı onu kendisi açar ==");
    const ps2 = new Mcp("photoshop", { GOKAI_NO_AUTOSTART: "" });
    await ps2.init();
    r = await ps2.call("get_documents");
    check("proxy kapalıydı; başlatıcı açtı ve komut proxy'ye ulaştı", r.isError && /Photoshop açık değil/.test(r.text), r.ms + " ms: " + r.text + "\n" + ps2.stderr.slice(-300));
    const up = await get("/status");
    check("proxy şimdi çalışıyor", up.json && up.json.ok);
    ps2.close();
    // başlatıcının açtığı proxy'yi kapat
    try {
        const out = require("child_process").execFileSync("/usr/sbin/lsof", ["-nP", "-tiTCP:" + PORT, "-sTCP:LISTEN"], { encoding: "utf8" });
        for (const pid of new Set(out.trim().split("\n"))) if (pid) process.kill(parseInt(pid, 10), "SIGTERM");
    } catch (e) {}

    console.log("\n== 14. Proxy hiç başlatılamıyorsa: açıklayıcı hata, asılı kalma yok ==");
    await sleep(800);
    const ai3 = new Mcp("illustrator", { GOKAI_NO_AUTOSTART: "1" });
    await ai3.init();
    r = await ai3.call("get_documents");
    check("köprü yokken hata açıklayıcı ve makul sürede", r.isError && /köprü servisi çalışmıyor/.test(r.text) && r.ms < 15000, r.ms + " ms: " + r.text);
    check("MCP çıktısına protokol dışı satır karışmadı", ai.noise === 0 && ai3.noise === 0);
    ai3.close(); ai.close();

    await sleep(500);
    console.log("\n" + (failed === 0 ? "TÜM TESTLER GEÇTİ" : failed + " TEST BAŞARISIZ") + " (" + passed + " geçti, " + failed + " kaldı)\n");
    process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.error("TEST ÇATISI HATASI", e); if (proxy) proxy.kill("SIGKILL"); process.exit(2); });
