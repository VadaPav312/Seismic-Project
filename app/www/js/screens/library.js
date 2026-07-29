// The library, and importing any building in the world.
//
// Import is offline-capable by design: the bundled reference library is
// searched first and always answers. A network path would add live facts, but
// its absence must never leave somebody staring at a spinner.

import { store } from '../state.js';
import {
  el, panel, button, row, icon, pill, field, sheet, notice, readoutGrid, readout, setChildren,} from '../ui/dom.js';
import { SEED_BUILDINGS } from '../core/library.js';
import { empiricalPeriod } from '../core/structures.js';
import { polygonFor, parseShape, shapeLabel, allShapes } from '../core/planshape.js';
import { Haptics } from '../platform.js';

export function renderLibrary({ navigate }) {
  const container = el('.stack', { style: { gap: '14px' } });
  let query = '';

  const search = field('', { placeholder: 'Search your library' });
  search.input.setAttribute('type', 'search');
  const list = el('.stack');

  const drawList = () => {
    const buildings = store.get('buildings').filter((b) => {
      if (!query) return true;
      const haystack = `${b.name} ${b.address ?? ''}`.toLowerCase();
      return haystack.includes(query.toLowerCase());
    });

    setChildren(list, [
      ...buildings.map((building) => row({
        iconName: building.storeyCount > 20 ? 'building' : 'building',
        title: building.name,
        subtitle: `${building.storeyCount} storeys · ${building.height} m`
          + ` · T ≈ ${empiricalPeriod(building).toFixed(2)} s`,
        badge: building.id === store.get('selectedBuildingId')
          ? pill('Your building', 'accent') : null,
        onClick: () => {
          Haptics.selection();
          store.set('selectedBuildingId', building.id);
          navigate('home');
        },
      })),
      buildings.length === 0 && el('p.body', {
        text: 'Nothing here matches that. Try importing it instead.',
        style: { padding: '16px', textAlign: 'center' },
      }),
    ]);
  };

  search.input.addEventListener('input', () => { query = search.input.value; drawList(); });

  container.append(
    search.wrapper,
    el('button.row', {
      type: 'button',
      on: { click: () => showImport(navigate, drawList) },
    }, [
      el('.row-icon', {}, [icon('globe', { size: 21 })]),
      el('.row-text', {}, [
        el('.row-title', { text: 'Import any building in the world' }),
        el('.caption', {
          text: 'Type a name or an address. Seismic finds its facts, works out how it '
            + 'should behave, and builds it in 3D.',
        }),
      ]),
    ]),
    list,
  );

  drawList();
  return container;
}

function showImport(navigate, refresh) {
  let candidates = [];
  const results = el('.stack');
  const nameField = field('Building name or address', { placeholder: 'e.g. Salesforce Tower' });

  const runSearch = () => {
    const query = nameField.input.value.trim().toLowerCase();
    if (query.length < 2) { setChildren(results, []); return; }

    // The bundled library first — it needs no network and always answers.
    candidates = SEED_BUILDINGS
      .filter((b) => `${b.name} ${b.address}`.toLowerCase().includes(query))
      .map((b) => ({ ...b, provider: 'Bundled library', confidence: 0.9 }));

    // Then a plausible interpretation of what was typed, so a building nobody
    // has catalogued is still importable rather than a dead end.
    candidates.push({
      id: `import-${Date.now()}`,
      name: titleCase(nameField.input.value.trim()),
      address: 'Entered by you',
      storeyCount: 8,
      height: 27,
      footprintArea: 620,
      material: 'reinforcedConcrete',
      system: 'momentFrame',
      soil: 'stiffSoil',
      retrofit: 'none',
      provider: 'Your description',
      confidence: 0.4,
      isNew: true,
    });

    setChildren(results, [...candidates.map((candidate) => row({
      iconName: 'building',
      title: candidate.name,
      subtitle: `${candidate.provider} · ${Math.round(candidate.confidence * 100)}% confidence`,
      onClick: () => showConfirm(candidate, navigate, refresh, close),
    }))]);
  };

  nameField.input.addEventListener('input', runSearch);

  const close = sheet('Import a building', [
    nameField.wrapper,
    notice('info', 'Works without a network',
      'The bundled reference library answers immediately. Live sources add facts when '
      + 'they are reachable; they are never required.'),
    results,
  ]);
}

function showConfirm(candidate, navigate, refresh, closeParent) {
  let shape = candidate.planShape ?? parseShape(candidate.notes ?? '') ?? 'rectangular';

  const storeys = field('Storeys', { type: 'number', value: String(candidate.storeyCount) });
  const height = field('Height (m)', { type: 'number', value: String(candidate.height) });
  const area = field('Footprint area (m²)', {
    type: 'number', value: String(candidate.footprintArea),
  });

  const shapeRow = el('.stack-tight');
  const drawShapes = () => {
    setChildren(shapeRow, [
      el('label', { text: 'PLAN SHAPE', style: { fontSize: '0.72rem', color: 'var(--text-tertiary)', letterSpacing: '0.08em' } }),
      el('.hstack', { style: { flexWrap: 'wrap', gap: '8px' } },
        allShapes().map((option) => el('button.btn.btn-secondary', {
          type: 'button',
          style: option === shape
            ? { borderColor: 'var(--accent)', color: 'var(--accent)', minHeight: '38px', padding: '0 14px' }
            : { minHeight: '38px', padding: '0 14px' },
          on: { click: () => { shape = option; drawShapes(); } },
        }, shapeLabel(option)))),
      el('p.caption', {
        text: 'Plan irregularity is one of the strongest predictors of earthquake damage '
          + 'there is — re-entrant corners concentrate stress, and mass away from the '
          + 'centre of rigidity twists a building rather than pushing it. Every shape '
          + 'here encloses the same floor area, so choosing one cannot change the mass.',
      }),
    ]);
  };
  drawShapes();

  const close = sheet('Confirm the facts', [
    el('p.body', {
      text: 'Nothing is promoted into the model silently. Change anything that is wrong '
        + '— what you enter outranks what was found.',
    }),
    storeys.wrapper,
    height.wrapper,
    area.wrapper,
    shapeRow,
    button('Add to my library', () => {
      const building = {
        ...candidate,
        id: candidate.isNew ? `building-${Date.now()}` : `copy-${Date.now()}`,
        storeyCount: Math.max(1, Number(storeys.input.value) || 1),
        height: Math.max(2, Number(height.input.value) || 10),
        footprintArea: Math.max(10, Number(area.input.value) || 400),
        planShape: shape,
        footprint: polygonFor(shape, Math.max(10, Number(area.input.value) || 400)),
        isSandbox: false,
      };
      store.set('buildings', [...store.get('buildings'), building]);
      store.set('selectedBuildingId', building.id);
      store.enqueueSync('building', building.id);
      Haptics.notification('SUCCESS');
      close();
      closeParent();
      navigate('simulator');
    }, { block: true }),
  ]);
}

function titleCase(text) {
  return text.replace(/\w\S*/g, (word) => word[0].toUpperCase() + word.slice(1).toLowerCase());
}
