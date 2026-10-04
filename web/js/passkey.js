// Optional second lock: Face ID / Touch ID passkey (WebAuthn) before the screen is shown.
const b64u = {
  enc: (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
  dec: (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0)),
};

async function post(path, body) {
  const r = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body ?? {}) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || `Request failed (${r.status})`);
  return data;
}

export async function passkeyStatus() {
  try {
    const r = await fetch('auth/status', { cache: 'no-store' });
    const data = await r.json().catch(() => ({}));
    if (r.status === 503 && data.paused) return { ok: false, paused: true, msg: data.msg };
    return data;
  } catch { return { ok: true }; }
}

export async function registerPasskey(device) {
  const o = await post('auth/register/options');
  const cred = await navigator.credentials.create({
    publicKey: {
      challenge: b64u.dec(o.challenge),
      rp: { name: 'Tether', id: o.rpId },
      user: { id: b64u.dec(o.userId), name: o.name, displayName: `${o.name} (Tether)` },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { userVerification: 'required', residentKey: 'preferred' },
      excludeCredentials: (o.exclude || []).map((id) => ({ type: 'public-key', id: b64u.dec(id) })),
      attestation: 'none',
      timeout: 60000,
    },
  });
  if (cred.response.getPublicKeyAlgorithm?.() !== -7) throw new Error('This device made an unsupported passkey type.');
  await post('auth/register', {
    id: cred.id,
    publicKey: b64u.enc(cred.response.getPublicKey()),
    clientDataJSON: b64u.enc(cred.response.clientDataJSON),
    device,
  });
}

export async function unlockWithPasskey() {
  const o = await post('auth/options');
  const a = await navigator.credentials.get({
    publicKey: {
      challenge: b64u.dec(o.challenge),
      rpId: o.rpId,
      allowCredentials: (o.allow || []).map((id) => ({ type: 'public-key', id: b64u.dec(id) })),
      userVerification: 'required',
      timeout: 60000,
    },
  });
  await post('auth/verify', {
    id: a.id,
    clientDataJSON: b64u.enc(a.response.clientDataJSON),
    authenticatorData: b64u.enc(a.response.authenticatorData),
    signature: b64u.enc(a.response.signature),
  });
}
