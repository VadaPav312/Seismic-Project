// Analysis: the spectrum, the modes, and how confident the measurement is.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, segmented, toggleRow, emptyState, notice, pill, setChildren,} from '../ui/dom.js';
import { drawLine, responsive } from '../ui/chart.js';
import {
  welch, konnoOhmachi, peaks, crossCheckedPeriod, halfPowerDamping,
  responseSpectrum, energy,
} from '../core/spectrum.js';

export function renderAnalysis({ onCleanup }) {
  const snapshot = store.get('node');
  // Twenty seconds, for the same reason Home needs it: a shorter record cannot
  // resolve the low-frequency mode this whole screen is about.
  if (!snapshot || snapshot.recent.count < snapshot.recent.sampleRate * 20) {
    return emptyState({
      iconName: 'analysis',
      title: 'Not enough data yet',
      message: 'A spectrum needs about twenty seconds of continuous motion to resolve a '
        + 'building\'s mode — a shorter record cannot see it at all. Leave this screen '
        + 'open and it will fill in.',
    });
  }

  let smoothing = true;
  let windowName = 'hann';
  const container = el('.stack', { style: { gap: '18px' } });

  const spectrumCanvas = el('canvas.chart');
  const responseCanvas = el('canvas.chart');
  const modesSlot = el('.stack');
  const checkSlot = el('.stack');

  const record = snapshot.recent;

  const compute = () => {
    const raw = welch(record.x, { window: windowName });
    const spectrum = smoothing ? konnoOhmachi(raw) : raw;
    const found = peaks(spectrum);
    const check = crossCheckedPeriod(record.x);
    const damping = found[0] ? halfPowerDamping(spectrum, found[0]) : null;
    return { spectrum, found, check, damping };
  };

  const draw = () => {
    const { spectrum, found, check, damping } = compute();

    drawLine(spectrumCanvas, [{
      points: Array.from(spectrum.frequencies)
        .map((f, i) => [f, spectrum.power[i]])
        .filter(([f]) => f > 0.05 && f < 15),
      colour: '#3ec9f0',
    }], {
      height: 220, logY: true, xLabel: 'Frequency (Hz)', yLabel: 'Power',
      markers: found.slice(0, 1).map((p) => ({ x: p.frequency })),
    });

    setChildren(modesSlot, [
      ...found.slice(0, 4).map((peak, index) => el('.hstack', {}, [
        el('.stack-tight', { style: { flex: '1' } }, [
          el('.headline', { text: `Mode ${index + 1}` }),
          el('.caption', { text: `prominence ${peak.prominence.toFixed(2)}` }),
        ]),
        el('.readout-value', {}, [
          peak.frequency.toFixed(3), el('span.unit', { text: 'Hz' }),
        ]),
        el('.readout-value', {}, [
          peak.period.toFixed(3), el('span.unit', { text: 's' }),
        ]),
      ])),
      found.length === 0 && el('p.caption', { text: 'No peak stands clear of the noise yet.' }),
    ]);

    setChildren(checkSlot, [
      readoutGrid([
        readout('Consensus period', check.consensus ? check.consensus.toFixed(3) : '—',
          { unit: 's', large: true }),
        readout('Agreement', Math.round(check.agreement * 100), { unit: '%' }),
        readout('Damping', damping ? (damping * 100).toFixed(1) : '—', { unit: '%' }),
      ]),
      el('.stack-tight', {}, check.estimates.map((estimate) => el('.hstack', {}, [
        el('.body', { text: estimate.method, style: { flex: '1' } }),
        el('.mono', { text: `${estimate.period.toFixed(3)} s` }),
      ]))),
      el('p.caption', { text: check.note }),
    ]);

    const spectrumResponse = responseSpectrum(record.x);
    drawLine(responseCanvas, [{
      points: Array.from(spectrumResponse.periods).map((p, i) => [p, spectrumResponse.sa[i]]),
      colour: '#e6b85a',
    }], { height: 190, logX: true, xLabel: 'Period (s)', yLabel: 'Sa (m/s²)' });
  };

  container.append(
    panel('Spectrum', [
      el('.chart-legend', {}, [pill(`Welch · ${windowName}`, 'accent')]),
      spectrumCanvas,
      toggleRow('Konno-Ohmachi smoothing',
        'Constant width on a log axis, so a peak at 8 Hz is smoothed as much as one at '
        + '1 Hz — which linear smoothing gets wrong.',
        smoothing, (value) => { smoothing = value; draw(); }),
      segmented([
        { value: 'none', label: 'None' },
        { value: 'hann', label: 'Hann' },
        { value: 'hamming', label: 'Hamming' },
        { value: 'blackman', label: 'Blackman' },
      ], windowName, (value) => {
        windowName = value;
        container.querySelectorAll('.segmented button').forEach((node, index) => {
          node.setAttribute('aria-selected',
            String(['none', 'hann', 'hamming', 'blackman'][index] === value));
        });
        draw();
      }),
      el('p.caption', {
        text: 'A window is applied before the transform because a finite record has hard '
          + 'ends, and hard ends smear energy across every frequency.',
      }),
    ], { iconName: 'analysis' }),

    panel('Identified modes', [modesSlot], { iconName: 'wave' }),

    panel('Cross-check', [
      checkSlot,
      el('p.caption', {
        text: 'Three independent methods, and an honest account of whether they agree. '
          + 'One method agreeing with itself is not corroboration, so a single estimate '
          + 'is capped well below full confidence.',
      }),
    ], { iconName: 'scope' }),

    panel('Response spectrum', [
      responseCanvas,
      el('p.caption', {
        text: 'The peak response of a whole family of oscillators. It answers "how hard '
          + 'did this shaking hit a building with THIS period", which is more useful '
          + 'than how strong the shaking was.',
      }),
    ], { iconName: 'analysis' }),

    (() => {
      const e = energy(record.x);
      return panel('Energy', [
        readoutGrid([
          readout('Arias intensity', e.arias.toFixed(4), { unit: 'm/s' }),
          readout('Significant duration', e.significantDuration.toFixed(1), { unit: 's' }),
        ]),
        el('p.caption', {
          text: 'The 5–95% duration, not the total. The tails of a record are noise, and '
            + 'including them makes every event look longer than it was.',
        }),
      ], { iconName: 'bolt' });
    })(),
  );

  requestAnimationFrame(draw);
  const stop = responsive(spectrumCanvas, draw);
  onCleanup(stop);
  return container;
}
