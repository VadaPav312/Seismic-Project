// The signal chain: waveforms, filtering, integration and the transform.
//
// Everything here works on plain Float64Array and returns new arrays rather
// than mutating. A trace that is quietly filtered in place is a trace that
// cannot be shown next to its own raw version, and showing both is most of how
// this app earns trust.

export class Waveform {
  constructor(samples, sampleRate, unit = 'acceleration') {
    this.samples = samples instanceof Float64Array
      ? samples
      : Float64Array.from(samples ?? []);
    this.sampleRate = sampleRate > 0 ? sampleRate : 0;
    this.unit = unit;
  }

  get count() { return this.samples.length; }

  get duration() {
    return this.sampleRate > 0 ? this.samples.length / this.sampleRate : 0;
  }

  get peak() {
    let peak = 0;
    for (const value of this.samples) {
      const magnitude = Math.abs(value);
      if (Number.isFinite(magnitude) && magnitude > peak) peak = magnitude;
    }
    return peak;
  }

  get mean() {
    if (this.samples.length === 0) return 0;
    let sum = 0;
    for (const value of this.samples) sum += value;
    return sum / this.samples.length;
  }

  get rms() {
    if (this.samples.length === 0) return 0;
    let sum = 0;
    for (const value of this.samples) sum += value * value;
    return Math.sqrt(sum / this.samples.length);
  }

  slice(fromSeconds, toSeconds) {
    if (this.sampleRate <= 0) return new Waveform([], 0, this.unit);
    const start = Math.max(0, Math.floor(fromSeconds * this.sampleRate));
    const end = Math.min(this.samples.length, Math.ceil(toSeconds * this.sampleRate));
    if (end <= start) return new Waveform([], this.sampleRate, this.unit);
    return new Waveform(this.samples.slice(start, end), this.sampleRate, this.unit);
  }

  static zeros(count, sampleRate, unit = 'acceleration') {
    return new Waveform(new Float64Array(Math.max(count, 0)), sampleRate, unit);
  }
}

export class TriaxialRecord {
  constructor(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }

  get count() { return Math.min(this.x.count, this.y.count, this.z.count); }
  get sampleRate() { return this.x.sampleRate; }
  get duration() { return this.x.duration; }

  slice(fromSeconds, toSeconds) {
    return new TriaxialRecord(
      this.x.slice(fromSeconds, toSeconds),
      this.y.slice(fromSeconds, toSeconds),
      this.z.slice(fromSeconds, toSeconds),
    );
  }

  static zeros(count, sampleRate) {
    return new TriaxialRecord(
      Waveform.zeros(count, sampleRate),
      Waveform.zeros(count, sampleRate),
      Waveform.zeros(count, sampleRate),
    );
  }
}

/**
 * Replaces non-finite samples with zero.
 *
 * A NaN or an infinity from the sensor is a hardware fault, not a measurement,
 * and arithmetic spreads it: one bad sample in a transform makes every
 * frequency bin NaN, and a NaN that reaches a verdict is far worse than a
 * dropped sample — it renders the whole spectrum blank with no explanation.
 * Every entry point to the signal chain goes through here.
 */
export function sanitise(waveform) {
  let needed = false;
  for (const value of waveform.samples) {
    if (!Number.isFinite(value)) { needed = true; break; }
  }
  if (!needed) return waveform;

  const out = new Float64Array(waveform.samples.length);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = Number.isFinite(waveform.samples[i]) ? waveform.samples[i] : 0;
  }
  return new Waveform(out, waveform.sampleRate, waveform.unit);
}

/** Removes the mean. The first thing done to anything from a real sensor. */
export function removeMean(waveform) {
  const clean = sanitise(waveform);
  const mean = clean.mean;
  const out = new Float64Array(clean.samples.length);
  for (let i = 0; i < out.length; i += 1) out[i] = clean.samples[i] - mean;
  return new Waveform(out, clean.sampleRate, clean.unit);
}

/**
 * Removes a least-squares straight line.
 *
 * Accelerometers drift, and a drift that survives into the integration becomes
 * a displacement that grows without bound — a building that appears to walk
 * down the street. Detrending before integrating is not optional.
 */
export function detrend(input) {
  const waveform = sanitise(input);
  const n = waveform.samples.length;
  if (n < 2) return new Waveform(waveform.samples.slice(), waveform.sampleRate, waveform.unit);

  let sumX = 0;
  let sumY = 0;
  let sumXY = 0;
  let sumXX = 0;
  for (let i = 0; i < n; i += 1) {
    const y = waveform.samples[i];
    sumX += i;
    sumY += y;
    sumXY += i * y;
    sumXX += i * i;
  }
  const denominator = n * sumXX - sumX * sumX;
  const slope = denominator === 0 ? 0 : (n * sumXY - sumX * sumY) / denominator;
  const intercept = (sumY - slope * sumX) / n;

  const out = new Float64Array(n);
  for (let i = 0; i < n; i += 1) out[i] = waveform.samples[i] - (slope * i + intercept);
  return new Waveform(out, waveform.sampleRate, waveform.unit);
}

/**
 * A Butterworth filter as a cascade of biquads, applied forwards then
 * backwards.
 *
 * Filtering twice in opposite directions cancels the phase shift exactly. That
 * matters more here than the doubled roll-off: a phase shift moves the arrival
 * time of the P wave, and the arrival time is what the distance estimate is
 * built on.
 */
export function butterworth(waveform, {
  kind = 'bandpass', order = 4, lowCutoff = 0.1, highCutoff = 25,
} = {}) {
  const rate = waveform.sampleRate;
  const n = waveform.samples.length;
  if (rate <= 0 || n < 8) {
    return new Waveform(waveform.samples.slice(), rate, waveform.unit);
  }

  const nyquist = rate / 2;
  const low = Math.min(Math.max(lowCutoff, 1e-6), nyquist * 0.999);
  const high = Math.min(Math.max(highCutoff, low * 1.001), nyquist * 0.999);

  let out = Float64Array.from(waveform.samples);
  const sections = Math.max(1, Math.round(order / 2));

  for (let section = 0; section < sections; section += 1) {
    // Each section gets its own Q from the Butterworth pole positions, which is
    // what makes the cascade maximally flat rather than merely repeated.
    const theta = (Math.PI * (2 * section + 1)) / (2 * sections * 2);
    const q = 1 / (2 * Math.sin(theta) || 1);

    if (kind === 'bandpass') {
      out = biquad(out, rate, low, q, 'highpass');
      out = biquad(out, rate, high, q, 'lowpass');
    } else if (kind === 'highpass') {
      out = biquad(out, rate, low, q, 'highpass');
    } else {
      out = biquad(out, rate, high, q, 'lowpass');
    }
  }

  return new Waveform(out, rate, waveform.unit);
}

function biquad(samples, rate, cutoff, q, kind) {
  const omega = (2 * Math.PI * cutoff) / rate;
  const cos = Math.cos(omega);
  const sin = Math.sin(omega);
  const alpha = sin / (2 * Math.max(q, 1e-6));

  let b0;
  let b1;
  let b2;
  if (kind === 'lowpass') {
    b0 = (1 - cos) / 2;
    b1 = 1 - cos;
    b2 = (1 - cos) / 2;
  } else {
    b0 = (1 + cos) / 2;
    b1 = -(1 + cos);
    b2 = (1 + cos) / 2;
  }
  const a0 = 1 + alpha;
  const a1 = -2 * cos;
  const a2 = 1 - alpha;

  const forward = applyBiquad(samples, b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  const reversed = forward.slice().reverse();
  const backward = applyBiquad(reversed, b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  return backward.reverse();
}

function applyBiquad(samples, b0, b1, b2, a1, a2) {
  const out = new Float64Array(samples.length);
  let x1 = 0;
  let x2 = 0;
  let y1 = 0;
  let y2 = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const x0 = samples[i];
    let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    if (!Number.isFinite(y0)) y0 = 0;
    out[i] = y0;
    x2 = x1;
    x1 = x0;
    y2 = y1;
    y1 = y0;
  }
  return out;
}

/**
 * Trapezoidal integration to velocity and then displacement, detrending
 * between the two.
 *
 * The intermediate detrend is the important part. Any constant offset left in
 * the acceleration integrates to a ramp in velocity and a parabola in
 * displacement, and the parabola swamps the signal within a few seconds.
 */
export function integrate(acceleration) {
  const rate = acceleration.sampleRate;
  if (rate <= 0 || acceleration.samples.length < 2) {
    return {
      velocity: Waveform.zeros(acceleration.samples.length, rate, 'velocity'),
      displacement: Waveform.zeros(acceleration.samples.length, rate, 'displacement'),
    };
  }

  const dt = 1 / rate;
  const cleaned = detrend(removeMean(acceleration));

  const velocitySamples = new Float64Array(cleaned.samples.length);
  for (let i = 1; i < cleaned.samples.length; i += 1) {
    velocitySamples[i] = velocitySamples[i - 1]
      + ((cleaned.samples[i] + cleaned.samples[i - 1]) / 2) * dt;
  }
  const velocity = detrend(new Waveform(velocitySamples, rate, 'velocity'));

  const displacementSamples = new Float64Array(velocity.samples.length);
  for (let i = 1; i < velocity.samples.length; i += 1) {
    displacementSamples[i] = displacementSamples[i - 1]
      + ((velocity.samples[i] + velocity.samples[i - 1]) / 2) * dt;
  }
  const displacement = detrend(new Waveform(displacementSamples, rate, 'displacement'));

  return { velocity, displacement };
}

// MARK: Windows

export const WINDOWS = {
  none: { label: 'None', apply: () => 1 },
  hann: {
    label: 'Hann',
    apply: (i, n) => 0.5 * (1 - Math.cos((2 * Math.PI * i) / (n - 1))),
  },
  hamming: {
    label: 'Hamming',
    apply: (i, n) => 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (n - 1)),
  },
  blackman: {
    label: 'Blackman',
    apply: (i, n) => 0.42
      - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1))
      + 0.08 * Math.cos((4 * Math.PI * i) / (n - 1)),
  },
};

/**
 * Iterative radix-2 FFT, in place, on separate real and imaginary arrays.
 *
 * Written out rather than pulled from a package because it is forty lines, it
 * has no dependencies to audit, and a safety app should be able to account for
 * every line between the sensor and the number on screen.
 */
export function fft(real, imaginary) {
  const n = real.length;
  if (n <= 1 || (n & (n - 1)) !== 0) {
    throw new Error(`FFT length must be a power of two, got ${n}`);
  }

  for (let i = 1, j = 0; i < n; i += 1) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [real[i], real[j]] = [real[j], real[i]];
      [imaginary[i], imaginary[j]] = [imaginary[j], imaginary[i]];
    }
  }

  for (let length = 2; length <= n; length <<= 1) {
    const angle = (-2 * Math.PI) / length;
    const wReal = Math.cos(angle);
    const wImaginary = Math.sin(angle);
    for (let i = 0; i < n; i += length) {
      let curReal = 1;
      let curImaginary = 0;
      for (let j = 0; j < length / 2; j += 1) {
        const uReal = real[i + j];
        const uImaginary = imaginary[i + j];
        const vReal = real[i + j + length / 2] * curReal
                    - imaginary[i + j + length / 2] * curImaginary;
        const vImaginary = real[i + j + length / 2] * curImaginary
                         + imaginary[i + j + length / 2] * curReal;

        real[i + j] = uReal + vReal;
        imaginary[i + j] = uImaginary + vImaginary;
        real[i + j + length / 2] = uReal - vReal;
        imaginary[i + j + length / 2] = uImaginary - vImaginary;

        const nextReal = curReal * wReal - curImaginary * wImaginary;
        curImaginary = curReal * wImaginary + curImaginary * wReal;
        curReal = nextReal;
      }
    }
  }
}

export function nextPowerOfTwo(value) {
  let power = 1;
  while (power < value) power <<= 1;
  return power;
}
