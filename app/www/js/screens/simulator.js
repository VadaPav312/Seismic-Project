// The simulator: your building, shaken by a real earthquake.
//
// The solve happens once, off the render path; playback then only reads frames
// out of the result. Solving inside the animation loop would recompute the
// entire time history sixty times a second to show one frame of it.
//
// The sway is exaggerated because real drift is a fraction of a per cent and
// would be invisible at true scale. The app says by how much rather than
// quietly lying about the magnitude.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, button, pill, icon, segmented, notice, setChildren,} from '../ui/dom.js';
import { BuildingScene } from '../ui/scene.js';
import { ShearBuilding, solve, modes, fundamentalPeriod } from '../core/structures.js';
import { Waveform } from '../core/signal.js';
import { Haptics } from '../platform.js';
import { VERDICTS } from '../core/library.js';

export function renderSimulator({ navigate, onCleanup }) {
  const building = store.selectedBuilding;
  const container = el('.stack', { style: { gap: '16px' } });

  if (!building) {
    return el('.empty', {}, [el('h2.title', { text: 'Pick a building first' })]);
  }

  const model = ShearBuilding.from(building);
  const naturalPeriod = fundamentalPeriod(model);
  const modeList = modes(model);

  let quake = store.get('earthquakes')[0];
  let result = null;
  let playing = false;
  let frame = 0;
  let timer = null;
  let style = 'materials';
  let exaggeration = store.get('settings').exaggeration ?? 40;

  // ── The scene ────────────────────────────────────────────────────────────
  const sceneHost = el('.scene');
  let scene = null;
  requestAnimationFrame(() => {
    scene = new BuildingScene(sceneHost);
    scene.exaggeration = exaggeration;
    scene.build(building, { animate: true });
  });

  const stats = el('.readout-grid');
  const verdictSlot = el('div');

  const drawStats = () => {
    setChildren(stats, [
      readout('Natural period', naturalPeriod.toFixed(2), { unit: 's', large: true }),
      readout('Sway shown', `×${exaggeration}`),
      result && readout('Peak drift', (result.maximumDrift * 100).toFixed(2), { unit: '%' }),
      result && readout('Period after', result.finalPeriod.toFixed(2), { unit: 's' }),
    ]);
  };

  // ── Playback ─────────────────────────────────────────────────────────────
  const stop = () => {
    playing = false;
    if (timer) clearInterval(timer);
    timer = null;
  };

  const play = () => {
    if (!result?.times.length) return;
    stop();
    playing = true;
    frame = 0;
    scene?.reset();

    // Real time: the frame interval matches the solved time step, so a
    // twenty-second earthquake takes twenty seconds.
    const interval = Math.max(
      ((result.times[result.times.length - 1] ?? 1) / result.times.length) * 1000, 16,
    );

    timer = setInterval(() => {
      if (!sceneHost.isConnected) { stop(); return; }
      if (frame >= result.times.length) {
        stop();
        scene?.markDamage(result.storeyResults, building.system);
        finish();
        return;
      }
      scene?.apply(result.displacements[frame], result.drifts[frame], building.system);
      frame += 1;
    }, interval);
  };

  const run = () => {
    Haptics.impact('Heavy');
    // A synthetic accelerogram with the character of the chosen event: its
    // duration, dominant period and peak acceleration, with a rising then
    // decaying envelope. The app says this is generated rather than implying
    // it is playing back the real record.
    const rate = 100;
    const count = Math.round(quake.duration * rate);
    const samples = new Float64Array(count);
    for (let i = 0; i < count; i += 1) {
      const t = i / rate;
      const envelope = Math.min(t / Math.max(quake.riseTime, 0.1), 1)
        * Math.exp(-t / (quake.duration * 0.45));
      samples[i] = quake.pga * envelope * (
        Math.sin((2 * Math.PI * t) / quake.dominantPeriod)
        + 0.42 * Math.sin((2 * Math.PI * t) / (quake.dominantPeriod * 0.55))
        + 0.18 * (Math.random() - 0.5)
      );
    }

    result = solve(ShearBuilding.from(building), new Waveform(samples, rate),
      { system: building.system });
    drawStats();
    play();
  };

  const finish = () => {
    const worst = Math.max(...result.storeyResults.map((s) => s.damageState), 0);
    const verdict = worst >= 3 ? 'unsafe' : worst >= 1 ? 'caution' : 'safe';
    const tone = VERDICTS[verdict].tone;

    setChildren(verdictSlot, [el(`.placard.${tone}`, {}, [
      el('.verdict', { text: VERDICTS[verdict].label }),
      el('.meaning', { text: VERDICTS[verdict].meaning }),
      el('.caption', {
        text: `Peak interstorey drift ${(result.maximumDrift * 100).toFixed(2)}%, `
          + `period ${result.periodChangePercent >= 0 ? 'lengthened' : 'shortened'} by `
          + `${Math.abs(result.periodChangePercent).toFixed(1)}%.`,
      }),
      button('Record this as an assessment', () => {
        const assessment = {
          id: `sim-${Date.now()}`,
          buildingId: building.id,
          createdAt: Date.now(),
          verdict,
          confidence: 0.72,
          periodChangePercent: result.periodChangePercent,
          maximumDrift: result.maximumDrift,
          source: 'simulation',
          note: `Simulated ${quake.name} ${quake.year}.`,
        };
        store.set('assessments', [...store.get('assessments'), assessment]);
        store.enqueueSync('assessment', assessment.id);
        Haptics.notification('SUCCESS');
        navigate('assess');
      }, { kind: 'secondary', block: true }),
    ])]);
  };

  // ── Layout ───────────────────────────────────────────────────────────────
  container.append(
    el('.panel', { style: { padding: '12px 16px' } }, [
      el('.hstack', {}, [
        el('.stack-tight', { style: { flex: '1' } }, [
          el('.headline', { text: building.name }),
          el('.caption', { text: `${building.storeyCount} storeys · ${building.height} m` }),
        ]),
        pill(`×${exaggeration}`, 'accent'),
      ]),
      stats,
    ]),
    sceneHost,

    segmented([
      { value: 'materials', label: 'Materials' },
      { value: 'wireframe', label: 'Wireframe' },
      { value: 'drift', label: 'Drift' },
    ], style, (value) => {
      style = value;
      scene?.setStyle(value);
      container.querySelectorAll('.segmented button').forEach((node, index) => {
        node.setAttribute('aria-selected',
          String(['materials', 'wireframe', 'drift'][index] === value));
      });
    }),

    verdictSlot,

    panel('Earthquake', [
      el('.stack', {}, store.get('earthquakes').map((q) => el('button.row', {
        type: 'button',
        style: q.id === quake.id ? { borderColor: 'var(--accent)' } : {},
        on: {
          click: () => {
            quake = q;
            Haptics.selection();
            window.seismic.render();
          },
        },
      }, [
        el('.row-text', {}, [
          el('.row-title', { text: `${q.name} ${q.year}` }),
          el('.caption', { text: `M${q.magnitude} · ${q.duration} s · peak ${q.pga.toFixed(1)} m/s²` }),
        ]),
        q.id === quake.id ? icon('check', { size: 20 }) : null,
      ]))),
      el('p.caption.prose', { text: quake.note }),
    ], { iconName: 'globe' }),

    panel('Exaggeration', [
      (() => {
        const slider = el('input', {
          type: 'range', min: '1', max: '120', step: '1', value: String(exaggeration),
        });
        slider.addEventListener('input', () => {
          exaggeration = Number(slider.value);
          if (scene) scene.exaggeration = exaggeration;
          store.set('settings', { ...store.get('settings'), exaggeration });
          drawStats();
        });
        return slider;
      })(),
      el('p.caption', {
        text: 'Real interstorey drift at the point of damage is under one per cent — a '
          + 'few centimetres across a whole storey. At true scale the animation would '
          + 'look completely still, so it is amplified and the factor is shown.',
      }),
    ]),

    modeList.length > 0 && panel('Mode shapes', [
      el('.stack', {}, modeList.slice(0, 3).map((mode) => el('button.row', {
        type: 'button',
        on: {
          click: () => {
            Haptics.selection();
            scene?.animateMode(mode.shape);
          },
        },
      }, [
        el('.row-text', {}, [
          el('.row-title', { text: `Mode ${mode.number}` }),
          el('.caption', {
            text: `${mode.period.toFixed(2)} s · ${Math.round(mode.massParticipationRatio * 100)}% of the mass`,
          }),
        ]),
        icon('play', { size: 18 }),
      ]))),
      el('p.caption', {
        text: 'The first mode usually carries most of the mass, which is why it is the '
          + 'one worth measuring. Tap one to see how the building wants to move in it.',
      }),
    ], { iconName: 'analysis' }),

    notice('info', 'This is a model, not a prediction',
      'It solves the equations of motion for a shear building with this height, mass and '
      + 'stiffness. It does not know about your particular columns, your soil, or what '
      + 'the last earthquake already did.'),
  );

  // ── The run button, pinned ───────────────────────────────────────────────
  const runButton = button('Shake', () => (playing ? stop() : run()),
    { block: true, iconName: 'play' });
  container.append(el('.panel', {
    style: {
      position: 'sticky',
      // Above the floating tab bar, which is 86pt tall plus the home indicator.
      bottom: 'calc(94px + env(safe-area-inset-bottom))',
      zIndex: '20',
    },
  }, [runButton]));

  drawStats();
  onCleanup(() => { stop(); scene?.dispose(); });
  return container;
}
