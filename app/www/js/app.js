// The shell: what is on screen, and what drives it.
//
// One display tick runs the simulated node and republishes its snapshot. That
// snapshot is deliberately *not* broadcast to every screen — only screens that
// draw live motion subscribe to it. Publishing a 20 Hz stream to everything is
// how an interface ends up re-rendering the settings screen twenty times a
// second to draw data it does not show.

import { store } from './state.js';
import { SimulatedNode } from './core/node.js';
import { configureChrome, Haptics, Speech, setHapticsEnabled } from './platform.js';
import { el, clear, icon, append } from './ui/dom.js';
import { startTour, isTourDue } from './ui/tour.js';

import { renderHome } from './screens/home.js';
import { renderMonitor } from './screens/monitor.js';
import { renderSimulator } from './screens/simulator.js';
import { renderMap } from './screens/map.js';
import { renderLibrary } from './screens/library.js';
import { renderAssess } from './screens/assess.js';
import { renderAnalysis } from './screens/analysis.js';
import { renderNode } from './screens/node.js';
import { renderFeed } from './screens/feed.js';
import { renderPrepare } from './screens/prepare.js';
import { renderHousehold } from './screens/household.js';
import { renderNetwork } from './screens/network.js';
import { renderShakeTable } from './screens/shaketable.js';
import { renderSettings } from './screens/settings.js';
import { renderAuth } from './screens/auth.js';
import { renderOnboarding } from './screens/onboarding.js';

const SECTIONS = {
  home: { title: 'Home', icon: 'home', render: renderHome, primary: true },
  monitor: { title: 'Monitor', icon: 'wave', render: renderMonitor, primary: true },
  simulator: { title: 'Simulator', icon: 'cube', render: renderSimulator, primary: true },
  map: { title: 'Map', icon: 'map', render: renderMap, primary: true },
  library: { title: 'Library', icon: 'building', render: renderLibrary, primary: true },
  assess: { title: 'Assess', icon: 'shield', render: renderAssess },
  analysis: { title: 'Analysis', icon: 'analysis', render: renderAnalysis },
  node: { title: 'Node', icon: 'sensor', render: renderNode },
  feed: { title: 'Feed', icon: 'globe', render: renderFeed },
  prepare: { title: 'Preparedness', icon: 'checklist', render: renderPrepare },
  household: { title: 'Household', icon: 'people', render: renderHousehold },
  network: { title: 'Network', icon: 'network', render: renderNetwork },
  shakeTable: { title: 'Shake table', icon: 'slider', render: renderShakeTable },
  settings: { title: 'Settings', icon: 'gear', render: renderSettings },
};

const app = {
  section: 'home',
  cleanup: null,
  node: null,
  tickHandle: null,
};

// ── Rendering ──────────────────────────────────────────────────────────────

export function navigate(section) {
  if (!SECTIONS[section]) return;
  app.section = section;
  render();
  document.getElementById('screen')?.scrollTo({ top: 0 });
}

export function currentSection() { return app.section; }

export function render() {
  const root = document.getElementById('app');
  if (!root) return;

  // A screen that set up timers, observers or a WebGL context must be given the
  // chance to tear them down. Skipping this leaks a renderer per navigation and
  // the web view runs out of contexts after a dozen.
  app.cleanup?.();
  app.cleanup = null;

  clear(root);

  if (!store.get('account')) {
    append(root, renderAuth({ onDone: render }));
    return;
  }
  if (!store.get('didCompleteOnboarding')) {
    append(root, renderOnboarding({ node: app.node, onDone: render }));
    return;
  }

  const section = SECTIONS[app.section];
  const screen = el('main#screen');
  const context = {
    node: app.node,
    navigate,
    rerender: render,
    onCleanup: (fn) => { app.cleanup = fn; },
  };

  append(root, [navbar(section), screen, tabbar()]);
  append(screen, el('.screen-inner', {}, [section.render(context)]));

  // Deferred so the first paint happens before anything measures a layout.
  requestAnimationFrame(() => {
    if (isTourDue()) startTour({ navigate });
  });
}

function navbar(section) {
  return el('header.navbar', {}, [
    el('h1', { text: section.title }),
    el('.navbar-actions', {}, [
      el('button.icon-button', {
        type: 'button',
        'aria-label': 'More',
        id: 'more-button',
        on: { click: showMoreMenu },
      }, [icon('more', { size: 20 })]),
    ]),
  ]);
}

function tabbar() {
  const bar = el('nav.tabbar', { role: 'tablist' });
  for (const [key, section] of Object.entries(SECTIONS)) {
    if (!section.primary) continue;
    bar.append(el('button', {
      role: 'tab',
      type: 'button',
      'aria-selected': String(key === app.section),
      on: {
        click: () => {
          Haptics.selection();
          navigate(key);
        },
      },
    }, [icon(section.icon, { size: 22 }), el('span', { text: section.title })]));
  }
  return bar;
}

/**
 * The sections without a tab.
 *
 * Nine icons in a bar is a bar nobody can use in a hurry, so the five most
 * urgent get tabs and the rest live here.
 */
function showMoreMenu() {
  Haptics.selection();
  const backdrop = el('.sheet-backdrop');
  const close = () => { backdrop.remove(); document.body.style.overflow = ''; };

  const items = Object.entries(SECTIONS)
    .filter(([, section]) => !section.primary)
    .map(([key, section]) => el('button.row', {
      type: 'button',
      on: { click: () => { close(); navigate(key); } },
    }, [
      el('.row-icon', {}, [icon(section.icon, { size: 21 })]),
      el('.row-text', {}, [el('.row-title', { text: section.title })]),
      el('.row-chevron', {}, [icon('chevron', { size: 18 })]),
    ]));

  backdrop.append(el('.sheet', {}, [
    el('.sheet-header', {}, [
      el('h2.title', { text: 'Everything else' }),
      el('button.icon-button', {
        type: 'button', 'aria-label': 'Close', on: { click: close },
      }, [icon('close', { size: 20 })]),
    ]),
    el('.stack', {}, items),
  ]));
  backdrop.addEventListener('click', (event) => { if (event.target === backdrop) close(); });
  document.body.append(backdrop);
  document.body.style.overflow = 'hidden';
}

// ── The event takeover ─────────────────────────────────────────────────────
//
// Life safety outranks everything. During an event this covers the entire
// screen and nothing competes with it.

let takeoverNode = null;
let lastCountdownSecond = null;

export function beginEvent(details) {
  const event = {
    id: `event-${Date.now()}`,
    startedAt: Date.now(),
    warningSeconds: details.warningSeconds ?? null,
    magnitude: details.magnitude ?? null,
    distanceKm: details.distanceKm ?? null,
    isDrill: Boolean(details.isDrill),
    acknowledged: false,
  };
  store.set('activeEvent', event, { persist: false });
  Haptics.notification('WARNING');

  Speech.speak(event.isDrill
    ? 'This is a drill. Drop, cover, hold on.'
    : 'Earthquake. Drop, cover, hold on.', { urgent: true });

  showTakeover();
}

function showTakeover() {
  hideTakeover();
  takeoverNode = el('.takeover');
  document.body.append(takeoverNode);
  updateTakeover();
}

function updateTakeover() {
  const event = store.get('activeEvent');
  if (!event || !takeoverNode) return;

  const elapsed = (Date.now() - event.startedAt) / 1000;
  const remaining = event.warningSeconds !== null
    ? Math.max(event.warningSeconds - elapsed, 0)
    : null;
  const arrived = remaining === null || remaining <= 0;

  takeoverNode.classList.toggle('arrived', arrived);
  clear(takeoverNode);

  append(takeoverNode, [
    event.isDrill && el('span.pill.violet', { text: 'DRILL' }),
    el('h1.title', {
      text: arrived ? 'Drop. Cover. Hold on.' : 'Strong shaking incoming',
      style: { fontSize: '1.6rem' },
    }),
    !arrived && el('.count', { text: Math.ceil(remaining) }),
    !arrived && el('p.body', { text: 'seconds until it reaches you' }),
    arrived && el('p.body', {
      text: 'Stay where you are until the shaking stops. Do not run outside — '
        + 'most injuries happen at the doors.',
    }),
    event.magnitude && el('p.caption', {
      text: `Estimated magnitude ${event.magnitude.toFixed(1)}`
        + (event.distanceKm ? ` · about ${Math.round(event.distanceKm)} km away` : ''),
    }),
    el('button.btn.btn-secondary', {
      type: 'button',
      style: { marginTop: '12px', minWidth: '200px' },
      on: { click: endEvent },
    }, arrived ? 'I am safe' : 'Dismiss'),
  ]);

  // One haptic per whole second, escalating. Compared against the previous
  // tick's whole second so it fires exactly once per boundary.
  if (remaining !== null && !arrived) {
    const second = Math.ceil(remaining);
    if (second !== lastCountdownSecond) {
      lastCountdownSecond = second;
      Haptics.countdown(second);
    }
  }
}

export function endEvent() {
  store.set('activeEvent', null, { persist: false });
  hideTakeover();
  Speech.stop();
}

function hideTakeover() {
  takeoverNode?.remove();
  takeoverNode = null;
  lastCountdownSecond = null;
}

// ── The tick ───────────────────────────────────────────────────────────────

function startTicking() {
  const interval = 1 / 20;
  let last = performance.now();

  const tick = () => {
    const now = performance.now();
    const delta = Math.min((now - last) / 1000, 0.25);
    last = now;

    app.node.tick(delta);
    // Not persisted: this is replaced twenty times a second, and writing it to
    // disk at that rate is pointless wear.
    store.set('node', app.node.snapshot(), { persist: false });

    if (store.get('activeEvent')) updateTakeover();
    app.tickHandle = setTimeout(tick, interval * 1000);
  };
  tick();
}

// ── Launch ─────────────────────────────────────────────────────────────────

async function boot() {
  // Cleared first, before anything that can fail. A splash screen sitting over
  // a crashed app is indistinguishable from a hang.
  await configureChrome();

  await store.load();
  setHapticsEnabled(store.get('settings').hapticsEnabled !== false);

  app.node = new SimulatedNode({ building: store.selectedBuilding });
  app.node.connect();
  app.node.on((type, payload) => {
    if (type === 'triggered') {
      beginEvent({
        warningSeconds: app.node.event?.sArrival ?? null,
        magnitude: app.node.event?.magnitude ?? null,
        distanceKm: app.node.event?.distanceKm ?? null,
      });
    }
    if (type === 'connection') store.set('nodeLog', app.node.log.slice(), { persist: false });
  });

  // Keep the node pointed at whichever building is selected.
  store.subscribe('selectedBuildingId', () => {
    app.node.setBuilding(store.selectedBuilding);
  });

  startTicking();
  render();

  // Test hooks, in the same spirit as everything else here: they grant nothing
  // that tapping through the interface would not.
  const params = new URLSearchParams(location.search);
  if (params.get('guest') === '1' && !store.get('account')) {
    store.set('account', { id: 'guest', name: 'Guest', isGuest: true });
  }
  if (params.get('onboarded') === '1') {
    store.set('didCompleteOnboarding', true);
    store.set('didCompleteTutorial', params.get('tour') !== '1');
  }
  render();
  if (params.get('tab') && SECTIONS[params.get('tab')]) navigate(params.get('tab'));
}

window.addEventListener('DOMContentLoaded', boot);

// Exposed for the tour and for screens that need to reach the shell.
window.seismic = { navigate, render, beginEvent, endEvent, store, get node() { return app.node; } };
