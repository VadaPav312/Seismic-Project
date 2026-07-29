// The assessment: a verdict, and every measurement that produced it.
//
// A verdict nobody can interrogate is a verdict nobody should trust, so the
// evidence is not behind a disclosure triangle — it is the body of the screen.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, button, emptyState, notice, relativeTime,
} from '../ui/dom.js';
import { drawBars } from '../ui/chart.js';
import { VERDICTS } from '../core/library.js';
import { fragility, DAMAGE_STATES } from '../core/structures.js';
import { Speech } from '../platform.js';

export function renderAssess({ navigate }) {
  const assessment = store.latestAssessment;
  const building = store.selectedBuilding;

  if (!assessment) {
    return emptyState({
      iconName: 'shield',
      title: 'Nothing to assess yet',
      message: 'An assessment is produced automatically after an event. Until then there '
        + 'is only a baseline — and inventing a verdict from nothing would be worse than '
        + 'showing none.',
      actionTitle: 'Simulate an event',
      action: () => navigate('simulator'),
      secondaryTitle: 'Run a drill instead',
      secondaryAction: () => window.seismic.beginEvent({ warningSeconds: 8, isDrill: true }),
    });
  }

  const verdict = VERDICTS[assessment.verdict];
  const curves = fragility(assessment.maximumDrift ?? 0, building?.system);
  const canvas = el('canvas.chart');

  const container = el('.stack', { style: { gap: '18px' } }, [
    el(`.placard.${verdict.tone}`, {}, [
      el('.verdict', { text: verdict.label }),
      el('.meaning', { text: verdict.meaning }),
      el('.caption', { text: `${building?.name ?? 'Building'} · ${relativeTime(assessment.createdAt)}` }),
    ]),

    panel('The evidence', [
      readoutGrid([
        readout('Period change',
          `${assessment.periodChangePercent >= 0 ? '+' : ''}${(assessment.periodChangePercent ?? 0).toFixed(1)}`,
          { unit: '%', large: true }),
        readout('Peak drift', ((assessment.maximumDrift ?? 0) * 100).toFixed(2), { unit: '%' }),
        readout('Confidence', Math.round((assessment.confidence ?? 0) * 100), { unit: '%' }),
      ]),
      el('p.body.prose', {
        text: 'A longer period after an event means the building has lost stiffness. That '
          + 'is what damage is, structurally — and it is measurable long before a crack '
          + 'is visible. A shift under about 3% is within what temperature alone can do.',
      }),
    ], { iconName: 'analysis' }),

    panel('Probability of reaching each damage state', [
      canvas,
      el('p.caption', {
        text: 'Fragility curves rather than a threshold. A building does not have a drift '
          + 'at which it is fine and one micron more at which it is not; it has a '
          + 'probability that rises through a range, and saying so is more useful than '
          + 'a false line in the sand.',
      }),
    ], { iconName: 'scope' }),

    assessment.note && notice('info', 'Where this came from', assessment.note),

    button('Read it out loud', () => {
      Speech.speak(`${verdict.label}. ${verdict.meaning}`, { urgent: false });
    }, { kind: 'secondary', block: true, iconName: 'wave' }),
  ]);

  requestAnimationFrame(() => {
    drawBars(canvas, [
      { label: 'Slight', value: curves.slight, colour: '#5c94a1', caption: pct(curves.slight) },
      { label: 'Moderate', value: curves.moderate, colour: '#bca059', caption: pct(curves.moderate) },
      { label: 'Extensive', value: curves.extensive, colour: '#bf7047', caption: pct(curves.extensive) },
      { label: 'Complete', value: curves.complete, colour: '#ad4045', caption: pct(curves.complete) },
    ], { height: 170 });
  });

  return container;
}

const pct = (value) => `${Math.round(value * 100)}%`;
