'use strict';

const path = require('node:path');
const { parseArgs } = require('node:util');

const expectedRejections = new Set(['UNAUTHORIZED', 'ORIGIN_NOT_ALLOWED']);
const loopbackHosts = new Set(['127.0.0.1', 'localhost', '[::1]']);

function checkedOptions({ url, origin, expected } = {}) {
  if (typeof url !== 'string' || typeof origin !== 'string' ||
      !expectedRejections.has(expected)) return null;
  try {
    const target = new URL(url);
    const source = new URL(origin);
    if (target.protocol !== 'http:' || !loopbackHosts.has(target.hostname) ||
        target.username || target.password || target.search || target.hash ||
        target.pathname !== '/') return null;
    if (source.origin !== origin || source.username || source.password ||
        source.search || source.hash || source.pathname !== '/' ||
        !(source.protocol === 'https:' ||
          (source.protocol === 'http:' && loopbackHosts.has(source.hostname)))) return null;
    return { url: target.origin, origin, expected };
  } catch {
    return null;
  }
}

/**
 * A rejected, deliberately invalid handshake is the only successful outcome.
 * No account authentication, room join, application event or retry is sent.
 */
async function probePreviewSocket(options) {
  const checked = checkedOptions(options);
  if (!checked) return { ok: false, code: 'INVALID_ARGUMENTS' };
  let io;
  try {
    ({ io } = require(path.join(__dirname, '../../apps/api/node_modules/socket.io-client')));
  } catch {
    return { ok: false, code: 'CLIENT_UNAVAILABLE' };
  }
  return new Promise((resolve) => {
    let socket;
    let timer;
    let finished = false;
    const onConnect = () => finish(false, 'AUTH_BYPASSED');
    const onConnectError = (error) => {
      if (error && typeof error.message === 'string' &&
          error.message === checked.expected) {
        finish(true, 'EXPECTED_REJECTION');
      } else {
        // Never print a server-provided message, error data, or payload.
        finish(false, 'UNEXPECTED_REJECTION');
      }
    };
    function finish(ok, code) {
      if (finished) return;
      finished = true;
      if (timer) clearTimeout(timer);
      if (socket) {
        socket.off('connect', onConnect);
        socket.off('connect_error', onConnectError);
        socket.disconnect();
        socket.io.disconnect();
      }
      resolve({ ok, code });
    }
    try {
      socket = io(`${checked.url}/queue`, {
        path: '/socket.io',
        transports: ['websocket'],
        forceNew: true,
        multiplex: false,
        autoConnect: false,
        reconnection: false,
        timeout: 5000,
        auth: { token: 'preview-readiness-invalid' },
        extraHeaders: { Origin: checked.origin },
      });
      socket.on('connect', onConnect);
      socket.on('connect_error', onConnectError);
      timer = setTimeout(() => finish(false, 'TIMEOUT'), 5000);
      socket.connect();
    } catch {
      finish(false, 'CLIENT_FAILURE');
    }
  });
}

module.exports = { probePreviewSocket };

if (require.main === module) {
  // This short-lived diagnostic must not inherit packet/transport debug logs.
  process.env.DEBUG = '';
  process.env.NODE_DEBUG = '';
  (async () => {
    try {
      const { values } = parseArgs({
        options: {
          url: { type: 'string' },
          origin: { type: 'string' },
          expect: { type: 'string' },
        },
        allowPositionals: false,
        strict: true,
      });
      const result = await probePreviewSocket({
        url: values.url,
        origin: values.origin,
        expected: values.expect,
      });
      process.stdout.write(result.ok ? 'PASS\n' : `FAIL ${result.code}\n`);
      process.exitCode = result.ok ? 0 : result.code === 'INVALID_ARGUMENTS' ? 2 : 1;
    } catch {
      process.stdout.write('FAIL INVALID_ARGUMENTS\n');
      process.exitCode = 2;
    }
  })();
}
