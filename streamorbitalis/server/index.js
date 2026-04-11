'use strict';

const crypto    = require('crypto');
const express   = require('express');
const http      = require('http');
const WebSocket = require('ws');
const path      = require('path');


const fs = require('fs');
// Pour robustesse, utiliser un chemin absolu basé sur le dossier du script lancé
const BASE_DIR = process.cwd();
const app  = express();
const PORT = process.env.PORT || 5003;

app.disable('x-powered-by');
app.set('trust proxy', true);

const MAX_FRAME_BYTES = Number(process.env.MAX_FRAME_BYTES || 2 * 1024 * 1024);

function resolveSecret(name) {
  const fromEnv = process.env[name];
  if (fromEnv && fromEnv.trim()) return fromEnv.trim();
  const fallback = crypto.randomBytes(24).toString('hex');
  console.warn(`[security] ${name} absent: fallback ephemere genere pour cette session.`);
  return fallback;
}

const PUSH_TOKEN = resolveSecret('PUSH_TOKEN');
const BROADCASTER_KEY = resolveSecret('BROADCASTER_KEY');
const ALLOWED_ORIGIN = (process.env.ALLOWED_ORIGIN || '').trim();

// ── Multer for Seestar upload ───────────────────────────────────────────
const multer = require('multer');
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_FRAME_BYTES } });

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function getClientIp(req) {
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.trim()) {
    return xff.split(',')[0].trim();
  }
  const xr = req.headers['x-real-ip'];
  if (typeof xr === 'string' && xr.trim()) return xr.trim();
  return req.ip || req.socket?.remoteAddress || 'unknown';
}

const rateBuckets = new Map();

function isRateLimited(req, key, limit, windowMs) {
  const bucketKey = `${getClientIp(req)}:${key}`;
  const now = Date.now();
  const bucket = rateBuckets.get(bucketKey);

  if (!bucket || now > bucket.resetAt) {
    rateBuckets.set(bucketKey, { count: 1, resetAt: now + windowMs });
    return false;
  }

  if (bucket.count >= limit) {
    return true;
  }

  bucket.count += 1;
  return false;
}

function isImageBuffer(buf) {
  if (!buf || buf.length < 12) return false;
  const isJpeg = buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff;
  const isPng =
    buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47 &&
    buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a;
  const isWebp =
    buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
    buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50;
  return isJpeg || isPng || isWebp;
}

function isAllowedOrigin(req) {
  const origin = req.headers.origin || '';
  if (!origin) return true;  // app native Android — pas d'Origin header, auth par token
  if (!ALLOWED_ORIGIN) return true;
  return safeEqual(origin, ALLOWED_ORIGIN);
}

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(self), microphone=(self), geolocation=()');
  res.setHeader('Feature-Policy', 'microphone \'self\'');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  next();
});

// ── Static files ────────────────────────────────────────────────────────────
app.use((req, res, next) => {
  if (req.path === '/broadcaster.html') return res.status(404).end();
  next();
});
app.use(express.static(path.join(__dirname, '../public')));

function hasRelayToken(req) {
  return safeEqual(req.query.token, PUSH_TOKEN);
}

function hasBroadcasterToken(req) {
  return safeEqual(req.get('x-broadcaster-token'), broadcasterSessionToken);
}

function hasBroadcasterKey(req) {
  return safeEqual(String(req.query.k || req.get('x-broadcaster-key') || ''), BROADCASTER_KEY);
}

// ── Seestar upload endpoint ─────────────────────────────────────────────
app.post('/seestar-upload', upload.single('image'), (req, res) => {
  if (isRateLimited(req, 'seestar-upload', 700, 60_000)) return res.status(429).send('Too many requests');
  if (!isAllowedOrigin(req)) return res.status(403).send('Forbidden origin');
  if (!hasRelayToken(req) && !hasBroadcasterToken(req)) return res.status(401).send('Unauthorized');
  if (!req.file || !req.file.buffer) return res.status(400).send('No image');
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(req.file.mimetype)) return res.status(400).send('Invalid content type');
  if (!isImageBuffer(req.file.buffer)) return res.status(400).send('Invalid image data');
  latestFrame = req.file.buffer;
  isLive = true;
  for (const vws of viewers) {
    if (vws.readyState === WebSocket.OPEN) vws.send(latestFrame);
  }
  for (const cvws of classroomViewers) {
    if (cvws.readyState === WebSocket.OPEN) cvws.send(latestFrame);
  }
  res.status(200).send('OK');
});

// ── Seestar stop endpoint ──────────────────────────────────────────────────
app.post('/seestar-stop', (req, res) => {
  if (!hasRelayToken(req)) return res.status(401).send('Unauthorized');
  isLive = false;
  latestFrame = null;
  const offlineMsg = JSON.stringify({ type: 'offline' });
  for (const vws of viewers) {
    if (vws.readyState === WebSocket.OPEN) vws.send(offlineMsg);
  }
  for (const cvws of classroomViewers) {
    if (cvws.readyState === WebSocket.OPEN) cvws.send(offlineMsg);
  }
  console.log('[stream] Seestar stop signal reçu');
  res.status(200).send('OK');
});

// ── Push-frame HTTP endpoint (relay depuis PC via ffmpeg) ────────────────────
app.use('/push-frame', express.raw({ type: '*/*', limit: `${MAX_FRAME_BYTES}b` }));
app.post('/push-frame', (req, res) => {
  if (isRateLimited(req, 'push-frame', 60, 60_000)) return res.status(429).send('Too many requests');
  if (!isAllowedOrigin(req)) return res.status(403).send('Forbidden origin');
  if (!hasRelayToken(req)) return res.status(401).send('Unauthorized');
  if (!req.body || !req.body.length)  return res.status(400).send('No data');
  if (req.body.length > MAX_FRAME_BYTES) return res.status(413).send('Payload too large');
  if (!isImageBuffer(req.body)) return res.status(400).send('Invalid image data');

  latestFrame = req.body;
  isLive = true;

  for (const vws of viewers) {
    if (vws.readyState === WebSocket.OPEN) vws.send(latestFrame);
  }
  for (const cvws of classroomViewers) {
    if (cvws.readyState === WebSocket.OPEN) cvws.send(latestFrame);
  }
  res.status(200).send('OK');
});

// ── Routes ──────────────────────────────────────────────────────────────────
app.get('/', (_req, res) =>
  res.sendFile(path.join(__dirname, '../public/index.html')));

app.get('/broadcast', (req, res) => {
  if (!hasBroadcasterKey(req)) return res.status(403).send('Forbidden');
  res.setHeader('Cache-Control', 'no-store');
  return res.sendFile(path.join(__dirname, '../public/broadcaster.html'));
});

app.get('/classroom', (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  return res.sendFile(path.join(__dirname, '../public/classroom.html'));
});

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    live: isLive,
    viewers: viewers.size,
    hasFrame: Boolean(latestFrame),
  });
});

// ── HTTP + WebSocket server ─────────────────────────────────────────────────
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server, maxPayload: MAX_FRAME_BYTES });

// ── State ───────────────────────────────────────────────────────────────────
let broadcaster   = null;
let broadcasterSessionToken = null;
let latestFrame   = null;   // Buffer — dernière image JPEG
let isLive        = false;
const viewers     = new Set();
const classroomViewers = new Set();  // WebSocket connections for classroom chat

// Persistance de l'historique du chat
const MESSAGES_FILE = path.join(BASE_DIR, 'messages.json');
let messages = [];
// Charger l'historique au démarrage
try {
  if (fs.existsSync(MESSAGES_FILE)) {
    const data = fs.readFileSync(MESSAGES_FILE, 'utf8');
    messages = JSON.parse(data);
    if (!Array.isArray(messages)) messages = [];
    console.log('[chat] messages.json chargé:', messages.length, 'messages');
  } else {
    console.log('[chat] Pas de messages.json, démarrage avec historique vide');
  }
} catch (e) {
  messages = [];
  console.error('[chat] Erreur lecture messages.json:', e);
}
function saveMessages() {
  try {
    fs.writeFileSync(MESSAGES_FILE, JSON.stringify(messages.slice(-20)), 'utf8');
    console.log('[chat] messages.json sauvegardé:', messages.length, 'messages');
  } catch (e) {
    console.error('[chat] Erreur écriture messages.json:', e);
  }
}

// ── Réinitialisation automatique du chat toutes les 24h ────────────────────
const RESET_TS_FILE = path.join(BASE_DIR, 'chat_reset_ts.json');
let lastResetTimestamp = 0;
try {
  if (fs.existsSync(RESET_TS_FILE)) {
    const d = JSON.parse(fs.readFileSync(RESET_TS_FILE, 'utf8'));
    lastResetTimestamp = typeof d.lastReset === 'number' ? d.lastReset : 0;
  }
} catch (e) { lastResetTimestamp = 0; }

function saveResetTimestamp() {
  try { fs.writeFileSync(RESET_TS_FILE, JSON.stringify({ lastReset: lastResetTimestamp })); } catch (e) {}
}

function doAutoReset() {
  messages.length = 0;
  saveMessages();
  lastResetTimestamp = Date.now();
  saveResetTimestamp();
  const resetMsg = JSON.stringify({ type: 'reset-chat' });
  const emptyHistory = JSON.stringify({ type: 'messages', data: [] });
  for (const cvws of classroomViewers) {
    if (cvws.readyState === WebSocket.OPEN) {
      cvws.send(resetMsg);
      cvws.send(emptyHistory);
    }
  }
  console.log('[chat] Réinitialisation automatique 24h effectuée');
  scheduleNextReset();
}

function scheduleNextReset() {
  const elapsed = lastResetTimestamp > 0 ? Date.now() - lastResetTimestamp : 0;
  const remaining = Math.max(0, 24 * 60 * 60 * 1000 - elapsed);
  console.log(`[chat] Prochain reset auto dans ${Math.round(remaining / 3600000)}h`);
  setTimeout(doAutoReset, remaining);
}

// Initialiser le timestamp si c'est la première fois
if (lastResetTimestamp === 0) {
  lastResetTimestamp = Date.now();
  saveResetTimestamp();
}
scheduleNextReset();

// ── WebSocket ───────────────────────────────────────────────────────────────
wss.on('connection', (ws, req) => {
  if (!isAllowedOrigin(req)) {
    ws.close(1008, 'Forbidden origin');
    return;
  }

  let url;
  try { url = new URL(req.url, 'http://localhost'); }
  catch { ws.close(); return; }

  const role = url.searchParams.get('role');
  const username = url.searchParams.get('u') || 'Visiteur ' + Math.floor(Math.random() * 1000);

  // ── BROADCASTER ───────────────────────────────────────────────────────────
  if (role === 'broadcaster') {
    if (!safeEqual(url.searchParams.get('k') || '', BROADCASTER_KEY)) {
      ws.close(1008, 'Unauthorized broadcaster');
      return;
    }
    if (broadcaster && broadcaster.readyState === WebSocket.OPEN) {
      ws.close(1013, 'Broadcaster already connected');
      return;
    }
    broadcaster = ws;
    broadcasterSessionToken = crypto.randomBytes(24).toString('hex');
    isLive = true;
    latestFrame = null;
    console.log('[stream] Émetteur connecté');

    ws.send(JSON.stringify({ type: 'broadcaster-session', token: broadcasterSessionToken }));
    // Envoyer le nombre de viewers
    ws.send(JSON.stringify({ type: 'viewer-count', count: viewers.size }));

    ws.on('message', (data) => {
      // Les données binaires = image JPEG
      if (Buffer.isBuffer(data) || data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
        const frame = Buffer.from(data);
        if (frame.length > MAX_FRAME_BYTES || !isImageBuffer(frame)) return;
        latestFrame = frame;
        // Diffuser à tous les viewers
        for (const vws of viewers) {
          if (vws.readyState === WebSocket.OPEN) {
            vws.send(latestFrame);
          }
        }
        // Diffuser aussi à tous les viewers classroom
        for (const cvws of classroomViewers) {
          if (cvws.readyState === WebSocket.OPEN) {
            cvws.send(latestFrame);
          }
        }
      } else {
        // Gestion des commandes JSON
        try {
          const msg = JSON.parse(data.toString());
          if (msg.type === 'reset-chat') {
            messages.length = 0; // Vide l'historique
            saveMessages();
            // Notifier tous les viewers classroom
            const resetMsg = JSON.stringify({ type: 'reset-chat' });
            const emptyHistory = JSON.stringify({ type: 'messages', data: [] });
            for (const cvws of classroomViewers) {
              if (cvws.readyState === WebSocket.OPEN) {
                cvws.send(resetMsg);
                cvws.send(emptyHistory);
              }
            }
            console.log('[broadcaster] Forum nettoyé par le diffuseur');
          }
        } catch (e) {
          // Ignore les JSON invalides
        }
      }
    });

    ws.on('close', () => {
      broadcaster = null;
      broadcasterSessionToken = null;
      isLive = false;
      latestFrame = null;
      // Prévenir tous les viewers
      for (const vws of viewers) {
        if (vws.readyState === WebSocket.OPEN) {
          vws.send(JSON.stringify({ type: 'offline' }));
        }
      }
      console.log('[stream] Émetteur déconnecté');
    });

    ws.on('error', () => ws.close());

  // ── CLASSROOM VIEWER ─────────────────────────────────────────────────────
  } else if (role === 'classroom') {
    classroomViewers.add(ws);
    console.log(`[classroom] Viewer connecté (total: ${classroomViewers.size})`);

    // On conserve l'historique du chat (jusqu'à 20 messages)

    // Envoyer l'état live + dernière image si disponible
    if (isLive) {
      ws.send(JSON.stringify({ type: 'live' }));
      if (latestFrame) ws.send(latestFrame);
    } else {
      ws.send(JSON.stringify({ type: 'offline' }));
    }

    // Envoyer l'historique du chat (jusqu'à 20 derniers messages)
    ws.send(JSON.stringify({ type: 'messages', data: messages }));

    // Send current online count
    ws.send(JSON.stringify({ type: 'viewer-count', count: classroomViewers.size }));

    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'message' && msg.text && typeof msg.text === 'string') {
          const msgUsername = (msg.username && typeof msg.username === 'string' && msg.username.trim())
            ? msg.username.trim().substring(0, 50)
            : username.substring(0, 50);
          const chatMsg = {
            username: msgUsername,
            text: msg.text.substring(0, 500),
            timestamp: new Date().toISOString()
          };
          messages.push(chatMsg);
          if (messages.length > 20) messages.shift();
          saveMessages();
          // Broadcast to all classroom viewers
          const msgJson = JSON.stringify({ type: 'message', data: chatMsg });
          for (const cvws of classroomViewers) {
            if (cvws.readyState === WebSocket.OPEN) {
              cvws.send(msgJson);
            }
          }
        }
      } catch (e) {
        // Invalid JSON, ignore
      }
    });

    ws.on('close', () => {
      classroomViewers.delete(ws);
      console.log(`[classroom] Viewer déconnecté (total: ${classroomViewers.size})`);
      // Notify others of count change
      const countMsg = JSON.stringify({ type: 'viewer-count', count: classroomViewers.size });
      for (const cvws of classroomViewers) {
        if (cvws.readyState === WebSocket.OPEN) cvws.send(countMsg);
      }
    });

    ws.on('error', () => ws.close());

  // ── VIEWER ────────────────────────────────────────────────────────────────
  } else {
    viewers.add(ws);
    console.log(`[stream] Viewer connecté (total: ${viewers.size})`);

    // Envoyer l'état + dernière frame si dispo
    if (isLive) {
      ws.send(JSON.stringify({ type: 'live' }));
      if (latestFrame) ws.send(latestFrame);
    } else {
      ws.send(JSON.stringify({ type: 'offline' }));
    }

    // Informer le broadcaster du nouveau nombre
    if (broadcaster && broadcaster.readyState === WebSocket.OPEN) {
      broadcaster.send(JSON.stringify({ type: 'viewer-count', count: viewers.size }));
    }

    ws.on('close', () => {
      viewers.delete(ws);
      if (broadcaster && broadcaster.readyState === WebSocket.OPEN) {
        broadcaster.send(JSON.stringify({ type: 'viewer-count', count: viewers.size }));
      }
      console.log(`[stream] Viewer déconnecté (total: ${viewers.size})`);
    });

    ws.on('error', () => ws.close());
  }
});

server.listen(PORT, () =>
  console.log(`[stream] Serveur snapshot JPEG sur le port ${PORT}`));
