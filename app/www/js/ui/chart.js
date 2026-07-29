// Charts, drawn to a canvas.
//
// Canvas rather than SVG because these are live: the ground-motion trace is
// redrawn continuously, and a few thousand SVG path nodes replaced at 20 Hz
// makes the whole interface stutter. Canvas draws the same picture with one
// element and no layout cost.
//
// Every chart decimates before drawing. A trace 390 CSS pixels wide cannot show
// three thousand samples, so sending them all to the GPU is work whose only
// visible effect is heat.

const AXIS_COLOUR = 'rgba(255,255,255,0.09)';
const TEXT_COLOUR = '#6b7280';

function setup(canvas, height) {
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  const width = canvas.clientWidth || canvas.parentElement?.clientWidth || 320;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  canvas.style.height = `${height}px`;

  const context = canvas.getContext('2d');
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.clearRect(0, 0, width, height);
  return { context, width, height };
}

/**
 * Reduces a series to at most `budget` points, keeping both extremes of each
 * bucket in the order they occurred.
 *
 * Plain subsampling would drop spikes entirely depending on where they fell,
 * and on a seismograph the spike is the whole point.
 */
function decimate(samples, budget) {
  const n = samples.length;
  if (n <= budget) return Array.from(samples);
  const bucket = Math.ceil(n / (budget / 2));

  const out = [];
  for (let start = 0; start < n; start += bucket) {
    const end = Math.min(start + bucket, n);
    let low = Infinity;
    let high = -Infinity;
    let lowAt = start;
    let highAt = start;
    for (let i = start; i < end; i += 1) {
      const value = samples[i];
      if (!Number.isFinite(value)) continue;
      if (value < low) { low = value; lowAt = i; }
      if (value > high) { high = value; highAt = i; }
    }
    if (low === Infinity) { out.push(0, 0); continue; }
    if (lowAt <= highAt) out.push(low, high);
    else out.push(high, low);
  }
  return out;
}

/** The live seismograph: several channels sharing one vertical scale. */
export function drawTraces(canvas, channels, {
  height = 200, unitLabel = '', durationSeconds = null,
} = {}) {
  const { context, width } = setup(canvas, height);
  const padding = { left: 6, right: 6, top: 8, bottom: 18 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;

  // One shared scale across all channels, because the comparison between axes
  // is the information. Independent scales would make a still axis look as
  // active as a shaking one.
  let peak = 0;
  const prepared = channels.map((channel) => {
    const points = decimate(channel.samples, Math.max(plotWidth * 2, 120));
    for (const value of points) {
      const magnitude = Math.abs(value);
      if (Number.isFinite(magnitude) && magnitude > peak) peak = magnitude;
    }
    return { ...channel, points };
  });
  if (!(peak > 0)) peak = 1;
  const scale = plotHeight / 2 / (peak * 1.12);

  context.strokeStyle = AXIS_COLOUR;
  context.lineWidth = 1;
  for (let i = 0; i <= 4; i += 1) {
    const y = padding.top + (plotHeight * i) / 4;
    context.beginPath();
    context.moveTo(padding.left, y);
    context.lineTo(width - padding.right, y);
    context.stroke();
  }

  const midline = padding.top + plotHeight / 2;
  for (const channel of prepared) {
    if (channel.points.length < 2) continue;
    context.strokeStyle = channel.colour;
    context.lineWidth = channel.width ?? 1.4;
    if (channel.dashed) context.setLineDash([4, 3]);
    context.beginPath();
    for (let i = 0; i < channel.points.length; i += 1) {
      const x = padding.left + (plotWidth * i) / (channel.points.length - 1);
      const y = midline - channel.points[i] * scale;
      if (i === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    }
    context.stroke();
    context.setLineDash([]);
  }

  context.fillStyle = TEXT_COLOUR;
  context.font = '11px ui-monospace, monospace';
  context.textBaseline = 'top';
  context.fillText(`±${peak.toPrecision(2)} ${unitLabel}`.trim(), padding.left, height - 15);
  if (durationSeconds) {
    const label = `${durationSeconds.toFixed(0)} s`;
    context.fillText(label, width - padding.right - context.measureText(label).width,
      height - 15);
  }
}

/** A line chart with real axes, for spectra and response curves. */
export function drawLine(canvas, series, {
  height = 220, xLabel = '', yLabel = '', logY = false, logX = false,
  markers = [],
} = {}) {
  const { context, width } = setup(canvas, height);
  const padding = { left: 8, right: 46, top: 12, bottom: 30 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;

  const all = series.flatMap((s) => s.points);
  if (all.length < 2) {
    context.fillStyle = TEXT_COLOUR;
    context.font = '12px system-ui';
    context.fillText('Not enough data yet', padding.left, height / 2);
    return;
  }

  let minX = Infinity; let maxX = -Infinity;
  let minY = Infinity; let maxY = -Infinity;
  for (const [x, y] of all) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  if (!(maxX > minX)) maxX = minX + 1;

  // A log axis cannot show zero, and a spectrum's floor is often exactly zero.
  // Clamping to a small positive floor is honest here: it says "below this the
  // measurement means nothing", which is true.
  const floor = logY ? Math.max(maxY * 1e-6, Number.MIN_VALUE) : 0;
  const ty = (value) => {
    const v = logY ? Math.log10(Math.max(value, floor)) : value;
    const lo = logY ? Math.log10(Math.max(minY, floor)) : Math.min(minY, 0);
    const hi = logY ? Math.log10(Math.max(maxY, floor * 10)) : maxY;
    const span = hi - lo || 1;
    return padding.top + plotHeight - ((v - lo) / span) * plotHeight;
  };
  const tx = (value) => {
    const v = logX ? Math.log10(Math.max(value, 1e-6)) : value;
    const lo = logX ? Math.log10(Math.max(minX, 1e-6)) : minX;
    const hi = logX ? Math.log10(Math.max(maxX, 1e-6)) : maxX;
    const span = hi - lo || 1;
    return padding.left + ((v - lo) / span) * plotWidth;
  };

  context.strokeStyle = AXIS_COLOUR;
  context.lineWidth = 1;
  context.fillStyle = TEXT_COLOUR;
  context.font = '10px ui-monospace, monospace';
  context.textBaseline = 'middle';

  for (let i = 0; i <= 4; i += 1) {
    const y = padding.top + (plotHeight * i) / 4;
    context.beginPath();
    context.moveTo(padding.left, y);
    context.lineTo(width - padding.right, y);
    context.stroke();

    const fraction = 1 - i / 4;
    let value;
    if (logY) {
      const lo = Math.log10(Math.max(minY, floor));
      const hi = Math.log10(Math.max(maxY, floor * 10));
      value = 10 ** (lo + (hi - lo) * fraction);
    } else {
      value = Math.min(minY, 0) + (maxY - Math.min(minY, 0)) * fraction;
    }
    const label = logY ? value.toExponential(0) : formatTick(value);
    context.fillText(label, width - padding.right + 5, y);
  }

  for (const marker of markers) {
    const x = tx(marker.x);
    context.strokeStyle = marker.colour ?? '#e6b85a';
    context.setLineDash([4, 3]);
    context.beginPath();
    context.moveTo(x, padding.top);
    context.lineTo(x, padding.top + plotHeight);
    context.stroke();
    context.setLineDash([]);
  }

  for (const s of series) {
    if (s.points.length < 2) continue;
    context.strokeStyle = s.colour;
    context.lineWidth = s.width ?? 2;
    if (s.dashed) context.setLineDash([5, 4]);
    context.beginPath();
    let started = false;
    for (const [x, y] of s.points) {
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      const px = tx(x);
      const py = ty(y);
      if (!started) { context.moveTo(px, py); started = true; } else context.lineTo(px, py);
    }
    context.stroke();
    context.setLineDash([]);
  }

  context.textBaseline = 'alphabetic';
  context.fillStyle = TEXT_COLOUR;
  context.font = '10px ui-monospace, monospace';
  for (let i = 0; i <= 3; i += 1) {
    const fraction = i / 3;
    const value = logX
      ? 10 ** (Math.log10(Math.max(minX, 1e-6))
        + (Math.log10(Math.max(maxX, 1e-6)) - Math.log10(Math.max(minX, 1e-6))) * fraction)
      : minX + (maxX - minX) * fraction;
    context.fillText(formatTick(value), tx(value) - 8, height - 14);
  }
  if (xLabel) {
    context.font = '11px system-ui';
    context.fillText(xLabel, padding.left, height - 2);
  }
  if (yLabel) {
    context.font = '11px system-ui';
    context.fillText(yLabel, width - padding.right + 2, padding.top - 2);
  }
}

/** Bars, for damage states and fragility. */
export function drawBars(canvas, bars, { height = 150 } = {}) {
  const { context, width } = setup(canvas, height);
  const padding = { left: 6, right: 6, top: 10, bottom: 26 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  const maximum = Math.max(...bars.map((b) => b.value), 1e-9);

  const slot = plotWidth / bars.length;
  bars.forEach((bar, index) => {
    const barHeight = Math.max((bar.value / maximum) * plotHeight, 2);
    const x = padding.left + slot * index + slot * 0.18;
    const w = slot * 0.64;
    const y = padding.top + plotHeight - barHeight;

    context.fillStyle = bar.colour;
    context.beginPath();
    context.roundRect(x, y, w, barHeight, 4);
    context.fill();

    context.fillStyle = TEXT_COLOUR;
    context.font = '10px system-ui';
    context.textAlign = 'center';
    context.fillText(bar.label, x + w / 2, height - 12);
    if (bar.caption) context.fillText(bar.caption, x + w / 2, height - 1);
  });
  context.textAlign = 'left';
}

/** A spectrogram: time across, frequency up, energy as colour. */
export function drawSpectrogram(canvas, columns, { height = 180 } = {}) {
  const { context, width } = setup(canvas, height);
  if (!columns.length) return;

  const columnWidth = width / columns.length;
  const bins = columns[0].length;
  const cellHeight = height / bins;

  let maximum = 0;
  for (const column of columns) {
    for (const value of column) if (value > maximum) maximum = value;
  }
  if (!(maximum > 0)) return;

  for (let c = 0; c < columns.length; c += 1) {
    for (let b = 0; b < bins; b += 1) {
      const intensity = Math.min(Math.log10(1 + (columns[c][b] / maximum) * 999) / 3, 1);
      context.fillStyle = heat(intensity);
      context.fillRect(c * columnWidth, height - (b + 1) * cellHeight,
        columnWidth + 0.5, cellHeight + 0.5);
    }
  }
}

/** Dark blue through cyan to amber. Perceptually monotonic in lightness. */
function heat(t) {
  const clamped = Math.min(Math.max(t, 0), 1);
  if (clamped < 0.5) {
    const k = clamped / 0.5;
    return `rgb(${Math.round(10 + 30 * k)}, ${Math.round(18 + 130 * k)}, ${Math.round(40 + 150 * k)})`;
  }
  const k = (clamped - 0.5) / 0.5;
  return `rgb(${Math.round(40 + 190 * k)}, ${Math.round(148 + 36 * k)}, ${Math.round(190 - 120 * k)})`;
}

function formatTick(value) {
  if (!Number.isFinite(value)) return '';
  if (Math.abs(value) >= 1000 || (Math.abs(value) < 0.01 && value !== 0)) {
    return value.toExponential(0);
  }
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(Math.abs(value) < 1 ? 2 : 1);
}

/**
 * Redraws on resize, and stops when the canvas leaves the document.
 *
 * The observer holds a reference to the callback, which holds the screen's
 * state; without disconnecting it, every screen ever visited stays alive and
 * keeps redrawing offscreen.
 */
export function responsive(canvas, draw) {
  draw();
  const observer = new ResizeObserver(() => {
    if (!canvas.isConnected) { observer.disconnect(); return; }
    draw();
  });
  observer.observe(canvas);
  return () => observer.disconnect();
}
