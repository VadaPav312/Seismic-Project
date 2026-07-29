// Several nodes, and what geometry buys you.
//
// One node gives distance from the P–S delay. Three give a location — but only
// if they are not in a straight line, which is the point this screen exists to
// make.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, button, emptyState, notice, pill,
} from '../ui/dom.js';
import { Haptics } from '../platform.js';

export function renderNetwork({ rerender }) {
  const nodes = store.get('observations').filter((o) => o.kind === 'networkNode');

  if (nodes.length === 0) {
    return emptyState({
      iconName: 'network',
      title: 'One node, so far',
      message: 'A single node can tell you how far away an earthquake was, from the delay '
        + 'between the first wave and the second. Three can tell you where it was. '
        + 'Simulate a network to see how the geometry changes the answer.',
      actionTitle: 'Simulate a five-node network',
      action: () => { simulate(5, false); rerender(); },
      secondaryTitle: 'Simulate three nodes in a line',
      secondaryAction: () => { simulate(3, true); rerender(); },
    });
  }

  const collinear = nodes.every((n) => Math.abs(n.y) < 0.5);
  const canvas = el('canvas.chart', { style: { borderRadius: 'var(--radius)' } });

  const container = el('.stack', { style: { gap: '16px' } }, [
    panel('Geometry', [
      canvas,
      readoutGrid([
        readout('Nodes', String(nodes.length)),
        readout('Location error', collinear ? '±∞ across' : '±0.8', { unit: 'km' }),
        readout('Depth', collinear ? 'unresolved' : '9.2', { unit: 'km' }),
      ]),
    ], { iconName: 'network', trailing: pill(collinear ? 'Collinear' : 'Well conditioned',
      collinear ? 'red' : 'green') }),

    collinear
      ? notice('warning', 'Three nodes in a line cannot locate anything',
        'Each node gives a circle of possible epicentres. Three circles centred on a '
        + 'straight line intersect in two mirrored points, and nothing in the data says '
        + 'which side the earthquake was on. Move one node off the line and the ambiguity '
        + 'disappears.')
      : notice('info', 'Why this works',
        'Each node measures the delay between the P wave and the S wave, which gives its '
        + 'distance from the epicentre — a circle. Three circles meet at one point. The '
        + 'more spread out the nodes, the sharper that intersection is.'),

    el('.stack', {}, [
      button('Simulate a five-node network', () => { simulate(5, false); rerender(); },
        { block: true }),
      button('Simulate three nodes in a line', () => { simulate(3, true); rerender(); },
        { kind: 'secondary', block: true }),
      button('Clear', () => {
        store.set('observations', store.get('observations').filter((o) => o.kind !== 'networkNode'));
        rerender();
      }, { kind: 'quiet', block: true }),
    ]),
  ]);

  requestAnimationFrame(() => drawGeometry(canvas, nodes, collinear));
  return container;
}

function simulate(count, collinear) {
  Haptics.selection();
  const nodes = Array.from({ length: count }, (_, i) => ({
    kind: 'networkNode',
    id: `node-${i}`,
    x: collinear ? (i - (count - 1) / 2) * 6 : Math.cos((i / count) * Math.PI * 2) * 8,
    y: collinear ? 0 : Math.sin((i / count) * Math.PI * 2) * 8,
    pDelay: 2.4 + Math.random() * 0.6,
  }));
  store.set('observations', [
    ...store.get('observations').filter((o) => o.kind !== 'networkNode'),
    ...nodes,
  ]);
}

function drawGeometry(canvas, nodes, collinear) {
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  const width = canvas.clientWidth || 320;
  const height = 260;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  const context = canvas.getContext('2d');
  context.setTransform(ratio, 0, 0, ratio, 0, 0);

  context.fillStyle = '#131519';
  context.fillRect(0, 0, width, height);

  const scale = Math.min(width, height) / 26;
  const cx = width / 2;
  const cy = height / 2;

  // The circle of possible epicentres around each node.
  for (const node of nodes) {
    const x = cx + node.x * scale;
    const y = cy + node.y * scale;
    context.strokeStyle = 'rgba(62,201,240,0.22)';
    context.lineWidth = 1;
    context.beginPath();
    context.arc(x, y, node.pDelay * 3.2 * scale, 0, Math.PI * 2);
    context.stroke();
  }

  for (const node of nodes) {
    const x = cx + node.x * scale;
    const y = cy + node.y * scale;
    context.fillStyle = '#3ec9f0';
    context.beginPath();
    context.arc(x, y, 6, 0, Math.PI * 2);
    context.fill();
  }

  context.fillStyle = collinear ? '#e0574f' : '#47c97e';
  context.beginPath();
  context.arc(cx, cy - (collinear ? 0 : 2), 8, 0, Math.PI * 2);
  context.fill();

  context.fillStyle = '#9aa2ad';
  context.font = '11px system-ui';
  context.fillText(collinear ? 'Two possible epicentres' : 'Epicentre', cx + 14, cy - 8);
}
