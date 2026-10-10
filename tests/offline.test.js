// Sunucular AĞ ERİŞİMİ TAMAMEN KAPALIYKEN açılıyor mu? (macOS sandbox-exec: deny network*)
//
// GokAI testlerinin parçası — tests/run.sh üzerinden çalıştırılır.
// GOKAI_SANDBOX_HOME: `GOKAI_TEST_MODE=1` ile kurulmuş sahte ev klasörü.
// Gerçek kuruluma (3001 portu, com.gokai.proxy servisi, Claude ayarları) dokunmaz.
const path = require("path");
const H = process.env.GOKAI_SANDBOX_HOME;
if (!H) { console.error("GOKAI_SANDBOX_HOME gerekli (tests/run.sh kullanın)"); process.exit(2); }
const G = path.join(H, "Library/Application Support/GokAI");
const fs = require("fs"); const os = require("os");
const { mcpHandshake } = require(path.join(G, "proxy", "gokai-doctor.js"));
const profile = "(version 1)(allow default)(deny network*)";
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "gk-off-"));
const wrap = (cmd, args, env) => ({ command: "/usr/bin/sandbox-exec", args: ["-p", profile, cmd, ...args], env });
(async () => {
  // önce: sandbox gerçekten ağı kesiyor mu?
  const { execFileSync } = require("child_process");
  let blocked = false;
  try { execFileSync("/usr/bin/sandbox-exec", ["-p", profile, "/usr/bin/curl", "-sS", "-m", "5", "-o", "/dev/null", "https://pypi.org/simple/mcp/"], { stdio: "pipe" }); } catch (e) { blocked = true; }
  console.log("ağ engeli çalışıyor (curl pypi.org başarısız):", blocked);
  const servers = {
    "GokAI Illustrator": wrap(G + "/venv/bin/python", ["-I", G + "/mcp/gokai_mcp.py", "illustrator"], { GOKAI_NO_AUTOSTART: "1" }),
    "GokAI Photoshop Plugin (ps-mcp.py)": wrap(G + "/venv/bin/python", ["-I", G + "/mcp/gokai_mcp.py", "photoshop"], { GOKAI_NO_AUTOSTART: "1" }),
    "GokAI Photoshop": wrap(G + "/node/bin/node", [G + "/photoshop-mcp/node_modules/@alisaitteke/photoshop-mcp/dist/index.js"], { LOG_LEVEL: "1", PSMCP_UPDATE_CHECK: "0", ANALYTICS_DISABLED: "1", PHOTOSHOP_MCP_HOME: scratch }),
  };
  let bad = 0;
  for (const [name, entry] of Object.entries(servers)) {
    const r = await mcpHandshake(entry, { timeoutMs: 30000 });
    console.log((r.ok ? "PASS" : "FAIL") + "  internetsiz açılış — " + name + ": " + (r.ok ? r.toolCount + " araç, " + r.ms + " ms" : r.error + "\n" + r.stderrTail));
    if (!r.ok) bad++;
  }
  fs.rmSync(scratch, { recursive: true, force: true });
  process.exit(bad || !blocked ? 1 : 0);
})();
