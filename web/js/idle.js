// When to stop streaming to save power: after a stretch with no interaction, or once the page
// has been in the background for a minute. Pure functions, tested by web/tests/idle.test.mjs.

export const HIDDEN_PAUSE_MS = 60_000;
export const DEFAULT_IDLE_MINUTES = 15;

/** The idle limit in minutes: ?idle=<minutes> on the URL (a testing aid) wins over the saved choice. 0 = never. */
export function idleMinutes(search, saved) {
  const raw = new URLSearchParams(search).get('idle');
  const v = raw !== null ? Number(raw) : saved;
  return Number.isFinite(v) && v >= 0 ? v : DEFAULT_IDLE_MINUTES;
}

/** Idle pause: no interaction for `minutes`. Never while sound plays or in view-only mode (watching is the point). */
export function shouldIdlePause({ now, lastActive, minutes, audioOn = false, viewOnly = false, visible = true }) {
  if (!minutes || minutes <= 0 || audioOn || viewOnly || !visible) return false;
  return now - lastActive >= minutes * 60_000;
}

/** Background pause: hidden for a minute, unless sound is playing. */
export function shouldHiddenPause({ now, hiddenSince, audioOn = false }) {
  return hiddenSince != null && !audioOn && now - hiddenSince >= HIDDEN_PAUSE_MS;
}
