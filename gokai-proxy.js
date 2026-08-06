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
const VERSION = "1.0.0";

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

// install.sh'in yazdığı girdi adları — değişirse ikisini birden güncelle
const GOKAI_CONFIG_KEYS = [
    "GokAI Photoshop",
    "GokAI Photoshop Plugin",
    "GokAI Illustrator",
];

function readClaudeConfigStatus() {
    try {
        const raw = fs.readFileSync(CLAUDE_CONFIG_PATH, "utf8");
        const cfg = JSON.parse(raw);
        const servers = cfg.mcpServers || {};
        const entries = {};
        for (const key of GOKAI_CONFIG_KEYS) {
            entries[key] = Object.prototype.hasOwnProperty.call(servers, key);
        }
        return { found: true, entries };
    } catch (e) {
        return { found: false, entries: {}, error: e.code || String(e) };
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
        claude: readClaudeConfigStatus(),
    });
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
