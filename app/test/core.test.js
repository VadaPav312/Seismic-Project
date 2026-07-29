import test from 'node:test';
import assert from 'node:assert/strict';

import {
  factorise, solveFactorised, solve as solveLinear, symmetricEigen,
} from '../www/js/core/linalg.js';
import {
  Waveform, TriaxialRecord, detrend, removeMean, butterworth, integrate, fft,
} from '../www/js/core/signal.js';
import {
  welch, konnoOhmachi, peaks, crossCheckedPeriod, responseSpectrum, energy, staLta,
} from '../www/js/core/spectrum.js';
import {
  ShearBuilding, modes, fundamentalPeriod, solve, fragility, damageState,
  empiricalPeriod, resonanceSweep,
} from '../www/js/core/structures.js';

// ─── Linear algebra ─────────────────────────────────────────────────────────

test('LU solves a system the answer to which is known', () => {
  const a = [[4, 1, 0], [1, 4, 1], [0, 1, 4]];
  const expected = [1, -2, 3];
  const b = a.map((row) => row.reduce((s, v, j) => s + v * expected[j], 0));
  const x = solveLinear(a, b);
  for (let i = 0; i < 3; i += 1) assert.ok(Math.abs(x[i] - expected[i]) < 1e-10);
});

test('a singular matrix returns null rather than infinities', () => {
  assert.equal(factorise([[1, 2], [2, 4]]), null);
  assert.equal(solveLinear([[0, 0], [0, 0]], [1, 1]), null);
});

test('one factorisation serves many right-hand sides', () => {
  const a = [[3, 1], [1, 2]];
  const f = factorise(a);
  for (const rhs of [[5, 5], [1, 0], [-2, 7]]) {
    const x = solveFactorised(f, rhs);
    for (let i = 0; i < 2; i += 1) {
      const got = a[i].reduce((s, v, j) => s + v * x[j], 0);
      assert.ok(Math.abs(got - rhs[i]) < 1e-10);
    }
  }
});

test('eigenvalues of a known symmetric matrix', () => {
  // [[2,1],[1,2]] has eigenvalues 1 and 3.
  const { values } = symmetricEigen([[2, 1], [1, 2]]);
  assert.ok(Math.abs(values[0] - 1) < 1e-9);
  assert.ok(Math.abs(values[1] - 3) < 1e-9);
});

test('eigenvectors are orthonormal and satisfy A v = lambda v', () => {
  const a = [[6, 2, 1], [2, 5, 1], [1, 1, 4]];
  const { values, vectors } = symmetricEigen(a);
  for (let k = 0; k < 3; k += 1) {
    const v = vectors[k];
    for (let i = 0; i < 3; i += 1) {
      const av = a[i].reduce((s, x, j) => s + x * v[j], 0);
      assert.ok(Math.abs(av - values[k] * v[i]) < 1e-8, `mode ${k} row ${i}`);
    }
  }
});

// ─── Signal ─────────────────────────────────────────────────────────────────

test('detrending removes a straight line exactly', () => {
  const n = 200;
  const samples = Float64Array.from({ length: n }, (_, i) => 3 + 0.5 * i);
  const out = detrend(new Waveform(samples, 100));
  for (const value of out.samples) assert.ok(Math.abs(value) < 1e-8);
});

test('integrating silence produces silence, not drift', () => {
  const { velocity, displacement } = integrate(Waveform.zeros(1000, 100));
  assert.ok(velocity.peak < 1e-12);
  assert.ok(displacement.peak < 1e-12);
});

test('the FFT of a pure tone puts its energy in the right bin', () => {
  const n = 256;
  const rate = 128;
  const frequency = 8;
  const real = new Float64Array(n);
  const imaginary = new Float64Array(n);
  for (let i = 0; i < n; i += 1) real[i] = Math.sin((2 * Math.PI * frequency * i) / rate);

  fft(real, imaginary);

  let peakBin = 0;
  let peakValue = 0;
  for (let bin = 1; bin < n / 2; bin += 1) {
    const magnitude = Math.hypot(real[bin], imaginary[bin]);
    if (magnitude > peakValue) { peakValue = magnitude; peakBin = bin; }
  }
  assert.equal((peakBin * rate) / n, frequency);
});

test('the FFT refuses a non-power-of-two length rather than returning nonsense', () => {
  assert.throws(() => fft(new Float64Array(100), new Float64Array(100)));
});

test('a bandpass filter keeps what is inside the band and removes what is not', () => {
  const rate = 200;
  const n = 4096;
  const inBand = new Float64Array(n);
  const outOfBand = new Float64Array(n);
  for (let i = 0; i < n; i += 1) {
    inBand[i] = Math.sin((2 * Math.PI * 5 * i) / rate);
    outOfBand[i] = Math.sin((2 * Math.PI * 80 * i) / rate);
  }
  const kept = butterworth(new Waveform(inBand, rate), { lowCutoff: 1, highCutoff: 20 });
  const removed = butterworth(new Waveform(outOfBand, rate), { lowCutoff: 1, highCutoff: 20 });

  assert.ok(kept.rms > 0.6, `in-band rms ${kept.rms}`);
  assert.ok(removed.rms < 0.05, `out-of-band rms ${removed.rms}`);
});

// ─── Spectrum ───────────────────────────────────────────────────────────────

test('Welch finds the frequency of a known sinusoid', () => {
  const rate = 100;
  const n = 4096;
  const frequency = 2.5;
  const samples = Float64Array.from({ length: n },
    (_, i) => Math.sin((2 * Math.PI * frequency * i) / rate));

  const found = peaks(konnoOhmachi(welch(new Waveform(samples, rate))))[0];
  assert.ok(found, 'no peak found');
  assert.ok(Math.abs(found.frequency - frequency) < 0.15,
    `found ${found.frequency}, expected ${frequency}`);
});

test('a stuck sensor does not read as a confident period', () => {
  const flat = new Waveform(new Float64Array(2000).fill(3.7), 100);
  assert.ok(crossCheckedPeriod(flat).agreement < 0.5);
});

test('one corroborating method cannot produce full confidence', () => {
  const rate = 100;
  const samples = Float64Array.from({ length: 2048 },
    (_, i) => Math.sin((2 * Math.PI * 1.5 * i) / rate));
  const check = crossCheckedPeriod(new Waveform(samples, rate));
  assert.ok(check.agreement <= 1);
  if (check.estimates.length === 1) assert.ok(check.agreement <= 0.35);
});

test('the response spectrum peaks near the oscillator it resonates', () => {
  const rate = 100;
  const n = 3000;
  const drivePeriod = 0.5;
  const samples = Float64Array.from({ length: n },
    (_, i) => Math.sin((2 * Math.PI * (1 / drivePeriod) * i) / rate));

  const { periods, sa } = responseSpectrum(new Waveform(samples, rate));
  let peakIndex = 0;
  for (let i = 1; i < sa.length; i += 1) if (sa[i] > sa[peakIndex]) peakIndex = i;
  assert.ok(Math.abs(periods[peakIndex] - drivePeriod) < 0.12,
    `peak at ${periods[peakIndex]}, expected near ${drivePeriod}`);
});

test('Arias intensity is zero for silence and positive for shaking', () => {
  assert.equal(energy(Waveform.zeros(500, 100)).arias, 0);
  const shaking = Float64Array.from({ length: 500 }, () => Math.random() - 0.5);
  assert.ok(energy(new Waveform(shaking, 100)).arias > 0);
});

test('STA/LTA rises on a burst and stays flat on noise', () => {
  const rate = 100;
  const n = 3000;
  const quiet = Float64Array.from({ length: n }, () => (Math.random() - 0.5) * 0.001);
  const burst = Float64Array.from(quiet);
  for (let i = 2000; i < 2200; i += 1) burst[i] += (Math.random() - 0.5) * 2;

  assert.ok(staLta(new Waveform(quiet, rate)).peakRatio < 8);
  assert.ok(staLta(new Waveform(burst, rate)).peakRatio > 10);
});

// ─── Structures ─────────────────────────────────────────────────────────────

test('a single-storey oscillator has the period theory says it does', () => {
  // T = 2 pi sqrt(m / k)
  const mass = 400_000;
  const stiffness = 4e8;
  const expected = 2 * Math.PI * Math.sqrt(mass / stiffness);
  const building = new ShearBuilding([{ height: 3.4, mass, stiffness }], 0.05);

  assert.ok(Math.abs(fundamentalPeriod(building) - expected) < 1e-6);
  assert.ok(Math.abs(modes(building)[0].period - expected) < 1e-6);
});

test('inverse iteration agrees with the full eigendecomposition', () => {
  const storeys = Array.from({ length: 12 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const building = new ShearBuilding(storeys, 0.05);
  assert.ok(Math.abs(fundamentalPeriod(building) - modes(building)[0].period) < 1e-6);
});

test('a taller building of the same construction has a longer period', () => {
  const make = (n) => new ShearBuilding(
    Array.from({ length: n }, () => ({ height: 3.4, mass: 500_000, stiffness: 6e8 })), 0.05,
  );
  assert.ok(fundamentalPeriod(make(20)) > fundamentalPeriod(make(5)));
});

test('modes come out ordered, and the first carries the most mass', () => {
  const storeys = Array.from({ length: 8 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const list = modes(new ShearBuilding(storeys, 0.05));
  for (let i = 1; i < list.length; i += 1) {
    assert.ok(list[i].frequency >= list[i - 1].frequency);
  }
  for (let i = 1; i < list.length; i += 1) {
    assert.ok(list[0].massParticipationRatio >= list[i].massParticipationRatio);
  }
});

test('losing stiffness lengthens the period — the claim the app rests on', () => {
  const healthy = Array.from({ length: 8 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const damaged = healthy.map((s, i) => (i === 0 ? { ...s, stiffness: s.stiffness * 0.65 } : s));
  assert.ok(fundamentalPeriod(new ShearBuilding(damaged, 0.05))
          > fundamentalPeriod(new ShearBuilding(healthy, 0.05)));
});

test('strong shaking damages the model and reports a period shift', () => {
  const storeys = Array.from({ length: 6 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const building = new ShearBuilding(storeys, 0.05);

  const rate = 100;
  const n = 2000;
  const period = fundamentalPeriod(building);
  // Drive it at its own resonance, hard, which is the worst case by design.
  const samples = Float64Array.from({ length: n },
    (_, i) => 9 * Math.sin((2 * Math.PI * (1 / period) * i) / rate));

  const result = solve(building, new Waveform(samples, rate));
  assert.ok(result.maximumDrift > 0, 'nothing moved');
  assert.ok(result.finalPeriod >= result.initialPeriod, 'period should not shorten');
  assert.ok(result.storeyResults.some((s) => s.damaged), 'nothing was damaged by resonance');
  assert.ok(Number.isFinite(result.periodChangePercent));
});

test('gentle shaking leaves the building undamaged', () => {
  const storeys = Array.from({ length: 6 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const building = new ShearBuilding(storeys, 0.05);
  const samples = Float64Array.from({ length: 1000 }, (_, i) => 0.002 * Math.sin(i / 10));
  const result = solve(building, new Waveform(samples, 100));

  assert.ok(!result.storeyResults.some((s) => s.damaged));
  assert.ok(Math.abs(result.periodChangePercent) < 1e-6);
});

test('fragility probabilities stay within bounds and increase with demand', () => {
  for (const drift of [-1, 0, 1e-12, 0.001, 0.05, 1, 1e6, Infinity]) {
    const f = fragility(drift);
    for (const value of Object.values(f)) {
      assert.ok(Number.isFinite(value), `NaN at demand ${drift}`);
      assert.ok(value >= 0 && value <= 1, `${value} out of range at ${drift}`);
    }
    // Reaching a worse state is always at most as likely as a milder one.
    assert.ok(f.slight >= f.moderate);
    assert.ok(f.moderate >= f.extensive);
    assert.ok(f.extensive >= f.complete);
  }
  assert.ok(fragility(0.03).moderate > fragility(0.001).moderate);
});

test('damage states rise monotonically with drift', () => {
  let previous = -1;
  for (const drift of [0, 0.001, 0.005, 0.009, 0.03, 0.09]) {
    const state = damageState(drift);
    assert.ok(state >= previous);
    previous = state;
  }
});

test('the empirical period grows with height', () => {
  assert.ok(empiricalPeriod({ height: 100 }) > empiricalPeriod({ height: 20 }));
});

test('a resonance sweep peaks at the building\'s own frequency', () => {
  const storeys = Array.from({ length: 8 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const building = new ShearBuilding(storeys, 0.05);
  const natural = modes(building)[0].frequency;

  const sweep = resonanceSweep(building, { from: 0.05, to: natural * 3, points: 200 });
  const peak = sweep.reduce((best, p) => (p.amplification > best.amplification ? p : best));
  assert.ok(Math.abs(peak.frequency - natural) / natural < 0.1,
    `peak at ${peak.frequency}, natural ${natural}`);
});

// ─── Degenerate input ───────────────────────────────────────────────────────
//
// Every one of these is reachable in the running app: a node that has just
// connected has a handful of samples, a disconnected one has none, a stuck
// sensor produces a flat line, and a bad reading produces an infinity.

const degenerate = () => [
  ['empty', new Waveform([], 100)],
  ['one sample', new Waveform([0.5], 100)],
  ['two samples', new Waveform([0.1, -0.1], 100)],
  ['all zeros', Waveform.zeros(500, 100)],
  ['constant', new Waveform(new Float64Array(500).fill(3.7), 100)],
  ['one spike', new Waveform(Float64Array.from({ length: 500 }, (_, i) => (i === 250 ? 9 : 0)), 100)],
  ['huge', new Waveform(new Float64Array(300).fill(1e12), 100)],
  ['tiny', new Waveform(new Float64Array(300).fill(1e-18), 100)],
  ['zero rate', new Waveform([1, 2, 3], 0)],
  ['non-finite', new Waveform([0, 1, NaN, 2, Infinity, 3, ...new Array(500).fill(0.1)], 100)],
];

test('the spectral chain survives every degenerate input', () => {
  for (const [name, wave] of degenerate()) {
    const spectrum = konnoOhmachi(welch(wave));
    for (const value of spectrum.power) {
      assert.ok(Number.isFinite(value), `${name}: NaN in the spectrum`);
    }
    for (const peak of peaks(spectrum)) {
      assert.ok(Number.isFinite(peak.frequency), `${name}: NaN peak`);
    }
    const check = crossCheckedPeriod(wave);
    assert.ok(check.agreement >= 0 && check.agreement <= 1, `${name}: agreement out of range`);

    const e = energy(wave);
    assert.ok(Number.isFinite(e.arias), `${name}: NaN Arias`);
    assert.ok(e.significantDuration >= 0, `${name}: negative duration`);

    const trigger = staLta(wave);
    assert.ok(Number.isFinite(trigger.peakRatio), `${name}: NaN STA/LTA`);

    const { sa } = responseSpectrum(wave);
    for (const value of sa) assert.ok(Number.isFinite(value), `${name}: NaN Sa`);
  }
});

test('the solver survives degenerate buildings and degenerate motion', () => {
  const storey = (over = {}) => ({ height: 3.4, mass: 400_000, stiffness: 4e8, ...over });
  const buildings = [
    ['no storeys', new ShearBuilding([], 0.05)],
    ['one storey', new ShearBuilding([storey()], 0.05)],
    ['zero mass', new ShearBuilding([storey({ mass: 0 }), storey({ mass: 0 })], 0.05)],
    ['zero stiffness', new ShearBuilding([storey({ stiffness: 0 })], 0.05)],
    ['zero damping', new ShearBuilding([storey(), storey()], 0)],
    ['absurd damping', new ShearBuilding([storey(), storey()], 5)],
    ['hair-thin', new ShearBuilding([storey({ height: 1e-6 })], 0.05)],
    ['tall', new ShearBuilding(Array.from({ length: 40 }, () => storey()), 0.05)],
  ];

  for (const [buildingName, building] of buildings) {
    assert.ok(Number.isFinite(fundamentalPeriod(building)), `${buildingName}: NaN period`);
    for (const mode of modes(building)) {
      assert.ok(Number.isFinite(mode.period), `${buildingName}: NaN mode period`);
      assert.ok(mode.shape.every(Number.isFinite), `${buildingName}: NaN mode shape`);
    }

    for (const [motionName, motion] of degenerate()) {
      const result = solve(building, motion);
      const label = `${buildingName} / ${motionName}`;
      assert.ok(Number.isFinite(result.maximumDrift), `${label}: NaN drift`);
      assert.ok(Number.isFinite(result.initialPeriod), `${label}: NaN initial period`);
      assert.ok(Number.isFinite(result.finalPeriod), `${label}: NaN final period`);
      assert.ok(Number.isFinite(result.periodChangePercent), `${label}: NaN change`);
      for (const s of result.storeyResults) {
        assert.ok(Number.isFinite(s.peakDrift), `${label}: NaN storey drift`);
      }
    }
  }
});

test('a sixty-storey solve finishes quickly enough to be usable', () => {
  const storeys = Array.from({ length: 60 }, () => ({
    height: 3.4, mass: 500_000, stiffness: 6e8,
  }));
  const building = new ShearBuilding(storeys, 0.05);
  const samples = Float64Array.from({ length: 3000 }, (_, i) => Math.sin(i / 20) * 2);

  const started = process.hrtime.bigint();
  const result = solve(building, new Waveform(samples, 100));
  const seconds = Number(process.hrtime.bigint() - started) / 1e9;

  assert.ok(Number.isFinite(result.maximumDrift));
  // The reused factorisation is what makes this possible. Without it this test
  // does not finish.
  assert.ok(seconds < 20, `took ${seconds.toFixed(1)}s`);
});

test('TriaxialRecord slicing keeps the three axes in step', () => {
  const rate = 100;
  const make = () => new Waveform(Float64Array.from({ length: 1000 }, (_, i) => i), rate);
  const record = new TriaxialRecord(make(), make(), make());
  const window = record.slice(2, 5);
  assert.equal(window.x.count, window.y.count);
  assert.equal(window.y.count, window.z.count);
  assert.ok(Math.abs(window.duration - 3) < 0.02);
});

test('removeMean actually centres the signal', () => {
  const samples = Float64Array.from({ length: 100 }, (_, i) => 50 + i);
  assert.ok(Math.abs(removeMean(new Waveform(samples, 100)).mean) < 1e-10);
});

// ── The simulated node ──────────────────────────────────────────────────────
//
// These drive a stochastic simulation, so Math.random is replaced with a seeded
// generator for the duration. A test that passes four times in five is worse
// than no test: it trains you to re-run it rather than to read it.

function withSeededRandom(seed, body) {
  const original = Math.random;
  let state = seed >>> 0;
  Math.random = () => {
    // xorshift32 — small, fast, and good enough for excitation noise.
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 0x1_0000_0000;
  };
  try { return body(); } finally { Math.random = original; }
}

test('the simulated node produces a trace whose period is the building\'s own', async () => {
  const { SimulatedNode } = await import('../www/js/core/node.js');
  const node = new SimulatedNode({
    building: {
      storeyCount: 8, height: 27, footprintArea: 620,
      material: 'reinforcedConcrete', system: 'momentFrame',
    },
  });
  node.connect();

  // Sixty seconds of ambient motion, at the rate the app ticks it.
  const check = withSeededRandom(12345, () => {
    for (let i = 0; i < 60 * 20; i += 1) node.tick(1 / 20);
    return crossCheckedPeriod(node.record(60).x);
  });
  assert.ok(node.x.length > 5000, `only ${node.x.length} samples`);
  assert.ok(check.consensus, 'no period could be measured from ambient motion');
  // Within 25% of the building's own period. This is the app's central claim —
  // that a period can be recovered from ambient motion alone, with no
  // earthquake — so it is asserted rather than assumed.
  assert.ok(Math.abs(check.consensus - node.naturalPeriod) / node.naturalPeriod < 0.25,
    `measured ${check.consensus.toFixed(3)} s, expected near ${node.naturalPeriod.toFixed(3)} s`);
});

test('damaging the simulated building lengthens its measured period', async () => {
  const { SimulatedNode } = await import('../www/js/core/node.js');
  const settle = (node, seconds) => {
    for (let i = 0; i < seconds * 20; i += 1) node.tick(1 / 20);
  };

  const node = new SimulatedNode({
    building: { storeyCount: 8, height: 27, footprintArea: 620, system: 'momentFrame' },
  });
  node.connect();

  const { before, after } = withSeededRandom(98765, () => {
    settle(node, 60);
    const first = crossCheckedPeriod(node.record(60).x).consensus;

    node.introduceDamage(1.25);
    node.x.length = 0; node.y.length = 0; node.z.length = 0;
    settle(node, 60);
    return { before: first, after: crossCheckedPeriod(node.record(60).x).consensus };
  });

  assert.ok(before && after, 'a period should be measurable before and after');
  assert.ok(after > before,
    `period should lengthen: ${before.toFixed(3)} -> ${after.toFixed(3)}`);
});
