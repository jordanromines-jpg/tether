// Why can't this page reach its Mac? Pure functions: the page does the network checks and passes
// the results in, so every case is testable (web/tests/diagnose.test.mjs).

/**
 * What a healthz request said. Pass what happened:
 *   { threw: true }                      network error or timeout: Tailscale can't reach the Mac
 *   { status: 502, json: null }          Tailscale reached the Mac, but Tether isn't answering
 *   { status: 200, json: {...} }         Tether's own answer
 */
export function healthKind({ threw = false, status = 0, json = null } = {}) {
  if (threw) return 'unreachable';
  if (status !== 200 || !json || typeof json.ok !== 'boolean') return 'notRunning';
  if (json.paused) return 'paused';
  if (json.perms && (json.perms.screen === false || json.perms.input === false)) return 'permissions';
  return 'ok';
}

/** "2:55 PM" today, "Tue 2:55 PM" this week, otherwise a date. */
export function seenText(iso, now = new Date()) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const days = (now - d) / 86_400_000;
  if (d.toDateString() === now.toDateString()) return time;
  if (days < 6) return `${d.toLocaleDateString([], { weekday: 'short' })} ${time}`;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

/**
 * The reason to show, from:
 *   online   this device thinks it has a network (navigator.onLine)
 *   health   healthKind() of this Mac
 *   peer     what another of your Macs' Tether says about this one: { by, online, lastSeen } or null
 *   mac      this Mac's name; device: this device's kind, as in "this iPhone"
 */
export function diagnose({ online, health, peer = null, mac = 'your Mac', device = 'device', now = new Date() }) {
  const here = `this ${device}`;
  const Mac = mac.replace(/^your /, 'Your ');   // the name when a sentence starts with it
  const checks = [
    { ok: online, label: `This ${device} is online`, fix: `Connect ${here} to Wi-Fi or mobile data.` },
    { ok: online && health !== 'unreachable', label: `Tailscale can reach ${mac}`,
      fix: peer && peer.online === false
        ? `${Mac} is off the tailnet${peer.lastSeen ? ` since ${seenText(peer.lastSeen, now)}` : ''}. Wake it, or check it's on and connected to the internet.`
        : `Open Tailscale on ${here} and on ${mac}, and check both say Connected.` },
    { ok: ['ok', 'paused', 'permissions'].includes(health), label: `Tether is running on ${mac}`,
      fix: `Open Tether on ${mac} (Applications or Spotlight). This page connects as soon as it starts.` },
    { ok: ['ok', 'permissions'].includes(health), label: 'Remote access is on', fix: `Resume it from the Tether icon in ${mac}'s menu bar.` },
    { ok: health === 'ok', label: 'Tether is allowed to see and control the screen',
      fix: `On ${mac}: System Settings → Privacy & Security → Screen Recording and Accessibility, turn on Tether.` },
  ];
  // Only the first failure is known for sure; the checks after it can't run until it's fixed.
  const firstFail = checks.findIndex((c) => !c.ok);
  checks.forEach((c, i) => { c.state = c.ok ? 'ok' : i === firstFail ? 'fail' : 'unknown'; });
  let reason;
  if (!online) reason = { kind: 'deviceOffline', title: `This ${device} is offline`, detail: 'Connect to Wi-Fi or mobile data. This page reconnects by itself.' };
  else if (health === 'unreachable' && peer?.online === false) {
    const when = peer.lastSeen ? ` at ${seenText(peer.lastSeen, now)}` : '';
    reason = { kind: 'macOffline', title: `${Mac} is offline`,
      detail: `Tailscale last saw it${when}${peer.by ? ` (says ${peer.by})` : ''}. It may be asleep, shut down or off the network.` };
  } else if (health === 'unreachable') {
    reason = { kind: 'unreachable', title: `Can't reach ${mac}`, detail: `Check that Tailscale is on, on ${here} and on ${mac}. This page keeps trying.` };
  } else if (health === 'notRunning') {
    reason = { kind: 'notRunning', title: `${Mac} is on, but Tether isn't running`, detail: 'Open Tether on it. This page connects as soon as it starts.' };
  } else if (health === 'paused') {
    reason = { kind: 'paused', title: 'Paused on the Mac', detail: 'Resume it from the Tether icon in the Mac\'s menu bar. This page reconnects on its own.' };
  } else if (health === 'permissions') {
    reason = { kind: 'permissions', title: `${Mac} needs a permission`, detail: 'Allow Tether in Privacy & Security: Screen Recording and Accessibility.' };
  } else {
    reason = { kind: 'ok', title: `Connecting to ${mac}`, detail: '' };
  }
  return { reason, checks };
}

/** How long to wait before checking again while the Mac can't be reached: 2 s, growing to 10 s. */
export const pollDelay = (attempt) => Math.min(10_000, 2000 + attempt * 2000);


// Waking a sleeping Mac (Wake-on-LAN): another Mac that's online and on the same network sends
// the magic packet. `wake` maps each Mac's URL to what its /healthz reported: { mac, net }.

/** The URL of a Mac that can wake `target`, or null. `candidates`: [{ url, online }]. */
export function pickWaker(target, candidates, wake) {
  const t = wake?.[target];
  if (!t?.mac || !t.net) return null;
  const helper = candidates.find((c) => c.url !== target && c.online && wake[c.url]?.net === t.net);
  return helper?.url ?? null;
}

/**
 * Keeps what /healthz said about a Mac's network. `mac` is missing on a Mac that can't be woken (a
 * randomized Wi-Fi address) but that Mac can still wake others on its network.
 */
export function rememberWake(wake, url, info) {
  const next = { ...(wake || {}) };
  if (info?.net) next[url] = info.mac ? { mac: info.mac, net: info.net } : { net: info.net };
  return next;
}
