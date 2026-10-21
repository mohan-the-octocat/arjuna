import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.PORT || process.argv[2] || '8085', 10);
// Default: this machine only. HOST=0.0.0.0 allows access from other machines
// (e.g. a laptop browsing to a workstation); the server has no authentication,
// so only do that on trusted networks.
const HOST = process.env.HOST || '127.0.0.1';
const DATA_FILE = path.join(__dirname, 'data', 'telemetry.json');
const PUBLIC_DIR = path.join(__dirname, 'public');
const FETCH_SCRIPT = path.join(__dirname, 'fetch_data.sh');
const SAFE_ID = /^[A-Za-z0-9_.:-]+$/;

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}

// Re-fetch with the same project/dataset as the current data file (if any).
function currentSource() {
  try {
    const meta = JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8')).metadata || {};
    if (SAFE_ID.test(meta.project_id || '') && SAFE_ID.test(meta.dataset_id || '')) {
      return [meta.project_id, meta.dataset_id];
    }
  } catch { /* no or unreadable data file: fall back to fetch_data.sh defaults */ }
  return [];
}

let refreshing = null; // serialize concurrent refreshes

async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/api/health') {
    sendJson(res, 200, { status: 'ok', time: new Date().toISOString() });
    return;
  }

  if (url.pathname === '/api/data' && req.method === 'GET') {
    if (!fs.existsSync(DATA_FILE)) {
      sendJson(res, 404, { error: 'Telemetry data file not found. Run fetch_data.sh first.' });
      return;
    }
    sendJson(res, 200, fs.readFileSync(DATA_FILE, 'utf-8'));
    return;
  }

  if (url.pathname === '/api/refresh' && req.method === 'POST') {
    // Custom header: browsers can't send it cross-site without a CORS preflight,
    // which this server never approves, so other websites can't trigger a refresh.
    if (req.headers['x-requested-with'] !== 'dashboard') {
      sendJson(res, 403, { error: 'Forbidden' });
      return;
    }
    try {
      refreshing ??= execFileAsync(FETCH_SCRIPT, currentSource(), { timeout: 300000 })
        .finally(() => { refreshing = null; });
      await refreshing;
      sendJson(res, 200, fs.readFileSync(DATA_FILE, 'utf-8'));
    } catch (err) {
      sendJson(res, 500, { error: 'Failed to refresh telemetry from BigQuery', details: (err.stderr || err.message || '').toString().slice(-2000) });
    }
    return;
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  // Static assets from public/ (never outside it)
  let filePath = path.resolve(PUBLIC_DIR, '.' + (url.pathname === '/' ? '/index.html' : url.pathname));
  if (!filePath.startsWith(PUBLIC_DIR + path.sep) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    filePath = path.join(PUBLIC_DIR, 'index.html');
  }
  const contentType = MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
  res.writeHead(200, { 'Content-Type': contentType });
  res.end(req.method === 'HEAD' ? undefined : fs.readFileSync(filePath));
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error(err);
    if (!res.headersSent) sendJson(res, 500, { error: 'Internal error' });
    else res.end();
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[Google Antigravity Telemetry Dashboard] Server running on http://${HOST}:${PORT}`);
  if (HOST === '0.0.0.0') console.log(`Workstation URL: http://${os.hostname()}:${PORT}`);
});
