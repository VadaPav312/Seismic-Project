// The live seismograph.
//
// Three axes, the trigger ratio beneath, and the processing chain laid open so
// the user can see exactly what has been done to the signal between the sensor
// and the screen.
//
// The filtered window is prepared when the data changes, not when the view
// draws. Filtering thirty seconds of three axes through a fourth-order
// Butterworth on every frame is about nine thousand samples of IIR per redraw,
// and the chart then throws most of it away — a trace 390 pixels wide cannot
// show three thousand samples per axis.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, button, pill, icon, toggleRow, emptyState, setChildren,} from '../ui/dom.js';
import { drawTraces, responsive } from '../ui/chart.js';
import { butterworth } from '../core/signal.js';
import { Haptics } from '../platform.js';

export function renderMonitor({ node, onCleanup }) {
  let frozen = null;
  let windowSeconds = 30;
  let filtered = true;
  let axes = new Set(['x', 'y', 'z']);
  let prepared = null;

  const container = el('.stack', { style: { gap: '20px' } });
  const canvas = el('canvas.chart');
  const ratioCanvas = el('canvas.chart');
  const live = el('.readout-grid');

  const source = () => frozen ?? store.get('node')?.recent ?? null;

  /** Filters and windows once per data change. */
  const prepare = () => {
    const record = source();
    if (!record || record.count < 8) { prepared = null; return; }

    const window = record.slice(
      Math.max(record.duration - windowSeconds, 0), record.duration,
    );
    if (!filtered || window.count < 32) { prepared = window; return; }

    const options = {
      kind: 'bandpass', order: 4, lowCutoff: 0.1,
      highCutoff: Math.min(25, window.sampleRate / 2.5),
    };
    prepared = {
      x: butterworth(window.x, options),
      y: butterworth(window.y, options),
      z: butterworth(window.z, options),
      duration: window.duration,
      count: window.count,
      sampleRate: window.sampleRate,
    };
  };

  const drawAll = () => {
    if (!prepared) return;
    const channels = [];
    if (axes.has('x')) {
      channels.push({ samples: prepared.x.samples, colour: '#3ec9f0', label: 'N–S' });
    }
    if (axes.has('y')) {
      channels.push({ samples: prepared.y.samples, colour: '#b18cf0', label: 'E–W' });
    }
    if (axes.has('z')) {
      channels.push({ samples: prepared.z.samples, colour: '#e6b85a', label: 'Vertical', dashed: true });
    }
    drawTraces(canvas, channels, {
      height: 210, unitLabel: 'm/s²', durationSeconds: prepared.duration,
    });

    const ratio = store.get('node')?.ratio;
    if (ratio?.samples?.length > 8) {
      drawTraces(ratioCanvas, [
        { samples: ratio.samples.slice(-Math.round(windowSeconds * 100)), colour: '#47c97e' },
      ], { height: 66, unitLabel: '' });
    }
  };

  const snapshot = store.get('node');
  if (!snapshot || snapshot.recent.count < 8) {
    // Subscribing here is what stops this being a dead end. This screen can be
    // rendered before the node's first tick — at launch it always is — and
    // without a subscription the empty state would stay on screen for ever
    // while data streamed past behind it.
    const waiting = el('div');
    const unsubscribe = store.subscribe('node', (snap) => {
      if (!waiting.isConnected) { unsubscribe(); return; }
      if ((snap?.recent.count ?? 0) > 8) {
        unsubscribe();
        window.seismic.render();
      }
    });
    onCleanup(unsubscribe);
    waiting.append(emptyState({
      iconName: 'wave',
      title: 'Waiting for data',
      message: 'The node streams continuously once connected. If nothing appears within '
        + 'a few seconds, check the connection on the node screen — or use the simulated '
        + 'node, which needs no hardware.',
      actionTitle: 'Use the simulated node',
      action: () => {
        // Clearing the freeze matters: freezing while the trace was empty would
        // otherwise latch an empty record in, and since the frozen record wins,
        // the screen would stay on this empty state no matter how much data
        // arrived — which makes this button look broken when it worked.
        frozen = null;
        node.connect();
        window.seismic.render();
      },
    }));
    return waiting;
  }

  // ── Traces ───────────────────────────────────────────────────────────────
  const freezeButton = el('button.btn.btn-secondary', {
    type: 'button',
    dataset: { tour: 'freeze' },
    on: {
      click: () => {
        Haptics.selection();
        if (frozen) {
          frozen = null;
        } else {
          const current = store.get('node')?.recent;
          // Only freeze something worth looking at.
          frozen = current && current.count > 8 ? current : null;
        }
        window.seismic.render();
      },
    },
  }, [icon(frozen ? 'play' : 'pause', { size: 18 }), frozen ? 'Live' : 'Freeze']);

  container.append(panel('Ground motion', [
    el('.chart-legend', {}, [
      el('span', { style: { color: '#3ec9f0' } }, [el('i'), 'N–S']),
      el('span', { style: { color: '#b18cf0' } }, [el('i'), 'E–W']),
      el('span', { style: { color: '#e6b85a' } }, [el('i'), 'Vertical']),
    ]),
    canvas,
    el('.panel-label', {}, ['STA / LTA ratio · triggers at 4.0']),
    ratioCanvas,
  ], {
    iconName: 'wave',
    trailing: el('.hstack', {}, [frozen && pill('Frozen', 'amber'), freezeButton]),
  }));

  // ── Controls ─────────────────────────────────────────────────────────────
  const axisButtons = [
    ['x', 'North–South'], ['y', 'East–West'], ['z', 'Vertical'],
  ].map(([key, label]) => {
    const active = axes.has(key);
    return el('button.btn.btn-secondary', {
      type: 'button',
      style: active ? { borderColor: 'var(--accent)', color: 'var(--accent)' } : {},
      on: {
        click: () => {
          if (axes.has(key)) axes.delete(key); else axes.add(key);
          // Never leave the chart with nothing on it.
          if (axes.size === 0) axes.add(key);
          window.seismic.render();
        },
      },
    }, label);
  });

  const windowSlider = el('input', {
    type: 'range', min: '5', max: '60', step: '5', value: String(windowSeconds),
  });
  const windowValue = el('.readout-value', { text: `${windowSeconds} s` });
  windowSlider.addEventListener('input', () => {
    windowSeconds = Number(windowSlider.value);
    windowValue.textContent = `${windowSeconds} s`;
    prepare();
    drawAll();
  });

  container.append(panel('View', [
    el('.hstack', { style: { flexWrap: 'wrap' } }, axisButtons),
    el('.toggle-row', {}, [el('.headline', { text: 'Window' }), windowValue]),
    windowSlider,
    toggleRow('Bandpass filter', '0.1–25 Hz. Removes drift and electrical hash.',
      filtered, (value) => {
        filtered = value;
        prepare();
        drawAll();
      }),
  ]));

  // ── Live values ──────────────────────────────────────────────────────────
  container.append(panel('Live values', [live], { iconName: 'scope' }));

  // ── Processing chain ─────────────────────────────────────────────────────
  container.append(panel('What has been done to this signal', [
    ...[
      ['Mean removed', 'Every accelerometer has a bias. It is subtracted first.'],
      ['Linear trend removed', 'Sensors drift with temperature. An uncorrected drift '
        + 'integrates into a displacement that grows without bound.'],
      ['Bandpass 0.1–25 Hz', 'Below 0.1 Hz is drift; above 25 Hz is nothing a building '
        + 'responds to. Applied forwards and backwards so the phase is unchanged — which '
        + 'matters because a phase shift moves the P-wave arrival the distance estimate '
        + 'is built on.'],
      ['Decimated for display', 'The screen cannot resolve three thousand samples across '
        + '390 pixels, so the trace is reduced by min/max pairs — which keeps the '
        + 'envelope rather than dropping spikes.'],
    ].map(([title, detail]) => el('.stack-tight', {}, [
      el('.headline', { text: title }),
      el('p.caption', { text: detail }),
    ])),
  ], { iconName: 'analysis' }));

  // ── Live subscription ────────────────────────────────────────────────────
  prepare();
  const stopResize = responsive(canvas, drawAll);

  const unsubscribe = store.subscribe('node', (snap) => {
    if (!container.isConnected || !snap) return;
    if (!frozen) prepare();
    drawAll();

    const peaks = {
      x: snap.recent.x.peak, y: snap.recent.y.peak, z: snap.recent.z.peak,
    };
    setChildren(live, [
      readout('Peak N–S', peaks.x.toFixed(4), { unit: 'm/s²' }),
      readout('Peak E–W', peaks.y.toFixed(4), { unit: 'm/s²' }),
      readout('Peak vertical', peaks.z.toFixed(4), { unit: 'm/s²' }),
      readout('Buffered', String(snap.bufferedSamples), { unit: 'samples' }),
    ]);
  });

  onCleanup(() => { unsubscribe(); stopResize(); });
  return container;
}
