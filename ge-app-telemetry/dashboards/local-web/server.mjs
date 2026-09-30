import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.PORT || process.argv[2] || '8085', 10);
const HOST = '0.0.0.0';
const DATA_FILE = path.join(__dirname, 'data', 'telemetry.json');
const PUBLIC_DIR = path.join(__dirname, 'public');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // CORS headers for local access
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Health check
  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', time: new Date().toISOString() }));
    return;
  }

  // Get current telemetry data
  if (url.pathname === '/api/data' && req.method === 'GET') {
    if (!fs.existsSync(DATA_FILE)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Telemetry data file not found. Run fetch_data.sh first.' }));
      return;
    }
    const data = fs.readFileSync(DATA_FILE, 'utf-8');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(data);
    return;
  }

  // Refresh telemetry data from BigQuery
  if (url.pathname === '/api/refresh' && req.method === 'POST') {
    try {
      const fetchScript = path.join(__dirname, 'fetch_data.sh');
      const { stdout, stderr } = await execAsync(`"${fetchScript}"`);
      const data = fs.readFileSync(DATA_FILE, 'utf-8');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(data);
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Failed to refresh telemetry from BigQuery', details: err.message }));
    }
    return;
  }

  // Serve static assets from public/
  let filePath = path.join(PUBLIC_DIR, url.pathname === '/' ? 'index.html' : url.pathname);
  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    filePath = path.join(PUBLIC_DIR, 'index.html');
  }

  const ext = path.extname(filePath).toLowerCase();
  const contentType = MIME_TYPES[ext] || 'application/octet-stream';

  try {
    const content = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(content);
  } catch (err) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[Google Antigravity Telemetry Dashboard] Server running on http://${HOST}:${PORT}`);
  console.log(`Cloudtop External URL: http://${os.hostname()}:${PORT}`);
});
