// Preparedness, specific to this building rather than generic advice.

import { store } from '../state.js';
import { el, panel, segmented, icon, notice, setChildren} from '../ui/dom.js';
import { empiricalPeriod } from '../core/structures.js';
import { Haptics } from '../platform.js';

export function renderPrepare() {
  let phase = 'before';
  const container = el('.stack', { style: { gap: '16px' } });
  const body = el('.stack', { style: { gap: '16px' } });
  const building = store.selectedBuilding;

  const draw = () => {
    setChildren(body, [...({ before: beforeContent, during: duringContent, after: afterContent }[phase])(building)]);
  };

  container.append(
    segmented([
      { value: 'before', label: 'Before' },
      { value: 'during', label: 'During' },
      { value: 'after', label: 'After' },
    ], phase, (value) => {
      phase = value;
      container.querySelectorAll('.segmented button').forEach((node, index) => {
        node.setAttribute('aria-selected', String(['before', 'during', 'after'][index] === value));
      });
      draw();
    }),
    body,
  );

  draw();
  return container;
}

function beforeContent(building) {
  const period = building ? empiricalPeriod(building) : 0.9;
  const quick = period < 1;

  return [
    panel('For my building', [
      ...[
        [`This building sways with a ${period.toFixed(1)} second rhythm`,
          quick
            ? 'A quick, sharp shake. Things will be thrown off shelves before you can '
              + 'react, so what is fixed down matters more here than in a tall building.'
            : 'A slow, rolling sway. You will have time to move, but tall furniture and '
              + 'anything on wheels will travel a long way.'],
        [labelForMaterial(building?.material),
          'The frame is designed to bend and absorb energy. What hurts people in these '
          + 'buildings is almost never the frame — it is ceilings, light fittings, glass '
          + 'and unsecured furniture.'],
        ['Shelter on a lower floor if you have a choice',
          `Movement grows with height. In this building the top floor moves roughly `
          + `${Math.max(2, Math.round((building?.storeyCount ?? 8) / 2))} times as far as `
          + 'the second. Lifts will stop; the stairs are the way out afterwards, not during.'],
      ].map(([title, detail]) => el('.hstack', { style: { alignItems: 'flex-start' } }, [
        icon('info', { size: 18 }),
        el('.stack-tight', {}, [
          el('.headline', { text: title }),
          el('p.caption', { text: detail }),
        ]),
      ])),
    ], { iconName: 'building' }),

    ...[
      ['Strap down anything tall', 'Bookcases, wardrobes and water heaters kill and '
        + 'injure far more people than collapsing frames do. Two brackets and an hour.'],
      ['Three days of water per person', 'Four litres a day each. Mains water is usually '
        + 'the first utility to go and among the last to come back.'],
      ['Shoes and a torch beside every bed', 'Broken glass on the floor in the dark is '
        + 'the most common injury after an earthquake, and it is entirely preventable.'],
      ['Know where the gas shut-off is', 'And keep the spanner beside it. Fire after the '
        + 'shaking causes more loss than the shaking.'],
      ['Agree one out-of-area contact', 'Local networks jam; long distance often still '
        + 'works. Everyone reports in to the same person.'],
    ].map(([title, detail]) => checklistItem(title, detail)),
  ];
}

function duringContent() {
  return [
    notice('critical', 'Drop, cover, hold on',
      'Get under a sturdy table, cover your head and neck, and hold on to it so it does '
      + 'not move away from you. Stay there until the shaking stops.'),
    panel('Do not', [
      ...[
        ['Do not run outside', 'Most injuries happen at doorways and just outside, from '
          + 'falling glass and masonry.'],
        ['Do not stand in a doorway', 'That advice comes from adobe houses where the frame '
          + 'was the only strong part. In a modern building it is one of the worst places.'],
        ['Do not use the lift', 'It will stop, and you will be in it.'],
      ].map(([title, detail]) => el('.stack-tight', {}, [
        el('.headline', { text: title }),
        el('p.caption', { text: detail }),
      ])),
    ], { iconName: 'warning' }),
    panel('If you cannot get under anything', [
      el('p.body', {
        text: 'Get against an interior wall, away from windows, and cover your head with '
          + 'your arms. In bed, stay there and put a pillow over your head — the floor is '
          + 'where the broken glass is.',
      }),
    ]),
  ];
}

function afterContent() {
  return [
    panel('In the first minutes', [
      ...[
        ['Check yourself, then others', 'Bleeding first, then anyone not responding.'],
        ['Smell for gas before anything else', 'If you smell it, shut it off, open a '
          + 'window and leave. Do not use a light switch or a phone inside.'],
        ['Expect aftershocks', 'A large aftershock can bring down what the main shock '
          + 'weakened. The building is more fragile now than it was an hour ago.'],
        ['Check in with your household', 'One message each to the agreed contact, then '
          + 'stop using the network so it stays up for emergencies.'],
      ].map(([title, detail]) => el('.stack-tight', {}, [
        el('.headline', { text: title }),
        el('p.caption', { text: detail }),
      ])),
    ], { iconName: 'checklist' }),
    notice('info', 'Then let Seismic assess the building',
      'It compares the building\'s rhythm now against its baseline. That comparison is '
      + 'evidence, not a guess — but it is not a substitute for an engineer where one '
      + 'is available.'),
  ];
}

function checklistItem(title, detail) {
  const key = `prep.${title}`;
  const done = store.get('settings')[key] ?? false;

  const box = el('button', {
    type: 'button',
    style: {
      width: '26px', height: '26px', flex: 'none', borderRadius: '50%',
      border: '1.5px solid var(--hairline-strong)',
      background: done ? 'var(--accent)' : 'transparent',
      color: 'var(--accent-text)', display: 'grid', placeItems: 'center',
    },
  }, done ? [icon('check', { size: 15 })] : []);

  box.addEventListener('click', () => {
    const settings = { ...store.get('settings') };
    settings[key] = !settings[key];
    store.set('settings', settings);
    Haptics.selection();
    window.seismic.render();
  });

  return el('.panel', { style: { padding: '14px 16px' } }, [
    el('.hstack', { style: { alignItems: 'flex-start' } }, [
      box,
      el('.stack-tight', {}, [
        el('.headline', { text: title }),
        el('p.caption', { text: detail }),
      ]),
    ]),
  ]);
}

function labelForMaterial(key) {
  return {
    reinforcedConcrete: 'Reinforced concrete frame',
    steel: 'Steel frame',
    timber: 'Timber frame',
    masonry: 'Masonry',
    unreinforcedMasonry: 'Unreinforced masonry',
  }[key] ?? 'Structural frame';
}
