// The introduction.
//
// The target is that somebody reaches a working simulation of a real building
// within three minutes of first launch, having understood *why* a building's
// rhythm changes when it is damaged. So the science comes first, as one animated
// idea rather than a wall of text.
//
// There is no Skip. Every individual step's own action is optional and the whole
// flow is five taps, so a skip button would only be a second way to leave that
// competes with Continue for the same space — which is exactly how it used to
// draw straight through it.

import { store } from '../state.js';
import { el, button, icon, notice, setChildren} from '../ui/dom.js';
import { Haptics } from '../platform.js';
import { crossCheckedPeriod } from '../core/spectrum.js';

export function renderOnboarding({ node, onDone }) {
  let step = 0;
  const total = 5;
  const container = el('main#screen');

  const next = () => {
    Haptics.selection();
    if (step === total - 1) {
      store.set('didCompleteOnboarding', true);
      onDone();
      return;
    }
    step += 1;
    draw();
  };

  const back = () => {
    if (step === 0) return;
    Haptics.selection();
    step -= 1;
    draw();
  };

  const draw = () => {
    setChildren(container, []);

    const progress = el('.tour-progress', { style: { padding: '0 16px' } },
      Array.from({ length: total }, (_, i) => el(`i${i <= step ? '.done' : ''}`)));

    const body = [
      welcomeStep, scienceStep, connectionStep, measurementStep, importStep,
    ][step]({ node, redraw: draw });

    container.append(el('.screen-inner', { style: { minHeight: '100%' } }, [
      progress,
      el('div', { style: { flex: '1' } }, [body]),

      // One bordered bar holding both controls, so they read as the same kind
      // of thing and neither can overlap the other.
      el('.button-bar', {}, [
        el('button.btn.btn-secondary', {
          type: 'button',
          on: { click: back },
          disabled: step === 0,
          // Kept in the layout rather than removed, so Continue does not jump
          // sideways the moment you advance.
          style: step === 0 ? { opacity: '0.35' } : {},
        }, 'Back'),
        el('button.btn.btn-primary', {
          type: 'button', on: { click: next },
        }, step === total - 1 ? 'Start using Seismic' : 'Continue'),
      ]),
    ]));
  };

  draw();
  return container;
}

// ── Steps ──────────────────────────────────────────────────────────────────

function welcomeStep() {
  return el('.stack', {
    style: { alignItems: 'center', textAlign: 'center', paddingTop: '8vh', gap: '20px' },
  }, [
    icon('wave', { size: 56, stroke: 1.2 }),
    el('h1', {
      text: 'SEISMIC',
      style: { fontSize: '1.9rem', fontWeight: '600', letterSpacing: '0.32em' },
    }),
    el('p.body', {
      text: 'After a major earthquake there are never enough engineers. People sleep '
        + 'outside safe buildings for weeks, while others walk back into damaged ones.',
      style: { maxWidth: '34ch' },
    }),
    el('p.body', {
      text: 'Seismic gives every building a continuous, evidence-backed assessment — '
        + 'and lets a neighbourhood share it.',
      style: { maxWidth: '34ch' },
    }),
  ]);
}

/**
 * The one idea the whole app rests on, animated rather than described.
 *
 * A damaged building is a softer building, and a softer building sways more
 * slowly. That is the entire principle, and seeing two buildings sway at
 * different rates teaches it faster than any paragraph.
 */
function scienceStep() {
  const canvas = el('canvas', { style: { width: '100%', height: '260px' } });
  const container = el('.stack', { style: { gap: '18px' } }, [
    el('h2.title', { text: 'A damaged building sways more slowly' }),
    el('p.body', {
      text: 'Stiffness is what makes a building spring back. Damage takes stiffness '
        + 'away, and a softer structure has a longer natural rhythm — the same way a '
        + 'looser guitar string sounds a lower note.',
    }),
    canvas,
    el('.chart-legend', {}, [
      el('span', { style: { color: 'var(--accent)' } }, [el('i'), 'Healthy · 0.9 s']),
      el('span', { style: { color: 'var(--verdict-amber)' } }, [el('i'), 'Damaged · 1.15 s']),
    ]),
    el('p.body', {
      text: 'Seismic measures that rhythm continuously. A shift after an earthquake is '
        + 'physical evidence of damage, visible long before a crack is.',
    }),
  ]);

  requestAnimationFrame(() => animateSway(canvas));
  return container;
}

function animateSway(canvas) {
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  const width = canvas.clientWidth || 320;
  const height = 260;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  const context = canvas.getContext('2d');
  context.setTransform(ratio, 0, 0, ratio, 0, 0);

  const started = performance.now();
  const draw = () => {
    if (!canvas.isConnected) return;
    const t = (performance.now() - started) / 1000;
    context.clearRect(0, 0, width, height);

    drawTower(context, width * 0.3, height, t, 0.9, '#3ec9f0', false);
    drawTower(context, width * 0.7, height, t, 1.15, '#e6b85a', true);

    requestAnimationFrame(draw);
  };
  draw();
}

function drawTower(context, cx, height, t, period, colour, damaged) {
  const storeys = 8;
  const storeyHeight = (height - 42) / storeys;
  const sway = Math.sin((2 * Math.PI * t) / period) * 16;

  for (let i = 0; i < storeys; i += 1) {
    const fraction = (i + 1) / storeys;
    const offset = sway * fraction * fraction;
    const y = height - 24 - (i + 1) * storeyHeight;
    const w = 54;

    context.fillStyle = damaged && i < 2 ? 'rgba(224,87,79,0.35)' : 'rgba(255,255,255,0.07)';
    context.strokeStyle = colour;
    context.lineWidth = 1.4;
    context.beginPath();
    context.roundRect(cx - w / 2 + offset, y, w, storeyHeight - 3, 2);
    context.fill();
    context.stroke();
  }

  context.strokeStyle = 'rgba(255,255,255,0.18)';
  context.lineWidth = 2;
  context.beginPath();
  context.moveTo(cx - 44, height - 22);
  context.lineTo(cx + 44, height - 22);
  context.stroke();
}

function connectionStep({ node, redraw }) {
  const connected = node?.isLive;
  const stages = [
    ['Turn on Bluetooth', 'The node talks to your phone over Bluetooth Low Energy.'],
    ['Scan for the node', 'It advertises as soon as it has power.'],
    ['Connect', 'Pairing persists — it reconnects on its own from then on.'],
    ['Confirm data is streaming', 'You should see a live trace within a second or two.'],
    ['Run a self-test', 'Every sensor and actuator is exercised once.'],
    ['Calibrate the baseline', 'Measures the building while it is quiet. This is what '
      + 'future assessments are compared against.'],
  ];

  return el('.stack', { style: { gap: '16px' } }, [
    el('h2.title', { text: 'Connecting your node' }),
    el('p.body', {
      text: 'Six steps. If you do not have hardware, the simulated node does all of '
        + 'this and behaves identically — you can complete the whole tutorial without it.',
    }),
    el('.stack', {}, stages.map(([title, detail], index) => el('.hstack', {
      style: { alignItems: 'flex-start', gap: '12px' },
    }, [
      el('div', {
        style: {
          width: '26px', height: '26px', borderRadius: '50%', flex: 'none',
          display: 'grid', placeItems: 'center',
          background: connected ? 'var(--accent)' : 'var(--surface-highest)',
          color: connected ? 'var(--accent-text)' : 'var(--text-secondary)',
        },
      }, [connected ? icon('check', { size: 14 }) : el('span.caption', { text: index + 1 })]),
      el('.stack-tight', {}, [
        el('.headline', { text: title }),
        el('p.caption', { text: detail }),
      ]),
    ]))),

    connected
      ? notice('info', 'Connected',
        'The simulated node is streaming physically realistic data. Everything from '
        + 'here works exactly as it would with hardware.')
      : button('Use the simulated node', () => {
        node?.connect();
        node?.calibrateBaseline();
        Haptics.notification('SUCCESS');
        redraw();
      }, { block: true, iconName: 'sensor' }),
  ]);
}

function measurementStep({ node, redraw }) {
  const state = node?.baselineCalibrated ? 1 : 0;
  const record = node?.record(20);
  const measured = record && record.count > 200 ? crossCheckedPeriod(record.x) : null;

  return el('.stack', { style: { gap: '16px' } }, [
    el('h2.title', { text: 'Your first measurement' }),
    el('p.body', {
      text: 'The building is always moving — wind, traffic, people. That motion is tiny '
        + 'and continuous, and it is enough to measure a period from. No earthquake '
        + 'is required to establish a baseline.',
    }),

    measured?.consensus
      ? el('.panel', {}, [
        el('.panel-label', {}, ['Measured now']),
        el('.readout-value.large', {}, [
          measured.consensus.toFixed(3), el('span.unit', { text: 's' }),
        ]),
        el('p.caption', { text: measured.note }),
      ])
      : notice('info', 'Listening',
        'Give the node a few seconds of ambient motion and a period will appear here.'),

    button('Introduce simulated damage', () => {
      node?.introduceDamage();
      Haptics.impact('Heavy');
      redraw();
    }, { kind: 'secondary', block: true }),

    button('Restore the building', () => {
      node?.restore();
      redraw();
    }, { kind: 'quiet', block: true }),

    el('p.body', {
      text: 'Damage the model and watch the number above lengthen. That shift is the '
        + 'entire basis of every assessment this app makes.',
    }),
    state === 0 && el('p.caption', { text: 'Tip: connect the node on the previous step first.' }),
  ]);
}

function importStep() {
  const count = store.get('buildings').length;
  return el('.stack', { style: { gap: '16px' } }, [
    el('h2.title', { text: 'Any building in the world' }),
    el('p.body', {
      text: 'Type a name or an address and Seismic finds its height, storey count, '
        + 'material and mapped outline, works out how it should behave, and builds it '
        + 'in 3D — with every fact showing where it came from.',
    }),
    el('.panel', {}, [
      el('.panel-label', {}, ['Already in your library']),
      el('.readout-value.large', { text: String(count) }),
      el('p.caption', {
        text: 'Ten real buildings are bundled, each chosen to teach something '
          + 'different — a soft storey, an unreinforced hall, a base-isolated tower.',
      }),
    ]),
    notice('info', 'Nothing needs a key',
      'Every capability has a path that works offline with no account and no hardware. '
      + 'Keys and a node upgrade those paths; they never unlock them.'),
  ]);
}
