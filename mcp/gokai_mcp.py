#!/usr/bin/env python3
"""
GokAI MCP başlatıcı — adb-mcp sunucularını (Illustrator / Photoshop) ek
kontrollerle başlatır.

Claude Desktop bu dosyayı kilitli Python ortamıyla doğrudan çalıştırır:

    <GokAI>/venv/bin/python -I <GokAI>/mcp/gokai_mcp.py illustrator

Açılışta hiçbir şey internetten çözülmez. adb-mcp'nin kendi dosyalarına
dokunmadan şunları ekler:

  * Proxy kapalıysa kendisi başlatır (launchd; o da olmazsa doğrudan).
  * Yerel bağlantılar sistemdeki HTTP proxy / VPN ayarlarından etkilenmez.
  * "Bağlantı zaman aşımı" yerine neyin eksik olduğunu söyleyen hata iletileri.
  * Komut proxy'ye hiç ulaşmadıysa bir kez yeniden dener (ulaştıysa denemez:
    aynı işlem iki kez çalışmasın).
  * Yanıt gelir gelmez döner; bağlantının kapanması yanıtı bekletmez.
  * print() çıktıları stdout'a karışıp MCP bağlantısını bozamaz.

Kullanım:
    gokai_mcp.py illustrator|photoshop          sunucuyu stdio üzerinde çalıştır
    gokai_mcp.py illustrator|photoshop --check  yalnızca yükle ve çık (kurulum testi)
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request

# anahtar -> (adb-mcp betiği, görünen ad, belirtme hâli)
APPS = {
    "illustrator": ("ai-mcp.py", "Illustrator", "Illustrator'ı"),
    "photoshop": ("ps-mcp.py", "Photoshop", "Photoshop'u"),
}

HERE = os.path.dirname(os.path.abspath(__file__))
GOKAI_DIR = os.environ.get("GOKAI_DIR") or os.path.dirname(HERE)
ADB_MCP_DIR = os.path.join(GOKAI_DIR, "adb-mcp", "mcp")

PORT = int(os.environ.get("GOKAI_PORT", "3001"))
# 127.0.0.1: "localhost" ad çözümlemesine (/etc/hosts, IPv6 sırası) bağımlı kalma.
PROXY_URL = "http://127.0.0.1:%d" % PORT
# MCP istemcilerinde yaygın olan 60 sn'lik istek sınırının hemen altında: uzun
# işlemler 20 saniyede kesilmesin, ama açıklayıcı hata istemcininkinden önce gelsin.
COMMAND_TIMEOUT = float(os.environ.get("GOKAI_PROXY_TIMEOUT", "55"))

# (Ortam değişkeni yalnızca testler için: gerçek servise dokunmadan denemek.)
SERVICE_LABEL = os.environ.get("GOKAI_SERVICE_LABEL") or "com.gokai.proxy"
# Komutun proxy'ye gönderilmesi için tanınan süre (bağlantı + el sıkışma).
CONNECT_TIMEOUT = 8
TEST_MODE = os.environ.get("GOKAI_TEST_MODE") == "1"
NO_AUTOSTART = os.environ.get("GOKAI_NO_AUTOSTART") == "1"

REINSTALL_HINT = (
    "Düzeltmek için Claude Desktop'ı kapatıp şunu çalıştırın: "
    "curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/install.sh | bash"
)


def log(message):
    print("GOKAI : %s" % message, file=sys.stderr, flush=True)


def fatal(message):
    log("HATA: %s" % message)
    log(REINSTALL_HINT)
    sys.exit(1)


class StdoutGuard:
    """print() çıktısını stderr'e yollar.

    stdio MCP sunucusunda stdout yalnızca JSON-RPC taşır; araya giren tek bir
    düz metin satırı Claude'un bağlantıyı kesmesine yol açar (adb-mcp'nin
    fonts.py dosyası bozuk bir yazı tipinde stdout'a print() yapıyor). MCP
    taşıyıcısı `.buffer` üzerinden gerçek stdout'u kullanmaya devam eder.
    """

    def __init__(self, real_stdout, err):
        self.buffer = real_stdout.buffer
        self.encoding = getattr(real_stdout, "encoding", "utf-8")
        self.errors = getattr(real_stdout, "errors", "strict")
        self._err = err

    def write(self, text):
        return self._err.write(text)

    def writelines(self, lines):
        for line in lines:
            self._err.write(line)

    def flush(self):
        self._err.flush()

    def isatty(self):
        return False

    def fileno(self):
        return self._err.fileno()


# ------------------------------------------------------------------- proxy ---

# Sistemde HTTP proxy tanımlı olsa bile (VPN, kurumsal ağ, Charles/Proxyman)
# yerel köprüye doğrudan bağlan.
_direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_start_lock = threading.Lock()


def proxy_status(timeout=1.5):
    """Proxy'nin /status yanıtı; ulaşılamıyorsa None."""
    try:
        with _direct.open(PROXY_URL + "/status", timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
            return data if isinstance(data, dict) and data.get("ok") else None
    except Exception:
        return None


def port_open():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        sock.connect(("127.0.0.1", PORT))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def wait_for_proxy(seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if proxy_status(timeout=1.0):
            return True
        time.sleep(0.3)
    return False


def _launchctl(*args):
    try:
        done = subprocess.run(
            ["/bin/launchctl"] + list(args),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=8,
        )
        return done.returncode == 0
    except Exception:
        return False


def start_proxy():
    """Proxy'yi ayağa kaldırmayı dener: önce launchd, olmazsa doğrudan.

    Bir başlatma denemesi yapıldıysa True döner (beklemeye değer mi?).
    """
    if NO_AUTOSTART:
        return False

    attempted = False
    if not TEST_MODE:
        uid = os.getuid()
        target = "gui/%d/%s" % (uid, SERVICE_LABEL)
        plist = os.path.expanduser("~/Library/LaunchAgents/%s.plist" % SERVICE_LABEL)
        # Temizlik/optimizasyon uygulamaları servisi devre dışı bırakmış olabilir.
        _launchctl("enable", target)
        if port_open():
            # Port açık ama HTTP yanıt vermiyor: süreç takılmış, yeniden başlat.
            log("proxy yanıt vermiyor, yeniden başlatılıyor")
            attempted = _launchctl("kickstart", "-k", target)
        elif _launchctl("kickstart", target):
            attempted = True
        elif os.path.exists(plist):
            log("proxy servisi yüklü değil, yükleniyor")
            _launchctl("bootstrap", "gui/%d" % uid, plist)
            attempted = _launchctl("kickstart", target)
        if attempted and wait_for_proxy(6):
            return True

    # Son çare: launchd çalışmıyorsa bile köprü ayakta olsun.
    node = os.path.join(GOKAI_DIR, "node", "bin", "node")
    script = os.path.join(GOKAI_DIR, "proxy", "gokai-proxy.js")
    if not (os.path.exists(node) and os.path.exists(script)):
        return attempted
    log("proxy doğrudan başlatılıyor")
    try:
        log_path = os.path.expanduser("~/Library/Logs/gokai-proxy.log")
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "ab") as out:
            subprocess.Popen(
                [node, script],
                cwd=os.path.dirname(script),
                stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                start_new_session=True,
            )
        return True
    except Exception as error:
        log("proxy başlatılamadı: %s" % error)
        return attempted


_last_failure = 0.0


def ensure_proxy(wait_seconds=10.0):
    """Proxy çalışıyorsa True; çalışmıyorsa başlatmayı dener."""
    global _last_failure
    if proxy_status():
        return True
    with _start_lock:
        # Port açıksa proxy ayakta ama yanıtı gecikiyor olabilir (makine o an
        # meşgul: render, büyük dosya…). Öldürüp yeniden başlatmak bağlı
        # eklentileri düşürür; önce toparlanması için süre tanı.
        if port_open() and wait_for_proxy(8):
            return True
        if proxy_status():
            return True
        # Az önce başlatılamadıysa her çağrıda yeniden bekletme.
        if time.time() - _last_failure < 5:
            return False
        ok = start_proxy() and wait_for_proxy(wait_seconds)
        if not ok:
            _last_failure = time.time()
        return ok


# ---------------------------------------------------- socket_client sarmalı ---

def install_guards(app_key, app_label, app_accusative):
    """adb-mcp'nin socket_client modülünü, dosyasına dokunmadan sarmalar."""
    import queue

    import socket_client
    import socketio

    upstream_configure = socket_client.configure

    def proxy_down():
        if port_open():
            # Port açık ama yanıt veren GokAI değil: başka bir program oturmuş.
            return (
                "GokAI köprü servisi yanıt vermiyor: %d portu açık ama GokAI'ye ait değil; "
                "başka bir program bu portu kullanıyor olabilir. O programı kapatın. "
                "Tanı: curl -fsSL https://raw.githubusercontent.com/gokay12/gokai/main/doctor.sh | bash"
                % PORT
            )
        return (
            "GokAI köprü servisi çalışmıyor ve başlatılamadı (port %d). "
            "Bilgisayarı yeniden başlatmak genellikle çözer. %s" % (PORT, REINSTALL_HINT)
        )

    def configure(app=None, url=None, timeout=None):
        # adb-mcp sabit olarak localhost:3001 ve 20 sn kullanıyor.
        return upstream_configure(app=app, url=PROXY_URL, timeout=COMMAND_TIMEOUT)

    def explain_timeout():
        status = proxy_status()
        if status is None:
            return proxy_down()
        info = (status.get("apps") or {}).get(app_key) or {}
        if info.get("connected"):
            return (
                "%s %d saniye içinde yanıt vermedi. Eklenti bağlı; %s meşgul olabilir ya da "
                "ekranda yanıt bekleyen bir iletişim kutusu olabilir. İşlem arka planda "
                "tamamlanmış olabilir — yeniden denemeden önce belgeyi kontrol edin."
                % (app_label, COMMAND_TIMEOUT, app_label)
            )
        return (
            "%s eklentisi GokAI'ye bağlı değil. %s açın ve MCP Agent panelinin bağlı "
            "olduğunu kontrol edin (durum paneli: http://localhost:%d)."
            % (app_label, app_accusative, PORT)
        )

    def exchange(command, wait_seconds):
        """Komutu proxy'ye gönderir, sonucu bekler → (tür, veri).

        tür: "response" | "not-sent" | "closed" | "timeout"

        adb-mcp'nin kendi gönderme fonksiyonunun yerini alır (protokol aynı):

          * Onunki bağlanmak için yalnızca 1 saniye bekliyor; makine o an
            meşgulse sağlam bir proxy "bağlanılamadı" sayılıyordu.
          * Onunki bağlantıyı bekleyerek kapatıyor; kapanış takılırsa çağrı
            da takılıyordu. Burada bağlantı arka planda kapatılır.
          * Komutun gönderilip gönderilmediği kesin olarak bilinir: yalnızca
            HİÇ gönderilmediyse yeniden denenir (aynı işlem iki kez çalışmaz).
        """
        outcome = queue.Queue(maxsize=1)
        lock = threading.Lock()
        state = {"emitted": False, "abandoned": False}

        def offer(kind, data=None):
            try:
                outcome.put_nowait((kind, data))
            except queue.Full:
                pass  # ilk sonuç geçerlidir

        # reconnection=False: bağlantı beklerken koparsa kütüphane yeni bir
        # kimlikle yeniden bağlanırdı; yanıt eski kimliğe gideceği için asla
        # gelmezdi. Kopmayı hemen bildirmek daha doğru.
        sio = socketio.Client(logger=False, reconnection=False)

        @sio.event
        def connect():
            with lock:
                if state["abandoned"]:
                    return  # vazgeçildi: geç kalan bağlantı komutu GÖNDERMEZ
                state["emitted"] = True
            try:
                sio.emit("command_packet", {
                    "type": "command",
                    "application": app_key,
                    "command": command,
                })
            except Exception:
                offer("closed")  # gönderilip gönderilmediği belirsiz: yeniden deneme

        @sio.on("packet_response")
        def packet_response(data):
            offer("response", data)

        @sio.event
        def connect_error(error):
            offer("not-sent", error)

        @sio.event
        def disconnect(*_):
            offer("closed" if state["emitted"] else "not-sent", "bağlantı kurulurken kesildi")

        def run():
            try:
                sio.connect(PROXY_URL, transports=["websocket"], wait_timeout=5)
                sio.wait()
            except Exception as error:
                offer("closed" if state["emitted"] else "not-sent", error)

        def close():
            try:
                sio.disconnect()
            except Exception:
                pass

        threading.Thread(target=run, daemon=True).start()
        try:
            # 1) Bağlantı aşaması: komut bu süre içinde gönderilemediyse vazgeç.
            try:
                return outcome.get(timeout=min(CONNECT_TIMEOUT, wait_seconds))
            except queue.Empty:
                with lock:
                    if not state["emitted"]:
                        state["abandoned"] = True
                        return ("not-sent", "bağlantı %d saniyede kurulamadı" % CONNECT_TIMEOUT)
            # 2) Komut gönderildi: yanıtı bekle.
            try:
                return outcome.get(timeout=max(wait_seconds - CONNECT_TIMEOUT, 1))
            except queue.Empty:
                return ("timeout", None)
        finally:
            with lock:
                state["abandoned"] = True
            threading.Thread(target=close, daemon=True).start()

    def send_message_blocking(command, timeout=None):
        if not ensure_proxy():
            raise RuntimeError(proxy_down())

        wait_seconds = timeout if timeout is not None else COMMAND_TIMEOUT
        for attempt in (1, 2):
            kind, data = exchange(command, wait_seconds)

            if kind == "response":
                if not isinstance(data, dict):
                    raise RuntimeError("%s eklentisinden beklenmeyen bir yanıt geldi." % app_label)
                if data.get("status") == "FAILURE":
                    # Uygulamanın (ya da proxy'nin) kendi hatası: olduğu gibi ilet.
                    raise socket_client.AppError(
                        "Error returned from %s: %s" % (app_key, data.get("message"))
                    )
                return data

            if kind == "not-sent":
                if attempt == 1:
                    # Komut proxy'ye ulaşmadı; yeniden denemek güvenli.
                    log("proxy bağlantısı kurulamadı (%s), yeniden deneniyor" % data)
                    ensure_proxy()
                    continue
                raise RuntimeError(proxy_down())

            if kind == "closed":
                # Komut gönderildi ama bağlantı yanıttan önce kesildi: uygulamaya
                # ulaşmış olabilir, YENİDEN DENEME (aynı işlem iki kez çalışmasın).
                raise RuntimeError(
                    "%s ile bağlantı, yanıt gelmeden kesildi. İşlem tamamlanmamış olabilir; "
                    "belgeyi kontrol edip yeniden deneyin." % app_label
                )

            # Zaman aşımı: komut uygulamaya ulaşmış olabilir, YENİDEN DENEME.
            raise RuntimeError(explain_timeout())

    socket_client.configure = configure
    socket_client.send_message_blocking = send_message_blocking


def load_server(script_path):
    """adb-mcp betiğini modül olarak yükler ve içindeki FastMCP nesnesini döndürür."""
    import importlib.util
    from mcp.server.fastmcp import FastMCP

    spec = importlib.util.spec_from_file_location("gokai_adb_server", script_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["gokai_adb_server"] = module
    spec.loader.exec_module(module)

    server = getattr(module, "mcp", None)
    if not isinstance(server, FastMCP):
        server = next((v for v in vars(module).values() if isinstance(v, FastMCP)), None)
    return server


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv[1:]
    if len(args) != 1 or args[0] not in APPS:
        fatal("kullanım: gokai_mcp.py illustrator|photoshop [--check]")

    app_key = args[0]
    script_name, app_label, app_accusative = APPS[app_key]
    script_path = os.path.join(ADB_MCP_DIR, script_name)
    if not os.path.exists(script_path):
        fatal("adb-mcp dosyası bulunamadı: %s" % script_path)

    # Yerel köprü asla bir HTTP proxy üzerinden geçmesin.
    for key in ("NO_PROXY", "no_proxy"):
        current = [p for p in os.environ.get(key, "").split(",") if p.strip()]
        for host in ("localhost", "127.0.0.1", "::1"):
            if host not in current:
                current.append(host)
        os.environ[key] = ",".join(current)

    sys.stdout = StdoutGuard(sys.stdout, sys.stderr)
    sys.path.insert(0, ADB_MCP_DIR)

    try:
        install_guards(app_key, app_label, app_accusative)
        server = load_server(script_path)
    except ImportError as error:
        fatal("Python ortamı eksik ya da bozuk: %s" % error)
    except Exception as error:
        fatal("%s yüklenemedi: %s: %s" % (script_name, type(error).__name__, error))

    if server is None:
        fatal("%s içinde MCP sunucusu bulunamadı" % script_name)

    if check_only:
        log("%s yüklendi (kontrol modu)" % script_name)
        return

    # Açılışı bekletme: proxy'yi arka planda kontrol et / başlat. İlk araç
    # çağrısı geldiğinde köprü hazır olur.
    threading.Thread(target=ensure_proxy, daemon=True).start()

    server.run()


if __name__ == "__main__":
    main()
