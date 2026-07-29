// Plan shapes: turning a description of a building's outline into a polygon.
//
// For buildings OpenStreetMap has traced, the real outline is used and this is
// never consulted. For the rest, the alternative is a rectangle — which makes
// every unmapped building look identical and quietly asserts a symmetry most
// buildings do not have.
//
// The shape is not decoration. Plan irregularity is among the strongest
// predictors of earthquake damage there is: re-entrant corners concentrate
// stress, and mass placed away from the centre of rigidity twists a building
// rather than simply pushing it.

const SHAPES = {
  rectangular: { label: 'Rectangular', irregular: false },
  square: { label: 'Square', irregular: false },
  lShaped: { label: 'L-shaped', irregular: true },
  tShaped: { label: 'T-shaped', irregular: true },
  uShaped: { label: 'U-shaped', irregular: true },
  cruciform: { label: 'Cruciform', irregular: true },
  circular: { label: 'Circular', irregular: false },
  octagonal: { label: 'Octagonal', irregular: false },
  triangular: { label: 'Triangular', irregular: true },
  setbackTower: { label: 'Setback tower', irregular: false },
};

export function shapeLabel(shape) { return SHAPES[shape]?.label ?? 'Rectangular'; }
export function isIrregular(shape) { return SHAPES[shape]?.irregular ?? false; }
export function allShapes() { return Object.keys(SHAPES); }

/**
 * A closed polygon in local metres, centred on the origin, enclosing
 * approximately `area` square metres.
 *
 * Every shape is normalised to the requested area. That is deliberate: if the
 * shape choice also changed the floor area it would change the building's mass
 * and therefore its period, and the app would report a period shift that came
 * from a menu selection rather than from the building.
 */
export function polygonFor(shape, area, aspectRatio = 1.6) {
  const a = Math.max(Number.isFinite(area) ? area : 0, 10);
  const ratio = Math.min(Math.max(Number.isFinite(aspectRatio) ? aspectRatio : 1.6, 1), 6);

  switch (shape) {
    case 'square':
      return rectangle(Math.sqrt(a), Math.sqrt(a));

    case 'circular':
      return regular(32, a);

    case 'octagonal':
      return regular(8, a);

    case 'triangular':
      return regular(3, a);

    case 'lShaped': {
      // A square with a quarter removed leaves three quarters.
      const side = Math.sqrt(a / 0.75);
      const h = side / 2;
      const notch = side / 2;
      return close([
        [-h, -h], [h, -h], [h, -h + notch],
        [-h + notch, -h + notch], [-h + notch, h], [-h, h],
      ]);
    }

    case 'tShaped': {
      // Bar a quarter of the side deep, stem half of it wide: 0.625.
      const side = Math.sqrt(a / 0.625);
      const h = side / 2;
      const stem = side * 0.25;
      const bar = side * 0.25;
      return close([
        [-stem, -h], [stem, -h], [stem, h - bar],
        [h, h - bar], [h, h], [-h, h],
        [-h, h - bar], [-stem, h - bar],
      ]);
    }

    case 'uShaped': {
      // Base half the side deep, two arms a quarter wide: 0.75.
      const side = Math.sqrt(a / 0.75);
      const h = side / 2;
      const arm = side * 0.25;
      const base = side * 0.5;
      return close([
        [-h, -h], [h, -h], [h, h],
        [h - arm, h], [h - arm, -h + base],
        [-h + arm, -h + base], [-h + arm, h], [-h, h],
      ]);
    }

    case 'cruciform': {
      // A plus sign fills five ninths of its bounding square.
      const side = Math.sqrt(a / (5 / 9));
      const h = side / 2;
      const arm = side / 6;
      return close([
        [-arm, -h], [arm, -h], [arm, -arm], [h, -arm], [h, arm],
        [arm, arm], [arm, h], [-arm, h], [-arm, arm], [-h, arm],
        [-h, -arm], [-arm, -arm],
      ]);
    }

    case 'rectangular':
    case 'setbackTower':
    default: {
      const depth = Math.sqrt(a / ratio);
      return rectangle(depth * ratio, depth);
    }
  }
}

/**
 * Maps free text onto a shape.
 *
 * Deliberately conservative: anything unrecognised returns null rather than a
 * guess, so an unclear description falls back to the honest rectangle instead
 * of inventing a cruciform hospital.
 */
export function parseShape(raw) {
  const text = String(raw ?? '').toLowerCase().trim();
  if (!text) return null;
  if (SHAPES[text]) return text;

  // Most specific first: "cruciform" before "cross", and nothing containing
  // "rectangular" may match "circular".
  const patterns = [
    [['cruciform', 'cross-shaped', 'cross shaped', 'plus-shaped'], 'cruciform'],
    [['l-shaped', 'l shaped', 'ell-shaped'], 'lShaped'],
    [['t-shaped', 't shaped'], 'tShaped'],
    [['u-shaped', 'u shaped', 'courtyard', 'horseshoe'], 'uShaped'],
    [['circular', 'cylindrical', 'round tower', 'rotunda', 'drum'], 'circular'],
    [['octagon'], 'octagonal'],
    [['triangul', 'wedge', 'flatiron'], 'triangular'],
    [['setback', 'stepped', 'ziggurat', 'taper'], 'setbackTower'],
    [['square'], 'square'],
    [['rectangul', 'rectilinear', 'slab', 'oblong'], 'rectangular'],
  ];
  for (const [needles, shape] of patterns) {
    if (needles.some((n) => text.includes(n))) return shape;
  }
  return null;
}

/** Shoelace area of a ring, for verifying a polygon is what it claims. */
export function polygonArea(ring) {
  const points = closedRingWithoutDuplicate(ring);
  if (points.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < points.length; i += 1) {
    const [x1, y1] = points[i];
    const [x2, y2] = points[(i + 1) % points.length];
    sum += x1 * y2 - x2 * y1;
  }
  return Math.abs(sum) / 2;
}

export function boundingBox(ring) {
  if (!ring?.length) return { minX: 0, minY: 0, maxX: 0, maxY: 0, width: 0, depth: 0 };
  let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
  for (const [x, y] of ring) {
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return { minX, minY, maxX, maxY, width: maxX - minX, depth: maxY - minY };
}

function closedRingWithoutDuplicate(ring) {
  const points = (ring ?? []).slice();
  if (points.length > 1) {
    const [fx, fy] = points[0];
    const [lx, ly] = points[points.length - 1];
    if (Math.abs(fx - lx) < 1e-9 && Math.abs(fy - ly) < 1e-9) points.pop();
  }
  return points;
}

function rectangle(width, depth) {
  const w = width / 2;
  const d = depth / 2;
  return close([[-w, -d], [w, -d], [w, d], [-w, d]]);
}

/**
 * A regular polygon of `sides` enclosing `area`.
 *
 * The circumradius is solved from the area rather than assumed, so a circular
 * drum and a rectangular slab of the same stated floor area come out genuinely
 * the same size.
 */
function regular(sides, area) {
  const n = Math.max(sides, 3);
  const radius = Math.sqrt((2 * area) / (n * Math.sin((2 * Math.PI) / n)));
  const points = [];
  for (let i = 0; i < n; i += 1) {
    const angle = (2 * Math.PI * i) / n - Math.PI / 2;
    points.push([radius * Math.cos(angle), radius * Math.sin(angle)]);
  }
  return close(points);
}

function close(points) {
  const ring = points.map(([x, y]) => [x, y]);
  ring.push([ring[0][0], ring[0][1]]);
  return ring;
}
