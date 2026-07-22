/**
 * Minimal token-holding proxy for the external chatbot widget.
 *
 * Why this exists: the widget can talk to Salesforce straight from the browser, but that means
 * pasting an integration-user OAuth token into the customer's browser and fighting CORS. This
 * proxy fixes both:
 *   - It mints and caches the OAuth access token server-side (Client Credentials flow), so the
 *     token never reaches the browser.
 *   - It serves the widget and the API from the SAME origin, so there is no cross-origin request
 *     and therefore no CORS to configure.
 *
 * The browser talks to THIS server; THIS server talks to Salesforce. Point the widget's
 * "API base URL" at "/agent" (same origin) and leave the bearer token blank.
 *
 * Dependency-free: Node 18+ only (uses the built-in global fetch and http module).
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

// ── Load .env directly (no shell) ──────────────────────────────────────────────
// Reading the file in-process avoids passing values through the shell, which on Git Bash /
// MSYS (Windows) rewrites anything that looks like a Unix path — e.g. turning
// `/services/apexrest/aao/agent` into `C:/Program Files/Git/services/...`. Real environment
// variables still win over the file.
(function loadDotenv() {
  let raw;
  try {
    raw = fs.readFileSync(path.join(__dirname, '.env'), 'utf8');
  } catch (_) {
    return; // no .env is fine — rely on the real environment
  }
  for (const line of raw.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue; // skip blanks and # comments
    let val = m[2].trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1); // tolerate quotes if someone added them
    }
    if (process.env[m[1]] === undefined) process.env[m[1]] = val;
  }
})();

// ── Config (from environment; see .env.example) ────────────────────────────────
const PORT = process.env.PORT || 8080;
const SF_LOGIN_URL = (process.env.SF_LOGIN_URL || '').replace(/\/$/, '');
const SF_CLIENT_ID = process.env.SF_CLIENT_ID || '';
const SF_CLIENT_SECRET = process.env.SF_CLIENT_SECRET || '';

// The Apex REST root for AgentChatApi. When AAO is installed as a MANAGED PACKAGE, Salesforce
// inserts the package namespace into the path, so the endpoint is
// `/services/apexrest/aao/agent` — set SF_APEXREST_PATH to that. For an unmanaged source deploy
// it stays the default `/services/apexrest/agent`. No trailing slash.
const SF_APEXREST_PATH = (
  process.env.SF_APEXREST_PATH || '/services/apexrest/agent'
).replace(/\/$/, '');

if (!SF_LOGIN_URL || !SF_CLIENT_ID || !SF_CLIENT_SECRET) {
  console.error(
    'Missing config. Set SF_LOGIN_URL, SF_CLIENT_ID and SF_CLIENT_SECRET ' +
      '(see .env.example) before starting the proxy.'
  );
  process.exit(1);
}

// ── OAuth token cache (Client Credentials flow) ────────────────────────────────
// One integration-user token, reused across requests and refreshed a little before it expires.
// `instance_url` from the token response is where the REST calls go — it can differ from the
// login URL (e.g. after a My Domain redirect), so we always use what Salesforce hands back.
let cached = { token: null, instanceUrl: null, expiresAt: 0 };

async function getToken() {
  const now = Date.now();
  if (cached.token && now < cached.expiresAt) {
    return cached;
  }

  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: SF_CLIENT_ID,
    client_secret: SF_CLIENT_SECRET,
  });

  const res = await fetch(SF_LOGIN_URL + '/services/oauth2/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) {
    // Surface Salesforce's own error (e.g. "unsupported_grant_type") to the server log.
    const detail = data.error_description || data.error || res.statusText;
    throw new Error('OAuth token request failed: ' + detail);
  }

  // Client Credentials responses don't include expires_in; assume a conservative 2h and refresh
  // 5 min early. If the token is revoked sooner, a 401 downstream will force a re-mint (below).
  cached = {
    token: data.access_token,
    instanceUrl: (data.instance_url || SF_LOGIN_URL).replace(/\/$/, ''),
    expiresAt: now + 115 * 60 * 1000,
  };
  return cached;
}

// ── Forward one API call to Salesforce, retrying once on a stale-token 401 ──────
async function forward(method, sfPath, query, bodyObj) {
  let auth = await getToken();

  const doCall = async () => {
    const url = auth.instanceUrl + SF_APEXREST_PATH + sfPath + (query || '');
    return fetch(url, {
      method,
      headers: {
        Authorization: 'Bearer ' + auth.token,
        'Content-Type': 'application/json',
      },
      body: bodyObj ? JSON.stringify(bodyObj) : undefined,
    });
  };

  let sfRes = await doCall();
  if (sfRes.status === 401) {
    // Token likely expired/revoked before our TTL — drop the cache and mint a fresh one once.
    cached = { token: null, instanceUrl: null, expiresAt: 0 };
    auth = await getToken();
    sfRes = await doCall();
  }
  return sfRes;
}

// ── Tiny helpers ───────────────────────────────────────────────────────────────
function sendJson(res, status, obj) {
  const payload = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 1e6) req.destroy(); // hard cap; the API itself rejects >8000 chars
    });
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch (_) {
        resolve(null); // signal malformed JSON
      }
    });
  });
}

async function pipeToClient(res, sfRes) {
  const text = await sfRes.text();
  res.writeHead(sfRes.status, {
    'Content-Type': sfRes.headers.get('content-type') || 'application/json',
  });
  res.end(text);
}

// ── Static file serving for the widget (same origin as the API) ────────────────
const WIDGET_DIR = path.join(__dirname, '..');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

function serveStatic(req, res, pathname) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const filePath = path.join(WIDGET_DIR, rel);
  // Contain traversal to the widget directory.
  if (!filePath.startsWith(WIDGET_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }
  fs.readFile(filePath, (err, buf) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
    });
    res.end(buf);
  });
}

// ── Router ─────────────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, 'http://localhost');
  const pathname = parsed.pathname;

  try {
    // GET /agent/config  ->  Salesforce GET /agent/config
    if (req.method === 'GET' && pathname === '/agent/config') {
      const sfRes = await forward('GET', '/config');
      return pipeToClient(res, sfRes);
    }

    // GET /agent/session/{id}?externalRef=...
    if (req.method === 'GET' && pathname.startsWith('/agent/session/')) {
      const id = pathname.slice('/agent/session/'.length);
      const ref = parsed.searchParams.get('externalRef') || '';
      const query = '?externalRef=' + encodeURIComponent(ref);
      const sfRes = await forward('GET', '/session/' + encodeURIComponent(id), query);
      return pipeToClient(res, sfRes);
    }

    // POST /agent/message  {message, externalRef, sessionId?}
    if (req.method === 'POST' && pathname === '/agent/message') {
      const body = await readBody(req);
      if (body === null) {
        return sendJson(res, 400, { error: 'Invalid JSON body' });
      }
      const sfRes = await forward('POST', '/message', '', body);
      return pipeToClient(res, sfRes);
    }

    // Anything else: serve the widget's static files.
    if (req.method === 'GET') {
      return serveStatic(req, res, pathname);
    }

    sendJson(res, 404, { error: 'Not found' });
  } catch (e) {
    // e.cause carries the underlying reason for fetch failures (DNS, TLS, ECONNREFUSED),
    // which is otherwise hidden behind a bare "fetch failed".
    const detail = e.cause ? e.message + ' (' + (e.cause.message || e.cause) + ')' : e.message;
    console.error('[proxy]', detail);
    // Customer-facing shape stays generic; set DEBUG=1 to echo the detail to the browser
    // while you're troubleshooting.
    const payload = { error: 'Upstream request failed' };
    if (process.env.DEBUG) payload.detail = detail;
    sendJson(res, 502, payload);
  }
});

server.listen(PORT, () => {
  console.log('External chatbot proxy listening on http://localhost:' + PORT);
  console.log('Forwarding /agent/* -> ' + SF_LOGIN_URL + SF_APEXREST_PATH);
  console.log('Open http://localhost:' + PORT + ' and set the widget base URL to "/agent".');
});
