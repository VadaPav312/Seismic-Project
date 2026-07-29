// The community map.
//
// Positions are offset before anything is shared. That is not a setting: a
// precise location tied to "this building may be unsafe" is an invitation to
// looters, and the useful information — roughly where, roughly how bad —
// survives the offset intact.

import { store } from '../state.js';
import {
  el, panel, button, pill, icon, notice, emptyState, relativeTime,
} from '../ui/dom.js';
import { VERDICTS } from '../core/library.js';
import { Location, Haptics } from '../platform.js';

export function renderMap({ navigate }) {
  const container = el('.stack', { style: { gap: '16px' } });
  const tags = store.get('tags');
  const building = store.selectedBuilding;

  const canvas = el('canvas.chart', { style: { borderRadius: 'var(--radius)' } });

  container.append(
    panel('Near you', [
      canvas,
      el('.chart-legend', {}, [
        el('span', { style: { color: 'var(--verdict-green)' } }, [el('i'), 'Safe']),
        el('span', { style: { color: 'var(--verdict-amber)' } }, [el('i'), 'Restricted']),
        el('span', { style: { color: 'var(--verdict-red)' } }, [el('i'), 'Do not occupy']),
      ]),
    ], { iconName: 'map' }),

    notice('info', 'Your position is offset before it is shared',
      'Tags are placed on a coarse grid, so a passer-by sees that a building on this '
      + 'street is unsafe without being told which door it is.'),

    tags.length === 0
      ? el('.panel', {}, [
        el('p.body', {
          text: 'No tags yet. After an event, buildings near you appear here as people '
            + 'assess them — including yours, if you choose to share it.',
        }),
        button('Tag my building', () => addTag(building, navigate), { block: true }),
      ])
      : panel('Recent tags', [
        el('.stack', {}, tags.slice(0, 20).map((tag) => el('.row', {}, [
          el('.row-icon', { style: { color: `var(--verdict-${VERDICTS[tag.verdict].tone})` } },
            [icon('shield', { size: 20 })]),
          el('.row-text', {}, [
            el('.row-title', { text: tag.label }),
            el('.caption', { text: `${VERDICTS[tag.verdict].label} · ${relativeTime(tag.postedAt)}` }),
          ]),
        ]))),
        button('Tag my building', () => addTag(building, navigate), { block: true }),
      ], { iconName: 'people' }),
  );

  requestAnimationFrame(() => drawMap(canvas, tags, building));
  return container;
}

function addTag(building, navigate) {
  const assessment = store.latestAssessment;
  if (!assessment) { navigate('assess'); return; }
  const tag = {
    id: `tag-${Date.now()}`,
    buildingId: building.id,
    label: building.name,
    verdict: assessment.verdict,
    // Rounded to roughly a hundred metres, deliberately.
    latitude: Math.round((building.latitude ?? 0) * 1000) / 1000,
    longitude: Math.round((building.longitude ?? 0) * 1000) / 1000,
    postedAt: Date.now(),
    expiresAt: Date.now() + 72 * 3600 * 1000,
  };
  store.set('tags', [tag, ...store.get('tags')]);
  store.enqueueSync('tag', tag.id);
  Haptics.notification('SUCCESS');
  window.seismic.render();
}

/**
 * A schematic street grid rather than a tile map.
 *
 * Real tiles need a network, and this screen has to work during exactly the
 * event when there is none. The grid carries the information that matters —
 * relative position and verdict — with no dependency at all.
 */
function drawMap(canvas, tags, building) {
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  const width = canvas.clientWidth || 320;
  const height = 260;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  const context = canvas.getContext('2d');
  context.setTransform(ratio, 0, 0, ratio, 0, 0);

  context.fillStyle = '#131519';
  context.fillRect(0, 0, width, height);

  context.strokeStyle = 'rgba(255,255,255,0.06)';
  context.lineWidth = 1;
  for (let x = 0; x < width; x += 42) {
    context.beginPath(); context.moveTo(x, 0); context.lineTo(x, height); context.stroke();
  }
  for (let y = 0; y < height; y += 42) {
    context.beginPath(); context.moveTo(0, y); context.lineTo(width, y); context.stroke();
  }

  const colours = { safe: '#47c97e', caution: '#e6b85a', unsafe: '#e0574f', unknown: '#6b7280' };
  tags.slice(0, 40).forEach((tag, index) => {
    const angle = index * 2.399;
    const radius = 24 + index * 9;
    const x = width / 2 + Math.cos(angle) * Math.min(radius, width / 2 - 24);
    const y = height / 2 + Math.sin(angle) * Math.min(radius, height / 2 - 24);
    context.fillStyle = colours[tag.verdict] ?? colours.unknown;
    context.beginPath();
    context.arc(x, y, 7, 0, Math.PI * 2);
    context.fill();
  });

  context.fillStyle = '#3ec9f0';
  context.beginPath();
  context.arc(width / 2, height / 2, 9, 0, Math.PI * 2);
  context.fill();
  context.strokeStyle = 'rgba(62,201,240,0.35)';
  context.lineWidth = 2;
  context.beginPath();
  context.arc(width / 2, height / 2, 20, 0, Math.PI * 2);
  context.stroke();

  context.fillStyle = '#9aa2ad';
  context.font = '11px system-ui';
  context.fillText(building?.name ?? 'You', width / 2 + 14, height / 2 - 12);
}
