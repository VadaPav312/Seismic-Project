import test from 'node:test';
import assert from 'node:assert/strict';
import {
  polygonFor, parseShape, polygonArea, boundingBox, allShapes, isIrregular,
} from '../www/js/core/planshape.js';

test('every shape encloses the area it was asked for', () => {
  for (const shape of allShapes()) {
    for (const requested of [50, 400, 2500, 18_000]) {
      const measured = polygonArea(polygonFor(shape, requested));
      // 2% covers the circle's polygonal approximation; the rest are exact.
      assert.ok(Math.abs(measured - requested) < requested * 0.02,
        `${shape} at ${requested} enclosed ${measured.toFixed(0)}`);
    }
  }
});

test('every shape is a closed ring with no zero-length edges', () => {
  for (const shape of allShapes()) {
    const ring = polygonFor(shape, 900);
    assert.ok(ring.length >= 4, `${shape} is not a polygon`);
    assert.deepEqual(ring[0], ring[ring.length - 1], `${shape} is not closed`);
    const interior = ring.slice(0, -1);
    for (let i = 0; i < interior.length; i += 1) {
      const [x1, y1] = interior[i];
      const [x2, y2] = interior[(i + 1) % interior.length];
      assert.ok(Math.hypot(x1 - x2, y1 - y2) > 1e-6, `${shape} has a zero-length edge`);
    }
  }
});

test('irregular shapes genuinely differ from their bounding box', () => {
  for (const shape of allShapes().filter(isIrregular)) {
    const ring = polygonFor(shape, 1000);
    const box = boundingBox(ring);
    assert.ok(polygonArea(ring) < box.width * box.depth * 0.95,
      `${shape} fills its bounding box — it is a rectangle`);
  }
});

test('aspect ratio stretches without changing the area', () => {
  const ring = polygonFor('rectangular', 1000, 4);
  const box = boundingBox(ring);
  assert.ok(Math.abs(box.width / box.depth - 4) < 0.01);
  assert.ok(Math.abs(polygonArea(ring) - 1000) < 1);
});

test('absurd input still yields a usable polygon', () => {
  for (const shape of allShapes()) {
    for (const area of [-100, 0, 0.0001, 1e9, NaN, undefined]) {
      const ring = polygonFor(shape, area, -5);
      assert.ok(ring.every(([x, y]) => Number.isFinite(x) && Number.isFinite(y)),
        `${shape} produced NaN at area ${area}`);
      assert.ok(polygonArea(ring) > 0, `${shape} collapsed at area ${area}`);
    }
  }
});

test('parsing prefers the more specific description', () => {
  assert.equal(parseShape('a cruciform plan with four wings'), 'cruciform');
  assert.equal(parseShape('L-shaped block'), 'lShaped');
  assert.equal(parseShape('Roughly rectangular slab'), 'rectangular');
  assert.equal(parseShape('circular drum on a podium'), 'circular');
  assert.equal(parseShape('U-shaped around a courtyard'), 'uShaped');
  assert.equal(parseShape('stepped setback tower'), 'setbackTower');
  // "rectangular" must not match "circular" by substring.
  assert.equal(parseShape('rectangular'), 'rectangular');
});

test('unrecognised descriptions return null rather than guessing', () => {
  for (const text of ['', '   ', 'a very tall building', 'brutalist', null, undefined]) {
    assert.equal(parseShape(text), null, `${JSON.stringify(text)} should not match`);
  }
});
