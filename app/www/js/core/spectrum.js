// Spectral estimation and everything read off a spectrum.
//
// The app's central claim is that a building's natural period changes when it
// is damaged. This file is where that period comes from, so it is also where
// the app is most able to mislead — a peak that is really a noise artefact
// looks exactly like a peak that is really a mode. Hence Welch averaging rather
// than a single transform, prominence rather than height for picking, and a
// cross-check that reports how many independent methods agreed.

import {
  Waveform, WINDOWS, fft, nextPowerOfTwo, removeMean, detrend, sanitise,
} from './signal.js';

/**
 * Welch's method: average the spectra of overlapping windows.
 *
 * A single transform of a noisy record gives an estimate whose variance does
 * not fall as the record gets longer — more data just buys more, equally noisy,
 * frequency bins. Averaging segments trades frequency resolution for variance,
 * which is the right trade when looking for one broad peak.
 */
export function welch(waveform, {
  segments = 8, overlap = 0.5, window = 'hann',
} = {}) {
  const rate = waveform.sampleRate;
  const samples = detrend(removeMean(waveform)).samples;
  if (rate <= 0 || samples.length < 16) {
    return { frequencies: [], power: [], resolution: 0, segmentsUsed: 0 };
  }

  const target = Math.floor(samples.length / Math.max(1, segments / 2));
  const size = Math.min(nextPowerOfTwo(Math.max(target, 32)), nextPowerOfTwo(samples.length));
  if (size < 16) return { frequencies: [], power: [], resolution: 0, segmentsUsed: 0 };

  const step = Math.max(1, Math.floor(size * (1 - overlap)));
  const shape = WINDOWS[window] ?? WINDOWS.hann;

  const taper = new Float64Array(size);
  let windowPower = 0;
  for (let i = 0; i < size; i += 1) {
    taper[i] = shape.apply(i, size);
    windowPower += taper[i] * taper[i];
  }
  // Normalising by the window's own power keeps the estimate a true power
  // spectral density, so a Hann window and a rectangular one report the same
  // level for the same signal instead of differing by a constant nobody sees.
  windowPower = windowPower || size;

  const bins = size / 2;
  const accumulated = new Float64Array(bins);
  let used = 0;

  for (let start = 0; start + size <= samples.length; start += step) {
    const real = new Float64Array(size);
    const imaginary = new Float64Array(size);
    for (let i = 0; i < size; i += 1) real[i] = samples[start + i] * taper[i];

    fft(real, imaginary);
    for (let bin = 0; bin < bins; bin += 1) {
      const magnitude = real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
      accumulated[bin] += magnitude;
    }
    used += 1;
  }

  if (used === 0) return { frequencies: [], power: [], resolution: 0, segmentsUsed: 0 };

  const scale = 1 / (used * rate * windowPower);
  const frequencies = new Float64Array(bins);
  const power = new Float64Array(bins);
  for (let bin = 0; bin < bins; bin += 1) {
    frequencies[bin] = (bin * rate) / size;
    // Single-sided: everything but DC and Nyquist doubles.
    const oneSided = bin === 0 || bin === bins - 1 ? 1 : 2;
    power[bin] = accumulated[bin] * scale * oneSided;
  }

  return { frequencies, power, resolution: rate / size, segmentsUsed: used };
}

/**
 * Konno-Ohmachi smoothing: constant bandwidth on a logarithmic axis.
 *
 * Linear smoothing of a spectrum is wrong in a specific and damaging way — it
 * flattens a 1 Hz peak far more than an 8 Hz one, because the same number of
 * bins is a much larger fraction of an octave down there. Since the modes this
 * app looks for are at low frequency, linear smoothing erases exactly what is
 * being measured.
 */
export function konnoOhmachi(spectrum, bandwidth = 40) {
  const { frequencies, power } = spectrum;
  const n = power.length;
  if (n === 0) return spectrum;

  const smoothed = new Float64Array(n);
  for (let i = 0; i < n; i += 1) {
    const centre = frequencies[i];
    if (centre <= 0) {
      smoothed[i] = power[i];
      continue;
    }
    let weighted = 0;
    let total = 0;
    for (let j = 0; j < n; j += 1) {
      const f = frequencies[j];
      if (f <= 0) continue;
      const ratio = Math.log10(f / centre) * bandwidth;
      if (Math.abs(ratio) > 3) continue;   // the kernel is negligible past here
      const w = ratio === 0 ? 1 : (Math.sin(ratio) / ratio) ** 4;
      weighted += power[j] * w;
      total += w;
    }
    smoothed[i] = total > 0 ? weighted / total : power[i];
  }

  return { ...spectrum, power: smoothed };
}

/**
 * Peaks by prominence, with the frequency refined by parabolic interpolation.
 *
 * Prominence rather than height, because a small bump riding on the shoulder of
 * a large peak is taller than an isolated peak elsewhere and is not a mode. The
 * parabola through the three bins around the maximum recovers most of the
 * resolution the bin spacing throws away, which matters when the whole
 * measurement is a period to three decimal places.
 */
export function peaks(spectrum, { minimumProminence = 0.15, limit = 6 } = {}) {
  const { frequencies, power } = spectrum;
  const n = power.length;
  if (n < 5) return [];

  let maximum = 0;
  for (const value of power) if (value > maximum) maximum = value;
  if (maximum <= 0) return [];

  const found = [];
  for (let i = 2; i < n - 2; i += 1) {
    const value = power[i];
    if (value < power[i - 1] || value < power[i + 1]) continue;

    // Prominence: how far this peak stands above the higher of the two
    // saddles either side of it.
    let leftMin = value;
    for (let j = i - 1; j >= 0; j -= 1) {
      if (power[j] > value) break;
      if (power[j] < leftMin) leftMin = power[j];
    }
    let rightMin = value;
    for (let j = i + 1; j < n; j += 1) {
      if (power[j] > value) break;
      if (power[j] < rightMin) rightMin = power[j];
    }
    const prominence = (value - Math.max(leftMin, rightMin)) / maximum;
    if (prominence < minimumProminence) continue;

    const y0 = power[i - 1];
    const y1 = power[i];
    const y2 = power[i + 1];
    const denominator = y0 - 2 * y1 + y2;
    const offset = denominator === 0 ? 0 : (0.5 * (y0 - y2)) / denominator;
    const spacing = frequencies[1] - frequencies[0];
    const frequency = frequencies[i] + offset * spacing;

    if (!Number.isFinite(frequency) || frequency <= 0) continue;
    found.push({ frequency, power: value, prominence, period: 1 / frequency });
  }

  return found.sort((a, b) => b.prominence - a.prominence).slice(0, limit);
}

/** Zero crossings per second, halved — a period estimate needing no transform. */
export function zeroCrossingPeriod(waveform) {
  const samples = detrend(removeMean(waveform)).samples;
  if (waveform.sampleRate <= 0 || samples.length < 8) return null;

  let crossings = 0;
  for (let i = 1; i < samples.length; i += 1) {
    if ((samples[i - 1] < 0 && samples[i] >= 0) || (samples[i - 1] > 0 && samples[i] <= 0)) {
      crossings += 1;
    }
  }
  if (crossings < 2) return null;
  const period = (2 * waveform.duration) / crossings;
  return Number.isFinite(period) && period > 0 ? period : null;
}

/** The lag of the first strong autocorrelation peak. */
export function autocorrelationPeriod(waveform) {
  const samples = detrend(removeMean(waveform)).samples;
  const rate = waveform.sampleRate;
  if (rate <= 0 || samples.length < 32) return null;

  const maxLag = Math.min(samples.length - 1, Math.floor(rate * 10));
  let zero = 0;
  for (const value of samples) zero += value * value;
  if (zero <= 0) return null;

  let previous = 1;
  let rising = false;
  for (let lag = 1; lag < maxLag; lag += 1) {
    let sum = 0;
    for (let i = 0; i + lag < samples.length; i += 1) sum += samples[i] * samples[i + lag];
    const value = sum / zero;

    // Wait for the correlation to turn back upwards before accepting a peak,
    // so the trivial maximum at lag zero is not rediscovered.
    if (!rising && value > previous) rising = true;
    if (rising && value < previous && previous > 0.2) {
      const period = (lag - 1) / rate;
      return Number.isFinite(period) && period > 0 ? period : null;
    }
    previous = value;
  }
  return null;
}

/**
 * Three independent period estimates, and an honest account of whether they
 * agree.
 *
 * The agreement figure is capped by how many methods actually answered. One
 * method agreeing with itself is not corroboration, and reporting 100%
 * confidence from a single estimate is how a stuck sensor becomes a confident
 * measurement.
 */
export function crossCheckedPeriod(waveform) {
  const estimates = [];

  const spectrum = konnoOhmachi(welch(waveform));
  const spectral = peaks(spectrum)[0];
  if (spectral) estimates.push({ method: 'Spectral peak', period: spectral.period });

  const zero = zeroCrossingPeriod(waveform);
  if (zero) estimates.push({ method: 'Zero crossings', period: zero });

  const auto = autocorrelationPeriod(waveform);
  if (auto) estimates.push({ method: 'Autocorrelation', period: auto });

  if (estimates.length === 0) {
    return { consensus: null, agreement: 0, estimates: [], note: 'No method could measure a period.' };
  }

  const periods = estimates.map((e) => e.period).sort((a, b) => a - b);
  const median = periods[Math.floor(periods.length / 2)];

  const agreeing = estimates.filter((e) => Math.abs(e.period - median) / median < 0.15);
  const ceiling = { 1: 0.35, 2: 0.8 }[estimates.length] ?? 1;
  const agreement = Math.min((agreeing.length / estimates.length) * ceiling, ceiling);

  return {
    consensus: median,
    agreement,
    estimates,
    note: estimates.length === 1
      ? 'Only one method could measure this, so it is not corroborated.'
      : `${agreeing.length} of ${estimates.length} methods agree.`,
  };
}

/**
 * Half-power bandwidth damping.
 *
 * Reads the width of the resonant peak at half its power. Only meaningful when
 * there is a clean isolated peak, so it returns null rather than a number when
 * the shoulders cannot be found.
 */
export function halfPowerDamping(spectrum, peak) {
  const { frequencies, power } = spectrum;
  if (!peak || power.length < 8) return null;

  let index = 0;
  let best = Infinity;
  for (let i = 0; i < frequencies.length; i += 1) {
    const distance = Math.abs(frequencies[i] - peak.frequency);
    if (distance < best) { best = distance; index = i; }
  }

  const half = power[index] / 2;
  let lower = null;
  for (let i = index; i > 0; i -= 1) {
    if (power[i] <= half) { lower = frequencies[i]; break; }
  }
  let upper = null;
  for (let i = index; i < frequencies.length; i += 1) {
    if (power[i] <= half) { upper = frequencies[i]; break; }
  }
  if (lower === null || upper === null || upper <= lower) return null;

  const ratio = (upper - lower) / (2 * peak.frequency);
  return Number.isFinite(ratio) && ratio > 0 && ratio < 1 ? ratio : null;
}

/**
 * The response spectrum: peak response of a family of single-degree
 * oscillators.
 *
 * This is what an engineer actually reads. It answers "how hard did this
 * shaking hit a building with *this* period", which is a different and more
 * useful question than how strong the shaking was.
 */
export function responseSpectrum(waveform, {
  damping = 0.05, periods = null,
} = {}) {
  const rate = waveform.sampleRate;
  if (rate <= 0 || waveform.samples.length < 8) return { periods: [], sa: [], sv: [], sd: [] };

  const targets = periods ?? logSpace(0.05, 4, 60);
  const dt = 1 / rate;
  // Sanitised: a single non-finite sample would otherwise make every
  // spectral acceleration NaN.
  const samples = sanitise(waveform).samples;

  const sa = new Float64Array(targets.length);
  const sv = new Float64Array(targets.length);
  const sd = new Float64Array(targets.length);

  for (let p = 0; p < targets.length; p += 1) {
    const period = targets[p];
    const omega = (2 * Math.PI) / period;

    // Newmark average acceleration, unconditionally stable — which matters
    // because the shortest periods here are far below the sample interval's
    // comfortable range and an explicit scheme would diverge.
    const beta = 0.25;
    const gamma = 0.5;
    const mass = 1;
    const stiffness = omega * omega;
    const c = 2 * damping * omega;

    const a1 = mass / (beta * dt * dt) + (gamma * c) / (beta * dt);
    const effective = stiffness + a1;

    let u = 0;
    let v = 0;
    let a = 0;
    let peakA = 0;
    let peakV = 0;
    let peakD = 0;

    for (let i = 1; i < samples.length; i += 1) {
      const force = -mass * samples[i];
      const rhs = force
        + mass * (u / (beta * dt * dt) + v / (beta * dt) + (1 / (2 * beta) - 1) * a)
        + c * ((gamma / (beta * dt)) * u
              + (gamma / beta - 1) * v
              + dt * (gamma / (2 * beta) - 1) * a);

      const uNext = rhs / effective;
      const aNext = (uNext - u) / (beta * dt * dt) - v / (beta * dt) - (1 / (2 * beta) - 1) * a;
      const vNext = v + dt * ((1 - gamma) * a + gamma * aNext);

      u = uNext;
      v = vNext;
      a = aNext;

      const total = Math.abs(a + samples[i]);
      if (total > peakA) peakA = total;
      if (Math.abs(v) > peakV) peakV = Math.abs(v);
      if (Math.abs(u) > peakD) peakD = Math.abs(u);
    }

    sa[p] = Number.isFinite(peakA) ? peakA : 0;
    sv[p] = Number.isFinite(peakV) ? peakV : 0;
    sd[p] = Number.isFinite(peakD) ? peakD : 0;
  }

  return { periods: targets, sa, sv, sd };
}

function logSpace(from, to, count) {
  const out = new Float64Array(count);
  const logFrom = Math.log(from);
  const logTo = Math.log(to);
  for (let i = 0; i < count; i += 1) {
    out[i] = Math.exp(logFrom + ((logTo - logFrom) * i) / (count - 1));
  }
  return out;
}

/** Arias intensity and the 5–95% significant duration. */
export function energy(waveform) {
  const rate = waveform.sampleRate;
  const samples = waveform.samples;
  if (rate <= 0 || samples.length < 2) {
    return { arias: 0, significantDuration: 0, cumulative: [] };
  }

  const dt = 1 / rate;
  const cumulative = new Float64Array(samples.length);
  let total = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const value = Number.isFinite(samples[i]) ? samples[i] : 0;
    total += value * value * dt;
    cumulative[i] = total;
  }

  const arias = (Math.PI / (2 * 9.80665)) * total;
  if (total <= 0) return { arias: 0, significantDuration: 0, cumulative };

  let start = 0;
  let end = samples.length - 1;
  for (let i = 0; i < samples.length; i += 1) {
    if (cumulative[i] >= 0.05 * total) { start = i; break; }
  }
  for (let i = samples.length - 1; i >= 0; i -= 1) {
    if (cumulative[i] <= 0.95 * total) { end = i; break; }
  }

  return {
    arias: Number.isFinite(arias) ? arias : 0,
    significantDuration: Math.max((end - start) * dt, 0),
    cumulative,
  };
}

/** STA/LTA — the trigger. */
export function staLta(waveform, { shortSeconds = 0.5, longSeconds = 10 } = {}) {
  const rate = waveform.sampleRate;
  const samples = waveform.samples;
  if (rate <= 0 || samples.length < 16) {
    return { ratio: new Waveform([], rate), peakRatio: 0, triggerIndex: null };
  }

  const shortWindow = Math.max(2, Math.round(shortSeconds * rate));
  const longWindow = Math.max(shortWindow * 2, Math.round(longSeconds * rate));

  const ratio = new Float64Array(samples.length);
  let peakRatio = 0;
  let shortSum = 0;
  let longSum = 0;

  for (let i = 0; i < samples.length; i += 1) {
    const value = Number.isFinite(samples[i]) ? samples[i] * samples[i] : 0;
    shortSum += value;
    longSum += value;
    if (i >= shortWindow) {
      const old = samples[i - shortWindow];
      shortSum -= Number.isFinite(old) ? old * old : 0;
    }
    if (i >= longWindow) {
      const old = samples[i - longWindow];
      longSum -= Number.isFinite(old) ? old * old : 0;
    }

    const shortAverage = shortSum / Math.min(i + 1, shortWindow);
    const longAverage = longSum / Math.min(i + 1, longWindow);
    const value2 = longAverage > 1e-18 ? shortAverage / longAverage : 0;
    ratio[i] = Number.isFinite(value2) ? value2 : 0;
    if (i > longWindow && ratio[i] > peakRatio) peakRatio = ratio[i];
  }

  let triggerIndex = null;
  for (let i = longWindow; i < ratio.length; i += 1) {
    if (ratio[i] >= 4) { triggerIndex = i; break; }
  }

  return { ratio: new Waveform(ratio, rate, 'ratio'), peakRatio, triggerIndex };
}
