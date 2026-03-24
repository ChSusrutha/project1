/**
 * Local backend for this folder.
 * - Serves files from the current directory over http://localhost:<PORT>
 * - Default route `/` serves `yellow-circle.html`
 * - `/health` returns a small JSON payload
 *
 * No dependencies (uses Node built-ins) so it works with a simple `node server.js`.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const rootDir = __dirname;
const PORT = Number(process.env.PORT || 3000);

function pickDefaultHtml() {
  const candidates = ['yellow-circle.html', 'index.html.html', 'index.html'];
  for (const name of candidates) {
    const p = path.join(rootDir, name);
    if (fs.existsSync(p) && fs.statSync(p).isFile()) return name;
  }
  // Last-resort fallback: any html file in the root
  try {
    const files = fs.readdirSync(rootDir);
    const html = files.find((f) => f.toLowerCase().endsWith('.html'));
    return html || null;
  } catch {
    return null;
  }
}

const defaultHtml = pickDefaultHtml();

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.svg':
      return 'image/svg+xml; charset=utf-8';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.txt':
      return 'text/plain; charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}

function safeResolvePath(urlPathname) {
  // Decode without allowing null bytes to slip through.
  let decoded;
  try {
    decoded = decodeURIComponent(urlPathname);
  } catch {
    decoded = urlPathname;
  }
  if (!decoded || decoded.includes('\0')) return null;

  // Prevent path traversal: always resolve within rootDir.
  const requested = decoded.replace(/^\/+/, ''); // strip leading slashes
  const absPath = path.resolve(rootDir, requested);
  const rel = path.relative(rootDir, absPath);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return absPath;
}

function respond(res, statusCode, body, headers = {}) {
  res.writeHead(statusCode, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body);
}

function serveFile(res, filePath) {
  try {
    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      return false;
    }
    const contentType = contentTypeFor(filePath);
    const data = fs.readFileSync(filePath);
    res.writeHead(200, {
      'Content-Type': contentType,
      // Simple dev-friendly headers. Adjust if you need aggressive caching.
      'Cache-Control': 'no-store',
    });
    res.end(data);
    return true;
  } catch (e) {
    return false;
  }
}

function serveDefaultHtml(res) {
  if (!defaultHtml) {
    respond(res, 500, 'No default HTML file found in this folder.');
    return;
  }
  serveFile(res, path.join(rootDir, defaultHtml));
}

const server = http.createServer((req, res) => {
  if (!req || !req.url) {
    respond(res, 400, 'Bad request');
    return;
  }

  const requestUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = requestUrl.pathname;
  const method = (req.method || 'GET').toUpperCase();

  if (method !== 'GET') {
    respond(res, 405, 'Only GET is supported by this static backend.');
    return;
  }

  if (pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, at: new Date().toISOString() }, null, 2));
    return;
  }

  // Route `/` (and `/something/` without an extension) to the default HTML to support SPA-ish usage.
  const endsWithSlash = pathname.endsWith('/');
  const hasExtension = path.extname(pathname).length > 0;

  if (pathname === '/' || endsWithSlash) {
    serveDefaultHtml(res);
    return;
  }

  const absPath = safeResolvePath(pathname);
  if (!absPath) {
    respond(res, 400, 'Invalid path.');
    return;
  }

  // Try file first.
  const served = serveFile(res, absPath);
  if (served) return;

  // If the route looks like a "client route" (no file extension), fall back to default HTML.
  if (!hasExtension) {
    serveDefaultHtml(res);
    return;
  }

  respond(res, 404, `Not found: ${pathname}`);
});

server.listen(PORT, '127.0.0.1', () => {
  const defaultMsg = defaultHtml ? ` (default: ${defaultHtml})` : '';
  // eslint-disable-next-line no-console
  console.log(`Local server running at http://localhost:${PORT}/${defaultMsg}`);
  // eslint-disable-next-line no-console
  console.log(`Health check: http://localhost:${PORT}/health`);
});

