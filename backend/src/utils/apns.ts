import http2 from 'http2';
import fs from 'fs';
import jwt from 'jsonwebtoken';

// Apple invalidates a provider token if you mint a new one on every request (rate-limited),
// but also caps how long one stays valid — an hour is the documented ceiling, so refreshing a
// bit before that keeps every request comfortably inside the window.
const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

let cachedToken: { token: string; mintedAt: number } | null = null;
let cachedKey: string | null | undefined; // undefined = not yet read, null = read but missing

function loadPrivateKey(): string | null {
  if (cachedKey !== undefined) return cachedKey;
  const keyPath = process.env.APNS_KEY_PATH;
  try {
    cachedKey = keyPath ? fs.readFileSync(keyPath, 'utf8') : null;
  } catch {
    cachedKey = null;
  }
  return cachedKey;
}

function getProviderToken(): string | null {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const privateKey = loadPrivateKey();
  if (!keyId || !teamId || !privateKey) return null;

  if (cachedToken && Date.now() - cachedToken.mintedAt < TOKEN_LIFETIME_MS) {
    return cachedToken.token;
  }

  const token = jwt.sign({ iss: teamId, iat: Math.floor(Date.now() / 1000) }, privateKey, {
    algorithm: 'ES256',
    keyid: keyId,
  });
  cachedToken = { token, mintedAt: Date.now() };
  return token;
}

export type PushResult =
  | { ok: true }
  | { ok: false; reason: 'not-configured' | 'invalid-token' | 'error' };

/// Sends a single alert push via Apple's HTTP/2 provider API — no `node-apn`/third-party
/// dependency, since jsonwebtoken (already a dependency, for the app's own auth tokens) covers
/// the ES256 signing this needs and the request itself is a handful of lines over Node's
/// built-in http2 module.
///
/// Silently no-ops (returns `{ok: false, reason: 'not-configured'}`) when APNS_KEY_ID/
/// APNS_TEAM_ID/the key file aren't set up — see the setup comment in .env. Real push simply
/// doesn't fire until those are in place; nothing else in the app depends on this succeeding.
export async function sendPushNotification(
  deviceToken: string,
  { title, body, data }: { title: string; body: string; data?: Record<string, unknown> }
): Promise<PushResult> {
  const providerToken = getProviderToken();
  if (!providerToken) return { ok: false, reason: 'not-configured' };

  const topic = process.env.APPLE_BUNDLE_ID || 'com.lumenfem.dating';
  const host =
    process.env.APNS_PRODUCTION === 'true'
      ? 'https://api.push.apple.com'
      : 'https://api.sandbox.push.apple.com';

  const payload = JSON.stringify({
    aps: { alert: { title, body }, sound: 'default' },
    ...data,
  });

  return new Promise((resolve) => {
    const client = http2.connect(host);
    client.on('error', () => resolve({ ok: false, reason: 'error' }));

    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${providerToken}`,
      'apns-topic': topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'content-type': 'application/json',
    });

    let responseBody = '';
    let status = 0;
    req.on('response', (headers) => {
      status = Number(headers[':status']);
    });
    req.on('data', (chunk) => {
      responseBody += chunk;
    });
    req.on('end', () => {
      client.close();
      if (status === 200) {
        resolve({ ok: true });
        return;
      }
      // 400 BadDeviceToken / 410 Unregistered both mean this token is permanently dead — the
      // caller should stop trying to push to it (clear User.pushToken) rather than retry.
      const reason =
        status === 400 || status === 410
          ? /BadDeviceToken|Unregistered/.test(responseBody)
            ? 'invalid-token'
            : 'error'
          : 'error';
      resolve({ ok: false, reason });
    });
    req.on('error', () => resolve({ ok: false, reason: 'error' }));
    req.end(payload);
  });
}
