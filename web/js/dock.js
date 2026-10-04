// Where the toolbar can sit, and which spot a drop lands on. Pure functions, tested by web/tests/dock.test.mjs.

export const DOCKS = ['top-left', 'top-center', 'top-right', 'left', 'right', 'bottom-left', 'bottom-center', 'bottom-right'];
export const DEFAULT_DOCK = 'bottom-center';

// Anchor of each dock as a fraction of the viewport.
const ANCHOR = {
  'top-left': [0, 0], 'top-center': [0.5, 0], 'top-right': [1, 0],
  left: [0, 0.5], right: [1, 0.5],
  'bottom-left': [0, 1], 'bottom-center': [0.5, 1], 'bottom-right': [1, 1],
};

export const LABELS = {
  'top-left': 'Top left', 'top-center': 'Top', 'top-right': 'Top right',
  left: 'Left side', right: 'Right side',
  'bottom-left': 'Bottom left', 'bottom-center': 'Bottom', 'bottom-right': 'Bottom right',
};

export const isVertical = (dock) => dock === 'left' || dock === 'right';
export const normalizeDock = (dock) => (DOCKS.includes(dock) ? dock : DEFAULT_DOCK);

// The dock whose anchor is closest to the drop point (x, y) in a w × h viewport.
// Distances are measured in viewport fractions, so a tall phone and a wide monitor behave the same.
export function nearestDock(x, y, w, h) {
  const fx = Math.min(1, Math.max(0, x / w));
  const fy = Math.min(1, Math.max(0, y / h));
  let best = DEFAULT_DOCK;
  let bestD = Infinity;
  for (const dock of DOCKS) {
    const [ax, ay] = ANCHOR[dock];
    const d = (fx - ax) ** 2 + (fy - ay) ** 2;
    if (d < bestD) { bestD = d; best = dock; }
  }
  return best;
}

// The order buttons fold into More when space runs out: highest data-prio first; 0 never folds.
export function foldOrder(items) {
  return items.filter((el) => Number(el.dataset.prio) > 0).sort((a, b) => Number(b.dataset.prio) - Number(a.dataset.prio));
}
