// The application's state, in one place.
//
// A small observable store rather than a framework. Everything the app knows
// lives here; screens read from it and subscribe to the slices they care about.
//
// The subscription is per-key on purpose. The node snapshot is replaced twenty
// times a second, and a store that notified every listener on every change
// would re-render the map and the settings screen at 20 Hz to draw data neither
// of them shows. Screens subscribe to 'node' only if they draw live motion.

import { Preferences } from './platform.js';
import { SEED_BUILDINGS, EARTHQUAKES } from './core/library.js';

const STORAGE_KEY = 'seismic.state.v1';

class Store {
  constructor() {
    this.data = {
      account: null,
      didCompleteOnboarding: false,
      didCompleteTutorial: false,

      buildings: SEED_BUILDINGS.map((b) => ({ ...b })),
      selectedBuildingId: SEED_BUILDINGS[0].id,
      events: [],
      assessments: [],
      observations: [],
      tags: [],
      notes: [],
      household: null,
      earthquakes: EARTHQUAKES,

      node: null,
      nodeLog: [],
      activeEvent: null,
      syncQueue: [],
      settings: {
        speaksAutomatically: true,
        hapticsEnabled: true,
        units: 'metric',
        exaggeration: 40,
      },
    };
    this.listeners = new Map();
    this.saveTimer = null;
  }

  get(key) { return this.data[key]; }

  /**
   * Writes a value and notifies only that key's subscribers.
   *
   * `persist: false` for anything replaced at display rate — writing the node
   * snapshot to disk twenty times a second would be pointless wear and would
   * block the main thread on serialisation.
   */
  set(key, value, { persist = true } = {}) {
    this.data[key] = value;
    const handlers = this.listeners.get(key);
    if (handlers) for (const handler of handlers) handler(value);
    if (persist) this.scheduleSave();
  }

  update(key, mutate) {
    this.set(key, mutate(this.data[key]));
  }

  subscribe(key, handler) {
    if (!this.listeners.has(key)) this.listeners.set(key, new Set());
    this.listeners.get(key).add(handler);
    return () => this.listeners.get(key)?.delete(handler);
  }

  get selectedBuilding() {
    return this.data.buildings.find((b) => b.id === this.data.selectedBuildingId)
      ?? this.data.buildings[0]
      ?? null;
  }

  get latestAssessment() {
    const id = this.data.selectedBuildingId;
    return this.data.assessments
      .filter((a) => a.buildingId === id)
      .sort((a, b) => b.createdAt - a.createdAt)[0] ?? null;
  }

  eventsForSelected() {
    const id = this.data.selectedBuildingId;
    return this.data.events
      .filter((e) => e.buildingId === id)
      .sort((a, b) => b.startedAt - a.startedAt);
  }

  // MARK: Persistence

  scheduleSave() {
    // Coalesced: a burst of edits during an import is one write, not thirty.
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.save(), 400);
  }

  async save() {
    const { node, ...persistable } = this.data;
    try {
      await Preferences.set({ key: STORAGE_KEY, value: JSON.stringify(persistable) });
    } catch (error) {
      // Storage being full or unavailable must never take the app down. The
      // session continues in memory; the user loses persistence, not their work.
      console.warn('Could not save state:', error);
    }
  }

  async load() {
    try {
      const { value } = await Preferences.get({ key: STORAGE_KEY });
      if (!value) return;
      const stored = JSON.parse(value);

      // Merged rather than replaced, so a build that adds a field does not
      // wipe an existing install's data by finding it absent.
      this.data = {
        ...this.data,
        ...stored,
        settings: { ...this.data.settings, ...(stored.settings ?? {}) },
        earthquakes: EARTHQUAKES,
        node: null,
      };

      // A stored library missing the seeds is a library from an older version.
      if (!Array.isArray(this.data.buildings) || this.data.buildings.length === 0) {
        this.data.buildings = SEED_BUILDINGS.map((b) => ({ ...b }));
      }
      if (!this.selectedBuilding) {
        this.data.selectedBuildingId = this.data.buildings[0]?.id ?? null;
      }
    } catch (error) {
      console.warn('Stored state was unreadable, starting fresh:', error);
    }
  }

  /** Queues a change for upload. Nothing is lost while signed out. */
  enqueueSync(kind, id) {
    const queue = this.data.syncQueue.filter((i) => !(i.kind === kind && i.id === id));
    queue.push({ kind, id, at: Date.now() });
    this.set('syncQueue', queue);
  }
}

export const store = new Store();
