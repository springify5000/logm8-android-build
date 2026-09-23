// Xcode automatic signing can only create the (development) provisioning profile it needs for
// `xcodebuild archive` when the team has at least one registered iOS device. TestFlight/App Store
// builds are re-signed at export with the cloud-managed distribution profile, so any device will do.
// This registers a placeholder device through the App Store Connect API when the team has none.
//
// Env: ASC_KEY_PATH (AuthKey .p8), ASC_KEY_ID, ASC_ISSUER_ID, optional DEVICE_UDID / DEVICE_NAME
import crypto from 'node:crypto';
import fs from 'node:fs';

const keyPath = process.env.ASC_KEY_PATH;
const kid = process.env.ASC_KEY_ID;
const iss = process.env.ASC_ISSUER_ID;
if (!keyPath || !kid || !iss) { console.log('   (no API key -> skipping device check)'); process.exit(0); }

const b64u = (s) => Buffer.from(s).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const header = b64u(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' }));
const payload = b64u(JSON.stringify({ iss, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }));
const signature = crypto.sign('sha256', Buffer.from(`${header}.${payload}`),
  { key: fs.readFileSync(keyPath, 'utf8'), dsaEncoding: 'ieee-p1363' }).toString('base64url');
const token = `${header}.${payload}.${signature}`;

async function api(method, path, body) {
  const res = await fetch('https://api.appstoreconnect.apple.com' + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} -> HTTP ${res.status} ${JSON.stringify(json).slice(0, 600)}`);
  return json;
}

const list = await api('GET', '/v1/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=5');
if (list.data.length) {
  console.log(`   registered iOS devices: ${list.data.map((d) => d.attributes.name).join(', ')}`);
} else {
  const udid = process.env.DEVICE_UDID || '00008130-000C0DE0C0DE0000';
  const name = process.env.DEVICE_NAME || 'LogM8 CI placeholder';
  const created = await api('POST', '/v1/devices', { data: { type: 'devices', attributes: { name, platform: 'IOS', udid } } });
  console.log(`   no iOS device was registered -> added "${name}" (${created.data.id}) so Xcode can create a development profile`);
}
