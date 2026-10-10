/* Illustrator MCP Agent (CEP) — GokAI sürümü
 *
 * adb-mcp projesindeki cep/com.mikechambers.ai/main.js dosyasından türetilmiştir
 * (Copyright (c) 2025 Mike Chambers, MIT). Proxy protokolü ve komut işleme
 * orijinaliyle aynıdır; bağlantı yönetimi sağlamlaştırılmıştır:
 *
 *   - Socket.IO yerel dosyadan yüklenir (index.html), internete gerek yok.
 *   - Tek bir soket kullanılır. Orijinalinde yeniden bağlanma sürerken
 *     Connect'e her basış yeni bir bağlantı açıyor, eskileri Disconnect ile
 *     kapatılamayan yetim bağlantılar olarak kalıyordu.
 *   - Bağlantı koparsa süresiz, kendiliğinden yeniden bağlanır.
 *   - "Connect automatically on launch" varsayılan olarak açıktır.
 *   - Komut biterken bağlantı anlık kopmuşsa yanıt atılmaz; yeniden bağlanınca
 *     gönderilir.
 *   - Mesaj günlüğü sınırlıdır (günlerce açık kalan panelde şişmez).
 */

const csInterface = new CSInterface();
const APPLICATION = "illustrator";
const PROXY_URL = "http://localhost:3001";

const CONNECT_ON_LAUNCH = "connectOnLaunch";
const MAX_LOG_LINES = 300;
const RESPONSE_MAX_AGE_MS = 60000;

let socket = null;
// Kullanıcı bağlı kalmak istiyor mu? (Connect'e bastı ya da otomatik bağlanma açık)
let wantConnection = false;
let connectErrors = 0;
// Bağlantı yokken biten komutların yanıtları
let queuedResponses = [];

// Log function
function log(message) {
    const logArea = document.getElementById('messageLog');
    const timestamp = new Date().toLocaleTimeString();
    const lines = logArea.value.split('\n');
    lines.push(`[${timestamp}] ${message}`);
    logArea.value = lines.slice(-MAX_LOG_LINES).join('\n');
    logArea.scrollTop = logArea.scrollHeight;
}

// Update UI status: "connected" | "connecting" | "disconnected"
function updateStatus(state) {
    const statusDot = document.getElementById('statusDot');
    const statusText = document.getElementById('statusText');
    const btnConnect = document.getElementById('btnConnect');

    statusDot.classList.toggle('connected', state === 'connected');
    statusText.textContent =
        state === 'connected' ? 'Connected' :
        state === 'connecting' ? 'Connecting…' : 'Disconnected';
    btnConnect.textContent = wantConnection ? 'Disconnect' : 'Connect';
}

// Node etkin CEP panellerinde UMD paketleri window yerine module.exports'a
// yazılabiliyor; iki yere de bak.
function getIO() {
    if (typeof io === 'function') return io;
    if (typeof module !== 'undefined' && module && typeof module.exports === 'function') {
        return module.exports;
    }
    return null;
}

// Handle incoming command packets
async function onCommandPacket(packet) {
    const action = packet && packet.command ? packet.command.action : 'unknown';
    log(`Received command: ${action}`);

    let out = {
        senderId: packet.senderId,
    };

    try {
        const response = await parseAndRouteCommand(packet.command);

        out.response = response;
        out.status = "SUCCESS";
        out.document = await getActiveDocumentInfo();

    } catch (e) {
        out.status = "FAILURE";
        out.message = `Error calling ${action}: ${e.message}`;
        log(`Error: ${e.message}`);
    }

    return out;
}

function flushQueuedResponses() {
    const now = Date.now();
    const fresh = queuedResponses.filter((q) => now - q.at < RESPONSE_MAX_AGE_MS);
    queuedResponses = [];
    for (const q of fresh) {
        socket.emit("command_packet_response", { packet: q.packet });
        log('Queued response sent');
    }
}

// Connect to Socket.IO server
function connectToServer() {
    wantConnection = true;

    const ioFactory = getIO();
    if (!ioFactory) {
        wantConnection = false;
        updateStatus('disconnected');
        log('ERROR: Socket.IO could not be loaded (lib/socket.io.min.js). Reinstall GokAI.');
        return;
    }

    // Soket zaten varsa onu kullan — ikinci bir bağlantı açma.
    if (socket) {
        updateStatus(socket.connected ? 'connected' : 'connecting');
        if (!socket.connected) socket.connect();
        return;
    }

    log(`Connecting to ${PROXY_URL}...`);
    updateStatus('connecting');

    socket = ioFactory(PROXY_URL, {
        transports: ["websocket", "polling"],
        reconnection: true,
        reconnectionAttempts: Infinity,
        reconnectionDelay: 1000,
        reconnectionDelayMax: 5000,
        timeout: 10000,
    });

    // "connect" ilk bağlantıda da yeniden bağlanmada da tetiklenir; her
    // seferinde yeniden kayıt olmak gerekir (proxy yeni bir soket kimliği görür).
    socket.on("connect", () => {
        connectErrors = 0;
        updateStatus('connected');
        log(`Connected with ID: ${socket.id}`);
        socket.emit("register", { application: APPLICATION });
        flushQueuedResponses();
    });

    socket.on("command_packet", async (packet) => {
        const response = await onCommandPacket(packet);
        sendResponsePacket(response);
    });

    socket.on("registration_response", (data) => {
        log(`Registration confirmed: ${data.message || 'OK'}`);
    });

    socket.on("connect_error", (error) => {
        updateStatus(wantConnection ? 'connecting' : 'disconnected');
        // GokAI servisi kapalıyken birkaç saniyede bir tekrarlanır; günlüğü doldurma.
        connectErrors++;
        if (connectErrors === 1 || connectErrors % 30 === 0) {
            log(`Connection error: ${error.message} (retrying…)`);
        }
    });

    socket.on("disconnect", (reason) => {
        log(`Disconnected: ${reason}`);
        if (!wantConnection) {
            updateStatus('disconnected');
            return;
        }
        updateStatus('connecting');
        // Sunucu bağlantıyı kendisi kapattıysa Socket.IO otomatik denemez.
        if (reason === "io server disconnect") socket.connect();
    });
}

// Disconnect from server
function disconnectFromServer() {
    wantConnection = false;
    if (socket) {
        socket.disconnect();
        log('Disconnected from server');
    }
    updateStatus('disconnected');
}

// Send response packet
function sendResponsePacket(packet) {
    if (socket && socket.connected) {
        socket.emit("command_packet_response", { packet });
        log('Response sent');
        return true;
    }
    // Komut çalışırken bağlantı anlık koptu: yanıtı sakla, bağlanınca gönder.
    if (wantConnection) {
        queuedResponses.push({ packet, at: Date.now() });
        queuedResponses = queuedResponses.slice(-20);
        log('Not connected — response queued');
    }
    return false;
}

function saveSettings() {
    localStorage.setItem(CONNECT_ON_LAUNCH,
        document.getElementById('chkConnectOnLaunch').checked);
}

function loadSettings() {
    // Hiç ayarlanmamışsa açık say: kullanıcı kutuyu elle kapatmadıkça panel
    // her açılışta kendiliğinden bağlanır.
    const stored = localStorage.getItem(CONNECT_ON_LAUNCH);
    const connectOnLaunch = stored === null ? true : stored === 'true';

    document.getElementById('chkConnectOnLaunch').checked = connectOnLaunch;

    return connectOnLaunch;
}

// Event Listeners
document.getElementById('btnConnect').addEventListener('click', () => {
    if (wantConnection) {
        disconnectFromServer();
    } else {
        connectToServer();
    }
    saveSettings();
});

document.getElementById('chkConnectOnLaunch').addEventListener('change', saveSettings);


function initializeExtension() {
    const csInterface = new CSInterface();
    const extensionPath = csInterface.getSystemPath(SystemPath.EXTENSION);
    const polyfillPath = extensionPath + '/jsx/json-polyfill.jsx';
    const utilsPath = extensionPath + '/jsx/utils.jsx';

    csInterface.evalScript(`$.evalFile("${polyfillPath}")`, function(result) {
        console.log('JSON polyfill loaded');
    });

    csInterface.evalScript(`$.evalFile("${utilsPath}")`, function(result) {
        console.log('utilsPath loaded');
    });
}

// Güvenlik ağı: bağlı olmak istiyoruz ama soket ne bağlı ne de yeniden
// deniyorsa (ör. uykudan sonra) elle tetikle.
setInterval(() => {
    if (wantConnection && socket && !socket.connected && !socket.active) {
        log('Reconnecting…');
        socket.connect();
    }
}, 15000);

// Initialize on load
window.addEventListener('load', () => {
    initializeExtension()
    const connectOnLaunch = loadSettings();
    log('Plugin loaded');

    if (connectOnLaunch) {
        connectToServer();
    }
});
