// Validation against a physical shake table.
//
// The solver's prediction is drawn before the sweep runs and is never fitted
// afterwards. A curve adjusted to match the measurement would prove nothing;
// the disagreement is the interesting part.

import { store } from '../state.js';
import { el, panel, button, pill, notice, readout, readoutGrid, setChildren} from '../ui/dom.js';
import { drawLine, responsive } from '../ui/chart.js';
import { ShearBuilding, resonanceSweep, modes } from '../core/structures.js';
import { Haptics } from '../platform.js';

export function renderShakeTable({ onCleanup }) {
  const building = store.selectedBuilding;
  const model = ShearBuilding.from(building);
  const predicted = resonanceSweep(model, { from: 0.1, to: 4, points: 90 });
  const natural = modes(model)[0]?.frequency ?? 1;

  let measured = null;
  let running = false;
  let timer = null;

  const canvas = el('canvas.chart');
  const stats = el('.readout-grid');

  const draw = () => {
    const series = [{
      points: predicted.map((p) => [p.frequency, p.amplification]),
      colour: '#3ec9f0',
    }];
    if (measured) {
      series.push({
        points: measured.map((p) => [p.frequency, p.amplification]),
        colour: '#e6b85a',
        dashed: true,
      });
    }
    drawLine(canvas, series, {
      height: 230, xLabel: 'Driving frequency (Hz)', yLabel: 'Amplification',
      markers: [{ x: natural }],
    });

    const peak = (measured ?? predicted)
      .reduce((best, p) => (p.amplification > best.amplification ? p : best));
    setChildren(stats, [
      readout('Predicted resonance', natural.toFixed(3), { unit: 'Hz', large: true }),
      measured && readout('Measured peak', peak.frequency.toFixed(3), { unit: 'Hz' }),
      measured && readout('Disagreement',
        `${(Math.abs(peak.frequency - natural) / natural * 100).toFixed(1)}`, { unit: '%' }),
    ]);
  };

  const run = () => {
    if (running) return;
    running = true;
    Haptics.impact('Medium');
    measured = [];
    let index = 0;

    timer = setInterval(() => {
      if (!canvas.isConnected || index >= predicted.length) {
        clearInterval(timer);
        running = false;
        Haptics.notification('SUCCESS');
        draw();
        return;
      }
      const point = predicted[index];
      // The sweep runs against the node's own physics, so the two curves agree
      // closely. Against real hardware they would not, and that is the point.
      measured.push({
        frequency: point.frequency,
        amplification: point.amplification * (0.93 + Math.random() * 0.14),
      });
      index += 1;
      draw();
    }, 40);
  };

  const container = el('.stack', { style: { gap: '16px' } }, [
    panel('Validation', [
      el('p.body', {
        text: 'The table sweeps slowly from a low frequency to a high one while the node '
          + 'measures the model\'s response. The blue curve is what the solver predicted '
          + 'before the sweep started. Nothing is fitted afterwards.',
      }),
      pill('Simulated node', 'violet'),
    ], { iconName: 'slider' }),

    panel(null, [
      canvas,
      el('.chart-legend', {}, [
        el('span', { style: { color: '#3ec9f0' } }, [el('i'), 'Predicted']),
        el('span', { style: { color: '#e6b85a' } }, [el('i'), 'Measured']),
      ]),
      stats,
    ]),

    button(running ? 'Sweeping…' : 'Run a validation sweep', run,
      { block: true, iconName: 'play' }),

    notice('info', 'This is the simulated node',
      'The sweep runs against the node\'s own physics rather than a real table, so the '
      + 'two curves agree closely. Connected to real hardware they disagree, and the '
      + 'disagreement is what tells you the model is wrong.'),
  ]);

  requestAnimationFrame(draw);
  const stop = responsive(canvas, draw);
  onCleanup(() => { if (timer) clearInterval(timer); stop(); });
  return container;
}
