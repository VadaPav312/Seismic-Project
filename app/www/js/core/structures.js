// The structural model: a shear building, its modes, and its response.
//
// A shear building is the standard idealisation for this kind of assessment:
// floors are rigid and carry the mass, columns between them carry the stiffness,
// and the building deforms by storeys sliding relative to one another. It is not
// the whole truth — it ignores axial shortening and does nothing about torsion —
// but it captures the thing this app is actually measuring, which is how the
// fundamental period moves when storey stiffness is lost.

import {
  factorise, solveFactorised, symmetricEigen, multiply, dot, norm,
} from './linalg.js';

export const MATERIALS = {
  reinforcedConcrete: { label: 'Reinforced concrete', damping: 0.05, density: 2400 },
  steel: { label: 'Steel', damping: 0.02, density: 7850 },
  timber: { label: 'Timber', damping: 0.07, density: 500 },
  masonry: { label: 'Masonry', damping: 0.08, density: 1900 },
  unreinforcedMasonry: { label: 'Unreinforced masonry', damping: 0.10, density: 1900 },
  hybrid: { label: 'Hybrid', damping: 0.04, density: 2200 },
  unknown: { label: 'Unknown', damping: 0.05, density: 2200 },
};

export const SYSTEMS = {
  momentFrame: { label: 'Moment frame', periodCoefficient: 0.075, periodExponent: 0.75 },
  bracedFrame: { label: 'Braced frame', periodCoefficient: 0.049, periodExponent: 0.75 },
  shearWall: { label: 'Shear wall', periodCoefficient: 0.049, periodExponent: 0.75 },
  dualSystem: { label: 'Dual system', periodCoefficient: 0.062, periodExponent: 0.75 },
  baseIsolated: { label: 'Base isolated', periodCoefficient: 0.12, periodExponent: 0.80 },
  softStorey: { label: 'Soft storey', periodCoefficient: 0.085, periodExponent: 0.78 },
  unreinforced: { label: 'Unreinforced', periodCoefficient: 0.045, periodExponent: 0.72 },
};

/**
 * The empirical period from the building codes: T = Ct * H^x.
 *
 * Worth stating plainly — this is a regression through measured buildings, not
 * a derivation. It is what the app compares its own measurement against, and
 * when the two disagree the measurement wins, because one of them was taken
 * from this building.
 */
export function empiricalPeriod({ height, system = 'momentFrame' }) {
  const s = SYSTEMS[system] ?? SYSTEMS.momentFrame;
  const period = s.periodCoefficient * Math.pow(Math.max(height, 1), s.periodExponent);
  return Number.isFinite(period) ? period : 0.1;
}

export class ShearBuilding {
  /** @param storeys array of { height, mass, stiffness } */
  constructor(storeys, damping = 0.05) {
    this.storeys = storeys ?? [];
    this.damping = Number.isFinite(damping) ? Math.min(Math.max(damping, 0), 0.5) : 0.05;
  }

  get degreesOfFreedom() { return this.storeys.length; }

  get totalHeight() {
    return this.storeys.reduce((sum, s) => sum + s.height, 0);
  }

  get totalMass() {
    return this.storeys.reduce((sum, s) => sum + s.mass, 0);
  }

  massMatrix() {
    const n = this.degreesOfFreedom;
    return Array.from({ length: n }, (_, i) => {
      const row = new Float64Array(n);
      // A zero-mass storey makes the mass matrix singular and every derived
      // quantity NaN. Importers do produce them, so a floor is applied here
      // rather than trusting the data.
      row[i] = Math.max(this.storeys[i].mass, 1);
      return row;
    });
  }

  /** Tridiagonal: each storey is connected only to the ones above and below. */
  stiffnessMatrix() {
    const n = this.degreesOfFreedom;
    const k = this.storeys.map((s) => Math.max(s.stiffness, 1));
    return Array.from({ length: n }, (_, i) => {
      const row = new Float64Array(n);
      row[i] = k[i] + (i + 1 < n ? k[i + 1] : 0);
      if (i > 0) row[i - 1] = -k[i];
      if (i + 1 < n) row[i + 1] = -k[i + 1];
      return row;
    });
  }

  /**
   * Rayleigh damping, anchored to the first and last computed modes.
   *
   * Chosen because it keeps the damping matrix a linear combination of mass and
   * stiffness, which is what lets the whole system be integrated without
   * decoupling it into modal coordinates first.
   */
  dampingMatrix(modes) {
    const n = this.degreesOfFreedom;
    const mass = this.massMatrix();
    const stiffness = this.stiffnessMatrix();

    const w1 = modes[0]?.frequency ? 2 * Math.PI * modes[0].frequency : 1;
    const w2 = modes.length > 1 && modes[modes.length - 1].frequency
      ? 2 * Math.PI * modes[modes.length - 1].frequency
      : w1 * 3;

    const zeta = this.damping;
    let a0 = 0;
    let a1 = 0;
    if (w1 > 0 && w2 > w1) {
      a0 = (2 * zeta * w1 * w2) / (w1 + w2);
      a1 = (2 * zeta) / (w1 + w2);
    } else if (w1 > 0) {
      a0 = zeta * w1;
      a1 = zeta / w1;
    }

    return Array.from({ length: n }, (_, i) => {
      const row = new Float64Array(n);
      for (let j = 0; j < n; j += 1) row[j] = a0 * mass[i][j] + a1 * stiffness[i][j];
      return row;
    });
  }

  /**
   * Builds a model from a described building.
   *
   * Mass comes from the floor area at a realistic loading; stiffness is solved
   * backwards from the empirical period so that the model, before any
   * measurement, agrees with what the codes expect of a building this shape.
   * That is deliberate: the model starts where an engineer would start, and the
   * measurement then moves it.
   */
  static from(building) {
    const storeyCount = Math.max(1, Math.round(building.storeyCount ?? 1));
    const height = Math.max(building.height ?? storeyCount * 3.4, 1);
    const storeyHeight = height / storeyCount;
    const area = Math.max(building.footprintArea ?? 400, 10);

    // ~1100 kg/m2 for a concrete floor plate with its live load: heavy, but
    // this is seismic mass, which includes the structure itself.
    const massPerStorey = area * 1100;

    const target = building.empiricalPeriod
      ?? empiricalPeriod({ height, system: building.system });

    // For a uniform shear building the fundamental frequency is approximately
    // sqrt(k/m) * 2 sin(pi / (2(2n+1))), which inverts to give the storey
    // stiffness that lands on the target period.
    const n = storeyCount;
    const factor = 2 * Math.sin(Math.PI / (2 * (2 * n + 1)));
    const omega = (2 * Math.PI) / Math.max(target, 0.05);
    const stiffness = massPerStorey * ((omega / Math.max(factor, 1e-6)) ** 2);

    const material = MATERIALS[building.material] ?? MATERIALS.reinforcedConcrete;
    const storeys = Array.from({ length: n }, (_, i) => ({
      index: i + 1,
      height: storeyHeight,
      mass: massPerStorey,
      // A soft storey is a real and lethal configuration: a ground floor of
      // shopfronts or parking with far less stiffness than everything above it.
      stiffness: building.system === 'softStorey' && i === 0 ? stiffness * 0.45 : stiffness,
      floorArea: area,
    }));

    return new ShearBuilding(storeys, building.damping ?? material.damping);
  }
}

/**
 * Mode shapes, frequencies and mass participation.
 *
 * Solves the generalised problem by transforming to the standard one with the
 * mass matrix's square root, which is trivial here because the mass matrix is
 * diagonal.
 */
export function modes(building) {
  const n = building.degreesOfFreedom;
  if (n === 0) return [];

  const mass = building.massMatrix();
  const stiffness = building.stiffnessMatrix();

  const rootMassInverse = Array.from({ length: n }, (_, i) => 1 / Math.sqrt(mass[i][i]));
  const reduced = Array.from({ length: n }, (_, i) => {
    const row = new Float64Array(n);
    for (let j = 0; j < n; j += 1) {
      row[j] = stiffness[i][j] * rootMassInverse[i] * rootMassInverse[j];
    }
    return row;
  });

  const { values, vectors } = symmetricEigen(reduced);
  const totalMass = building.totalMass;

  return values.map((eigenvalue, index) => {
    const omegaSquared = Math.max(eigenvalue, 0);
    const omega = Math.sqrt(omegaSquared);
    const frequency = omega / (2 * Math.PI);

    const shape = vectors[index].map((value, i) => value * rootMassInverse[i]);
    const largest = shape.reduce((m, v) => Math.max(m, Math.abs(v)), 0) || 1;
    const normalised = shape.map((v) => v / largest);

    // Mass participation: how much of the building's mass this mode actually
    // moves. It is why the first mode usually matters and the fifth usually
    // does not.
    let numerator = 0;
    let denominator = 0;
    for (let i = 0; i < n; i += 1) {
      numerator += mass[i][i] * normalised[i];
      denominator += mass[i][i] * normalised[i] * normalised[i];
    }
    const participation = denominator > 0 && totalMass > 0
      ? (numerator * numerator) / (denominator * totalMass)
      : 0;

    return {
      number: index + 1,
      frequency: Number.isFinite(frequency) ? frequency : 0,
      period: frequency > 0 ? 1 / frequency : 0,
      shape: normalised,
      massParticipationRatio: Number.isFinite(participation) ? Math.min(participation, 1) : 0,
    };
  });
}

/**
 * The fundamental period, by inverse power iteration.
 *
 * A full eigendecomposition to obtain one number is wasteful, and this runs
 * inside the solver's damage loop where it is called repeatedly. Inverse
 * iteration against a single reused factorisation converges to the lowest mode
 * in a handful of passes.
 */
export function fundamentalPeriod(building) {
  const n = building.degreesOfFreedom;
  if (n === 0) return 0;

  const mass = building.massMatrix();
  const stiffness = building.stiffnessMatrix();
  const factorisation = factorise(stiffness);
  if (!factorisation) return 0;

  let vector = new Float64Array(n).fill(1);
  let omegaSquared = 0;

  for (let iteration = 0; iteration < 40; iteration += 1) {
    const rhs = multiply(mass, vector);
    const next = solveFactorised(factorisation, rhs);
    if (!next) return 0;

    const length = norm(next);
    if (!(length > 0)) return 0;
    for (let i = 0; i < n; i += 1) next[i] /= length;

    // Rayleigh quotient, which converges quadratically even when the vector
    // itself is still settling.
    const kv = multiply(stiffness, next);
    const mv = multiply(mass, next);
    const numerator = dot(next, kv);
    const denominator = dot(next, mv);
    const estimate = denominator > 0 ? numerator / denominator : 0;

    if (Math.abs(estimate - omegaSquared) < 1e-10 * Math.max(estimate, 1)) {
      omegaSquared = estimate;
      break;
    }
    omegaSquared = estimate;
    vector = next;
  }

  const omega = Math.sqrt(Math.max(omegaSquared, 0));
  return omega > 0 ? (2 * Math.PI) / omega : 0;
}

export const DRIFT_THRESHOLDS = {
  // Interstorey drift ratios at which each damage state begins. These are the
  // numbers a verdict ultimately rests on, so they are stated explicitly rather
  // than buried in a formula.
  momentFrame: { slight: 0.004, moderate: 0.008, extensive: 0.020, complete: 0.050 },
  bracedFrame: { slight: 0.003, moderate: 0.006, extensive: 0.015, complete: 0.040 },
  shearWall: { slight: 0.002, moderate: 0.005, extensive: 0.012, complete: 0.030 },
  dualSystem: { slight: 0.003, moderate: 0.007, extensive: 0.017, complete: 0.045 },
  baseIsolated: { slight: 0.005, moderate: 0.010, extensive: 0.025, complete: 0.060 },
  softStorey: { slight: 0.003, moderate: 0.006, extensive: 0.014, complete: 0.030 },
  unreinforced: { slight: 0.001, moderate: 0.003, extensive: 0.007, complete: 0.015 },
};

export const DAMAGE_STATES = ['none', 'slight', 'moderate', 'extensive', 'complete'];

export function damageState(drift, system = 'momentFrame') {
  const t = DRIFT_THRESHOLDS[system] ?? DRIFT_THRESHOLDS.momentFrame;
  const d = Math.abs(drift);
  if (d >= t.complete) return 4;
  if (d >= t.extensive) return 3;
  if (d >= t.moderate) return 2;
  if (d >= t.slight) return 1;
  return 0;
}

/**
 * Newmark-beta time integration of the whole building.
 *
 * Average acceleration (beta = 1/4, gamma = 1/2), which is unconditionally
 * stable — the alternative would impose a time step limit tied to the highest
 * mode, and a sixty-storey building's highest mode is far faster than anything
 * worth resolving.
 *
 * The effective stiffness matrix is constant, so it is factorised once and the
 * factorisation reused for every step. Doing otherwise is what turns a
 * one-second solve into a hang.
 */
export function solve(building, groundAcceleration, {
  system = 'momentFrame', degradeStiffness = true,
} = {}) {
  const n = building.degreesOfFreedom;
  const samples = groundAcceleration?.samples ?? [];
  const rate = groundAcceleration?.sampleRate ?? 0;

  const empty = {
    times: [], displacements: [], drifts: [], storeyResults: [],
    maximumDrift: 0, initialPeriod: 0, finalPeriod: 0, periodChangePercent: 0,
    peakDisplacement: 0, peakAcceleration: 0,
  };
  if (n === 0 || rate <= 0 || samples.length < 2) return empty;

  const initialPeriod = fundamentalPeriod(building);

  const mass = building.massMatrix();
  let stiffness = building.stiffnessMatrix();
  const modeList = modes(building);
  const damping = building.dampingMatrix(modeList);

  const dt = 1 / rate;
  const beta = 0.25;
  const gamma = 0.5;

  const effective = Array.from({ length: n }, (_, i) => {
    const row = new Float64Array(n);
    for (let j = 0; j < n; j += 1) {
      row[j] = stiffness[i][j]
        + mass[i][j] / (beta * dt * dt)
        + (gamma * damping[i][j]) / (beta * dt);
    }
    return row;
  });

  let factorisation = factorise(effective);
  if (!factorisation) return { ...empty, initialPeriod, finalPeriod: initialPeriod };

  let u = new Float64Array(n);
  let v = new Float64Array(n);
  let a = new Float64Array(n);

  const storeyHeights = building.storeys.map((s) => Math.max(s.height, 0.1));
  const peakDrift = new Float64Array(n);
  const peakDisplacementPerStorey = new Float64Array(n);
  const damaged = new Array(n).fill(false);

  const stride = Math.max(1, Math.round(samples.length / 600));
  const times = [];
  const displacementHistory = [];
  const driftHistory = [];

  let maximumDrift = 0;
  let peakAcceleration = 0;

  for (let step = 1; step < samples.length; step += 1) {
    const ground = Number.isFinite(samples[step]) ? samples[step] : 0;

    const rhs = new Float64Array(n);
    for (let i = 0; i < n; i += 1) {
      let inertia = 0;
      let viscous = 0;
      for (let j = 0; j < n; j += 1) {
        inertia += mass[i][j] * (
          u[j] / (beta * dt * dt)
          + v[j] / (beta * dt)
          + (1 / (2 * beta) - 1) * a[j]
        );
        viscous += damping[i][j] * (
          (gamma / (beta * dt)) * u[j]
          + (gamma / beta - 1) * v[j]
          + dt * (gamma / (2 * beta) - 1) * a[j]
        );
      }
      // Ground motion enters as an inertial force on every mass.
      rhs[i] = -mass[i][i] * ground + inertia + viscous;
    }

    const uNext = solveFactorised(factorisation, rhs);
    if (!uNext) break;

    const aNext = new Float64Array(n);
    const vNext = new Float64Array(n);
    for (let i = 0; i < n; i += 1) {
      aNext[i] = (uNext[i] - u[i]) / (beta * dt * dt)
        - v[i] / (beta * dt)
        - (1 / (2 * beta) - 1) * a[i];
      vNext[i] = v[i] + dt * ((1 - gamma) * a[i] + gamma * aNext[i]);
    }

    u = uNext;
    v = vNext;
    a = aNext;

    let stiffnessChanged = false;
    for (let i = 0; i < n; i += 1) {
      const relative = i === 0 ? u[0] : u[i] - u[i - 1];
      const drift = Math.abs(relative) / storeyHeights[i];
      if (drift > peakDrift[i]) peakDrift[i] = drift;
      if (Math.abs(u[i]) > peakDisplacementPerStorey[i]) {
        peakDisplacementPerStorey[i] = Math.abs(u[i]);
      }
      if (drift > maximumDrift) maximumDrift = drift;

      const total = Math.abs(a[i] + ground);
      if (total > peakAcceleration) peakAcceleration = total;

      // Stiffness degradation, once, when a storey first passes the moderate
      // threshold. This is what makes the measured period lengthen after an
      // event — the effect the entire app is built to detect.
      if (degradeStiffness && !damaged[i] && damageState(drift, system) >= 2) {
        damaged[i] = true;
        stiffnessChanged = true;
      }
    }

    if (stiffnessChanged) {
      const degraded = building.storeys.map((s, i) => ({
        ...s,
        stiffness: damaged[i] ? s.stiffness * 0.65 : s.stiffness,
      }));
      const degradedBuilding = new ShearBuilding(degraded, building.damping);
      stiffness = degradedBuilding.stiffnessMatrix();
      const newEffective = Array.from({ length: n }, (_, i) => {
        const row = new Float64Array(n);
        for (let j = 0; j < n; j += 1) {
          row[j] = stiffness[i][j]
            + mass[i][j] / (beta * dt * dt)
            + (gamma * damping[i][j]) / (beta * dt);
        }
        return row;
      });
      const refactored = factorise(newEffective);
      if (refactored) factorisation = refactored;
    }

    if (step % stride === 0) {
      times.push(step * dt);
      displacementHistory.push(Array.from(u));
      driftHistory.push(building.storeys.map((_, i) => {
        const relative = i === 0 ? u[0] : u[i] - u[i - 1];
        return relative / storeyHeights[i];
      }));
    }
  }

  const finalStoreys = building.storeys.map((s, i) => ({
    ...s,
    stiffness: damaged[i] ? s.stiffness * 0.65 : s.stiffness,
  }));
  const finalPeriod = fundamentalPeriod(new ShearBuilding(finalStoreys, building.damping));

  const change = initialPeriod > 0
    ? ((finalPeriod - initialPeriod) / initialPeriod) * 100
    : 0;

  return {
    times,
    displacements: displacementHistory,
    drifts: driftHistory,
    storeyResults: building.storeys.map((s, i) => ({
      storey: i + 1,
      peakDrift: peakDrift[i],
      peakDisplacement: peakDisplacementPerStorey[i],
      damageState: damageState(peakDrift[i], system),
      damaged: damaged[i],
    })),
    maximumDrift,
    initialPeriod,
    finalPeriod,
    periodChangePercent: Number.isFinite(change) ? change : 0,
    peakDisplacement: Math.max(...peakDisplacementPerStorey, 0),
    peakAcceleration,
  };
}

/**
 * Lognormal fragility: the probability of reaching each damage state at a
 * given demand.
 *
 * Fragility curves are the honest way to express this. A building does not have
 * a drift at which it is fine and one micron more at which it is not; it has a
 * probability that rises through a range, and saying so is more useful than a
 * false line in the sand.
 */
export function fragility(drift, system = 'momentFrame', beta = 0.5) {
  const t = DRIFT_THRESHOLDS[system] ?? DRIFT_THRESHOLDS.momentFrame;
  const demand = Math.max(Math.abs(drift), 1e-12);

  const exceedance = (median) => {
    if (!Number.isFinite(demand) || demand <= 0) return 0;
    const z = Math.log(demand / median) / beta;
    return clamp(standardNormalCdf(z), 0, 1);
  };

  return {
    slight: exceedance(t.slight),
    moderate: exceedance(t.moderate),
    extensive: exceedance(t.extensive),
    complete: exceedance(t.complete),
  };
}

function standardNormalCdf(z) {
  if (!Number.isFinite(z)) return z > 0 ? 1 : 0;
  // Abramowitz & Stegun 7.1.26, accurate to about 1e-7 — far beyond what a
  // fragility curve's own uncertainty justifies.
  const sign = z < 0 ? -1 : 1;
  const x = Math.abs(z) / Math.SQRT2;
  const t = 1 / (1 + 0.3275911 * x);
  const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
    + 0.254829592) * t * Math.exp(-x * x);
  return 0.5 * (1 + sign * y);
}

function clamp(value, low, high) {
  if (!Number.isFinite(value)) return low;
  return Math.min(Math.max(value, low), high);
}

/**
 * Sweeps a driving frequency across the building's response.
 *
 * The step rate adapts to the fastest mode present rather than being fixed:
 * a fixed rate is either far too slow to resolve a stiff building's resonance
 * or wastefully fine for a tall one.
 */
export function resonanceSweep(building, { from = 0.1, to = 5, points = 60 } = {}) {
  const modeList = modes(building);
  if (modeList.length === 0) return [];

  const fundamental = modeList[0].frequency || 1;
  const zeta = Math.max(building.damping, 0.005);

  const out = [];
  for (let i = 0; i < points; i += 1) {
    const frequency = from + ((to - from) * i) / (points - 1);
    const ratio = frequency / fundamental;
    // Steady-state amplification of a single-degree oscillator. Enough for the
    // teaching point: the peak sits at the natural frequency and its height is
    // set by damping.
    const denominator = Math.sqrt(
      (1 - ratio * ratio) ** 2 + (2 * zeta * ratio) ** 2,
    );
    const amplification = denominator > 1e-9 ? 1 / denominator : 0;
    out.push({
      frequency,
      amplification: Number.isFinite(amplification) ? Math.min(amplification, 100) : 0,
    });
  }
  return out;
}
