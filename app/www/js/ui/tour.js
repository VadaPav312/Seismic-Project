// The guided tour that runs over the real app.
//
// Deliberately not more introduction slides. The introduction explains *why* a
// building's rhythm changes, which is an idea and belongs on its own screen.
// This explains *where things are*, which is a place — and the only honest way
// to show somebody a place is to stand them in it. So the app keeps running
// underneath: the real tab bar, the real trace, the real building, dimmed, with
// a hole cut around whatever is being described.

import { store } from '../state.js';
import { el, icon, setChildren} from './dom.js';
import { Haptics } from '../platform.js';

const STEPS = [
  {
    id: 'home',
    section: 'home',
    title: 'This is your building',
    body: 'Everything the app knows about it lives here: how tall it is, what it is '
      + 'made of, and how it has behaved every time it has been shaken.',
    anchor: null,
  },
  {
    id: 'verdict',
    section: 'home',
    title: 'The answer, in one line',
    body: 'After an event this says whether the building is safe to be in. It is never '
      + 'hidden behind a menu and never phrased as a maybe — and tapping it shows you '
      + 'exactly which measurements produced it.',
    anchor: '[data-tour="verdict"]',
  },
  {
    id: 'monitor',
    section: 'monitor',
    title: 'The live trace',
    body: 'Three axes of ground motion, straight from the node. The strip underneath is '
      + 'the trigger ratio — when it crosses the line, the app decides an earthquake '
      + 'has started.',
    anchor: null,
  },
  {
    id: 'freeze',
    section: 'monitor',
    title: 'Freeze what just happened',
    body: 'The interesting moment is always the one that has just scrolled off. Freeze '
      + 'holds the trace still so you can look at it properly; the node keeps recording '
      + 'either way.',
    anchor: '[data-tour="freeze"]',
  },
  {
    id: 'simulator',
    section: 'simulator',
    title: 'Your building, shaken',
    body: 'Pick a real earthquake and watch what it does to this specific building. The '
      + 'sway is exaggerated so you can see it — the app tells you by how much rather '
      + 'than pretending otherwise.',
    anchor: null,
  },
  {
    id: 'map',
    section: 'map',
    title: 'The street around you',
    body: 'After an event, buildings near you appear here as other people assess them. '
      + 'Your own position is offset before anything is shared.',
    anchor: null,
  },
  {
    id: 'more',
    section: 'home',
    title: 'Everything else is in here',
    body: 'Assess, Analysis, Node, Preparedness, Household and the rest. Nine icons in a '
      + 'tab bar is a bar nobody can use in a hurry.',
    anchor: '#more-button',
  },
];

let running = false;

export function isTourDue() {
  return !running
    && Boolean(store.get('account'))
    && store.get('didCompleteOnboarding')
    && !store.get('didCompleteTutorial');
}

export function startTour({ navigate }) {
  if (running) return;
  running = true;

  let index = 0;
  const dim = el('canvas.tour-dim');
  const ring = el('.tour-ring');
  const card = el('.tour-card');
  document.body.append(dim, ring, card);

  const finish = () => {
    running = false;
    store.set('didCompleteTutorial', true);
    dim.remove();
    ring.remove();
    card.remove();
    window.removeEventListener('resize', place);
  };

  const step = () => STEPS[index];

  const go = (delta) => {
    Haptics.selection();
    const next = index + delta;
    if (next < 0) return;
    if (next >= STEPS.length) { finish(); return; }
    index = next;
    navigate(step().section);
    // The new screen has to lay out before its anchor can be measured.
    requestAnimationFrame(() => requestAnimationFrame(() => { drawCard(); place(); }));
  };

  function drawCard() {
    setChildren(card, []);
    card.append(
      el('.tour-progress', {}, STEPS.map((_, i) => el(`i${i <= index ? '.done' : ''}`))),
      el('h2.title', { text: step().title }),
      el('p.body', { text: step().body }),
      el('.hstack', {}, [
        el('button.btn.btn-quiet', {
          type: 'button', on: { click: finish }, style: { paddingLeft: '0' },
        }, 'End tour'),
        el('.spacer'),
        index > 0 && el('button.btn.btn-secondary', {
          type: 'button', on: { click: () => go(-1) },
        }, 'Back'),
        el('button.btn.btn-primary', {
          type: 'button', on: { click: () => go(1) },
        }, index === STEPS.length - 1 ? 'Done' : 'Next'),
      ]),
    );
  }

  /**
   * Positions the spotlight and the card.
   *
   * The hole is a real hole — the dimming is drawn to a canvas and the target
   * rectangle is cleared out of it, so taps inside reach the app underneath and
   * somebody can try the control while it is being described.
   */
  function place() {
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const width = window.innerWidth;
    const height = window.innerHeight;
    dim.width = width * ratio;
    dim.height = height * ratio;
    dim.style.width = `${width}px`;
    dim.style.height = `${height}px`;

    const context = dim.getContext('2d');
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    context.fillStyle = 'rgba(0,0,0,0.78)';
    context.fillRect(0, 0, width, height);

    const target = step().anchor ? document.querySelector(step().anchor) : null;
    const box = target?.getBoundingClientRect();
    const valid = box && box.width > 1 && box.height > 1;

    if (valid) {
      const hole = {
        x: box.left - 8, y: box.top - 8, w: box.width + 16, h: box.height + 16,
      };
      context.save();
      // 'destination-out' punches through what is already drawn rather than
      // painting transparent black over it.
      context.globalCompositeOperation = 'destination-out';
      context.beginPath();
      context.roundRect(hole.x, hole.y, hole.w, hole.h, 12);
      context.fill();
      context.restore();

      Object.assign(ring.style, {
        display: 'block',
        left: `${hole.x}px`,
        top: `${hole.y}px`,
        width: `${hole.w}px`,
        height: `${hole.h}px`,
      });

      // Below the hole if there is room, above it if not, centred if neither.
      const cardHeight = card.offsetHeight || 240;
      const below = hole.y + hole.h + 20;
      const above = hole.y - 20 - cardHeight;
      if (below + cardHeight < height - 20) card.style.top = `${below}px`;
      else if (above > 20) card.style.top = `${above}px`;
      else card.style.top = `${Math.max((height - cardHeight) / 2, 20)}px`;
    } else {
      ring.style.display = 'none';
      const cardHeight = card.offsetHeight || 240;
      card.style.top = `${Math.max((height - cardHeight) / 2, 20)}px`;
    }
  }

  navigate(step().section);
  requestAnimationFrame(() => requestAnimationFrame(() => { drawCard(); place(); }));
  window.addEventListener('resize', place);
}
