'use strict';

// Optional remote preview transport only. No files, environment secrets or DB reads.
const http = require('node:http');
const net = require('node:net');
const { timingSafeEqual } = require('node:crypto');
const { parseArgs } = require('node:util');

const markerPath = '/__queueb_preview/health';
const methods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
const hopHeaders = new Set([
  'connection', 'keep-alive', 'proxy-connection', 'proxy-authenticate',
  'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade',
]);

function configurationError(message) {
  const error = new Error(message);
  error.code = 'QUEUEB_PREVIEW_CONFIG';
  throw error;
}

function checkedPort(value, allowEphemeral = false) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < (allowEphemeral ? 0 : 1) || parsed > 65535) {
    configurationError('Port preview/upstream tidak valid.');
  }
  return parsed;
}

function checkedTimeout(value) {
  if (!Number.isInteger(value) || value < 100 || value > 300_000) {
    configurationError('Batas waktu upstream preview tidak valid.');
  }
  return value;
}

function checkedPublicOrigin(value) {
  if (value === undefined || value === null || value === '') return null;
  let parsed;
  try { parsed = new URL(value); } catch { configurationError('Public origin harus satu origin HTTPS yang valid.'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      parsed.pathname !== '/' || parsed.search || parsed.hash ||
      net.isIP(parsed.hostname) || !/^[a-z0-9.-]+$/i.test(parsed.hostname) ||
      !parsed.hostname.includes('.') || parsed.hostname.endsWith('.')) {
    configurationError('Public origin harus satu domain HTTPS tanpa path, kredensial, query, atau fragment.');
  }
  return parsed;
}

function loopback(address = '') {
  const raw = address.replace(/^::ffff:/i, '');
  return raw === '::1' || (net.isIP(raw) === 4 && raw.startsWith('127.'));
}

function apiPath(path) {
  return path === '/api/v1' || path.startsWith('/api/v1/') ||
    path === '/socket.io' || path.startsWith('/socket.io/');
}

function socketIoPath(path) {
  return path === '/socket.io' || path.startsWith('/socket.io/');
}

// Inspect before normalization: URL() would silently remove traversal segments.
function requestPath(target) {
  if (typeof target !== 'string' || target.length > 16_384 ||
      !target.startsWith('/') || target.startsWith('//') ||
      /[^\x21-\x7e]|[\\#]/.test(target) || /%(?![0-9a-f]{2})/i.test(target)) {
    return null;
  }
  const path = target.split('?', 1)[0];
  if (path.includes('//') || /%(?:2f|5c|25|2e|3f|23)/i.test(path)) return null;
  let decoded;
  try { decoded = decodeURIComponent(path); } catch { return null; }
  if (/[\x00-\x1f\x7f\\?#]/.test(decoded) ||
      decoded.split('/').some((segment) => segment === '.' || segment === '..') ||
      apiPath(path) !== apiPath(decoded)) return null;
  return path;
}

function filteredHeaders(headers, upgrade = false, request = false) {
  const blocked = new Set(hopHeaders);
  for (const token of String(headers.connection || '').split(',')) {
    if (token.trim()) blocked.add(token.trim().toLowerCase());
  }
  const result = {};
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase();
    if (blocked.has(lower) || value === undefined) continue;
    if (request && (lower === 'forwarded' || lower.startsWith('x-forwarded-') ||
        lower === 'x-real-ip' || lower === 'x-original-url' || lower === 'x-rewrite-url')) continue;
    result[lower] = value;
  }
  if (upgrade) {
    result.connection = 'Upgrade';
    result.upgrade = 'websocket';
  }
  return result;
}

function serializedHeaders(headers) {
  let result = '';
  for (const [name, value] of Object.entries(headers)) {
    for (const part of Array.isArray(value) ? value : [value]) result += `${name}: ${part}\r\n`;
  }
  return result;
}

function sendError(res, status, message) {
  if (res.destroyed) return;
  if (res.headersSent) { res.destroy(); return; }
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    Connection: 'close',
  });
  res.end(JSON.stringify({ statusCode: status, message }));
}

function deniedDevelopmentPath(path) {
  return /^\/(?:\.git(?:ignore)?|\.env(?:\.[^/]*)?|\.dart_tool|\.cache)(?:\/|$)/.test(path) ||
    /^\/(?:dart-devtools|dartDevelopmentService)(?:\/|$)/.test(path);
}

function createPreviewProxy({
  port = 8085, webPort = 5173, apiPort = 3000, publicOrigin,
  instanceId, apiTimeoutMs = 30_000, webTimeoutMs = 60_000,
  upgradeTimeoutMs = 10_000,
} = {}) {
  if (process.env.NODE_ENV === 'production') {
    configurationError('Remote Preview tidak boleh dijalankan dalam mode production.');
  }
  const listenPort = checkedPort(port, true);
  const api = checkedPort(apiPort);
  const web = checkedPort(webPort);
  if (api === web || (listenPort !== 0 && (listenPort === api || listenPort === web))) {
    configurationError('Port proxy, Web, dan API harus berbeda.');
  }
  if (typeof instanceId !== 'string' || !/^[a-z0-9_-]{16,96}$/i.test(instanceId)) {
    configurationError('Instance ID preview wajib nonce unik 16-96 karakter.');
  }
  const expectedInstance = Buffer.from(instanceId);
  const publicUrl = checkedPublicOrigin(publicOrigin);
  const apiTimeout = checkedTimeout(apiTimeoutMs);
  const webTimeout = checkedTimeout(webTimeoutMs);
  const upgradeTimeout = checkedTimeout(upgradeTimeoutMs);
  const serverSockets = new Set();
  const upstreamSockets = new Set();
  const upstreamRequests = new Set();
  let stopping = false;

  function actualPort() {
    const address = server.address();
    return address && typeof address === 'object' ? address.port : listenPort;
  }

  function metadata() {
    return {
      service: 'queueb-ngrok-preview-proxy', version: 1, instanceId,
      listenHost: '127.0.0.1', listenPort: actualPort(),
      webUpstream: `http://127.0.0.1:${web}`,
      apiUpstream: `http://127.0.0.1:${api}`,
      publicOrigin: publicUrl ? publicUrl.origin : null,
    };
  }

  function localHost(host) {
    return host === `127.0.0.1:${actualPort()}` || host === `localhost:${actualPort()}`;
  }

  function markerAccess(req) {
    const provided = req.headers['x-queueb-preview-instance'];
    return localHost(req.headers.host.toLowerCase()) && typeof provided === 'string' &&
      Buffer.byteLength(provided) === expectedInstance.length &&
      timingSafeEqual(Buffer.from(provided), expectedInstance);
  }

  function accepted(req) {
    if (stopping || !loopback(req.socket.remoteAddress)) return false;
    let hostCount = 0;
    for (let index = 0; index < req.rawHeaders.length; index += 2) {
      if (req.rawHeaders[index].toLowerCase() === 'host') hostCount++;
    }
    if (hostCount !== 1 || typeof req.headers.host !== 'string') return false;
    const host = req.headers.host.toLowerCase();
    return localHost(host) || (publicUrl !== null &&
      (host === publicUrl.host || (!publicUrl.port && host === `${publicUrl.hostname}:443`)));
  }

  function upstreamOptions(req, path, upgrade = false) {
    const targetPort = apiPath(path) ? api : web;
    const headers = filteredHeaders(req.headers, upgrade, true);
    // Preserve original Origin, credentials, cookies and payload. No forwarded
    // header is trusted; the API retains its own exact-origin/auth checks.
    headers.host = `127.0.0.1:${targetPort}`;
    return { hostname: '127.0.0.1', port: targetPort, method: req.method, path: req.url, headers };
  }

  const server = http.createServer((req, res) => {
    const path = requestPath(req.url);
    if (path === null) { sendError(res, 400, 'Path preview tidak valid.'); return; }
    if (!accepted(req)) { sendError(res, 403, 'Host preview tidak diizinkan.'); return; }
    if (!methods.has(req.method)) {
      res.setHeader('Allow', [...methods].join(', '));
      sendError(res, 405, 'Metode preview tidak didukung.');
      return;
    }
    if (path.startsWith('/__queueb_preview/') || path === '/__queueb_preview') {
      if (path !== markerPath || !markerAccess(req)) {
        sendError(res, 404, 'Endpoint tidak tersedia.');
      } else if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.setHeader('Allow', 'GET, HEAD');
        sendError(res, 405, 'Metode metadata tidak didukung.');
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
        res.end(req.method === 'HEAD' ? undefined : JSON.stringify(metadata()));
      }
      return;
    }
    if (!localHost(req.headers.host.toLowerCase()) &&
        /^\/api\/v1\/health\/?$/i.test(decodeURIComponent(path))) {
      sendError(res, 404, 'Endpoint tidak tersedia.');
      return;
    }
    if (deniedDevelopmentPath(path)) { sendError(res, 404, 'Endpoint tidak tersedia.'); return; }
    let timedOut = false;
    const proxy = http.request(upstreamOptions(req, path), (upstream) => {
      res.writeHead(upstream.statusCode || 502, filteredHeaders(upstream.headers));
      upstream.on('error', () => res.destroy());
      upstream.on('aborted', () => res.destroy());
      upstream.pipe(res);
    });
    upstreamRequests.add(proxy);
    proxy.once('close', () => upstreamRequests.delete(proxy));
    proxy.setTimeout(apiPath(path) ? apiTimeout : webTimeout, () => {
      timedOut = true;
      proxy.destroy();
    });
    proxy.on('error', () => sendError(res, timedOut ? 504 : 502,
      timedOut ? 'Upstream preview belum merespons tepat waktu.' : 'Upstream preview belum dapat dihubungi.'));
    req.on('aborted', () => proxy.destroy());
    req.on('error', () => proxy.destroy());
    res.on('close', () => { if (!res.writableFinished) proxy.destroy(); });
    req.pipe(proxy); // Forward once; do not retry POST or other mutations.
  });

  server.on('upgrade', (req, socket, head) => {
    const path = requestPath(req.url);
    if (path === null || !accepted(req) || req.method !== 'GET' ||
        !socketIoPath(path) || String(req.headers.upgrade).toLowerCase() !== 'websocket') {
      const status = path === null ? 400 : 403;
      socket.end(`HTTP/1.1 ${status} Preview Rejected\r\nConnection: close\r\n\r\n`);
      return;
    }
    socket.pause();
    const proxy = http.request(upstreamOptions(req, path, true));
    upstreamRequests.add(proxy);
    proxy.once('close', () => upstreamRequests.delete(proxy));
    let handedOff = false;
    let replied = false;
    const fail = (status = 502) => {
      if (socket.destroyed || handedOff || replied) return;
      replied = true;
      socket.end(`HTTP/1.1 ${status} Preview Upstream Error\r\nConnection: close\r\n\r\n`);
    };
    proxy.setTimeout(upgradeTimeout, () => { fail(504); proxy.destroy(); });
    proxy.on('error', () => {
      if (replied && !handedOff) {
        if (!socket.writableEnded) socket.destroy();
      } else {
        fail();
      }
    });
    socket.on('error', () => proxy.destroy());
    socket.on('close', () => { if (!handedOff) proxy.destroy(); });
    proxy.on('upgrade', (upstream, upstreamSocket, upstreamHead) => {
      if (socket.destroyed || replied ||
          String(upstream.headers.upgrade).toLowerCase() !== 'websocket') {
        upstreamSocket.destroy();
        fail();
        return;
      }
      handedOff = true;
      proxy.setTimeout(0);
      socket.setTimeout(0);
      upstreamSocket.setTimeout(0);
      upstreamSockets.add(upstreamSocket);
      upstreamSocket.once('close', () => upstreamSockets.delete(upstreamSocket));
      const headers = filteredHeaders(upstream.headers, true);
      socket.write(`HTTP/1.1 101 Switching Protocols\r\n${serializedHeaders(headers)}\r\n`);
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      upstreamSocket.on('error', () => socket.destroy());
      upstreamSocket.on('close', () => socket.destroy());
      socket.on('error', () => upstreamSocket.destroy());
      socket.on('close', () => upstreamSocket.destroy());
      upstreamSocket.pipe(socket);
      socket.pipe(upstreamSocket);
    });
    proxy.on('response', (upstream) => {
      if (socket.destroyed || replied) { upstream.destroy(); return; }
      replied = true;
      proxy.setTimeout(0);
      const headers = filteredHeaders(upstream.headers);
      headers.connection = 'close';
      socket.write(`HTTP/1.1 ${upstream.statusCode || 502} ${upstream.statusMessage || 'Rejected'}\r\n${serializedHeaders(headers)}\r\n`);
      upstream.on('error', () => socket.destroy());
      upstream.on('aborted', () => socket.destroy());
      upstream.pipe(socket);
    });
    proxy.end();
  });
  server.on('connect', (_req, socket) => socket.end('HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n'));
  server.on('connection', (socket) => {
    serverSockets.add(socket);
    socket.once('close', () => serverSockets.delete(socket));
  });
  server.on('clientError', (_error, socket) => {
    if (!socket.destroyed) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  });
  server.headersTimeout = 15_000;
  server.requestTimeout = 120_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 200;
  Object.defineProperty(server, 'previewInfo', { get: metadata });
  server.closePreview = (callback) => {
    stopping = true;
    for (const request of upstreamRequests) request.destroy();
    for (const socket of upstreamSockets) socket.destroy();
    for (const socket of serverSockets) socket.destroy();
    return server.close(callback);
  };
  return server;
}

if (require.main === module) {
  try {
    const { values } = parseArgs({
      strict: true, allowPositionals: false,
      options: {
        port: { type: 'string', default: '8085' },
        'web-port': { type: 'string', default: '5173' },
        'api-port': { type: 'string', default: '3000' },
        'public-origin': { type: 'string' },
        'instance-id': { type: 'string' },
      },
    });
    const port = checkedPort(values.port);
    const server = createPreviewProxy({
      port, webPort: checkedPort(values['web-port']), apiPort: checkedPort(values['api-port']),
      publicOrigin: values['public-origin'], instanceId: values['instance-id'],
    });
    server.on('error', (error) => {
      const code = ['EADDRINUSE', 'EACCES', 'EADDRNOTAVAIL'].includes(error.code) ? error.code : 'LISTEN_ERROR';
      process.stderr.write(`Preview proxy gagal: ${code}. Proses lain tidak dihentikan.\n`);
      process.exitCode = 1;
    });
    server.listen(port, '127.0.0.1', () => {
      process.stdout.write(`Preview proxy siap: http://127.0.0.1:${port}\n`);
    });
    let closing = false;
    const close = () => { if (!closing) { closing = true; server.closePreview(); } };
    process.once('SIGINT', close);
    process.once('SIGTERM', close);
  } catch (error) {
    process.stderr.write(`${error.code === 'QUEUEB_PREVIEW_CONFIG' ? error.message : 'Argumen atau konfigurasi preview proxy tidak valid.'}\n`);
    process.exitCode = 1;
  }
}

module.exports = { createPreviewProxy };
