// Recent earthquakes worldwide.
//
// The USGS feed needs no key. When it is unreachable the screen falls back to
// the bundled historic set rather than showing an error, because "no network"
// is the normal condition immediately after an earthquake.

import { store } from '../state.js';
import { el, panel, button, pill, icon, notice, relativeTime, setChildren} from '../ui/dom.js';

const USGS = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson';

export function renderFeed() {
  const container = el('.stack', { style: { gap: '16px' } });
  const list = el('.stack');
  const status = el('div');

  const drawHistoric = (note) => {
    setChildren(status, [notice('info', 'Showing the bundled record', note)]);
    setChildren(list, [...store.get('earthquakes').map((quake) => el('.row', {}, [
      el('.row-icon', {}, [icon('globe', { size: 20 })]),
      el('.row-text', {}, [
        el('.row-title', { text: `${quake.name} ${quake.year}` }),
        el('.caption', { text: quake.note }),
      ]),
      pill(`M${quake.magnitude}`, quake.magnitude >= 7 ? 'red' : 'amber'),
    ]))]);
  };

  const load = async () => {
    setChildren(status, [el('p.caption', { text: 'Checking the USGS feed…' })]);
    try {
      const controller = new AbortController();
      // A feed that has not answered in eight seconds is not going to.
      const timeout = setTimeout(() => controller.abort(), 8000);
      const response = await fetch(USGS, { signal: controller.signal });
      clearTimeout(timeout);
      if (!response.ok) throw new Error(String(response.status));

      const data = await response.json();
      const features = (data.features ?? []).slice(0, 25);
      if (features.length === 0) throw new Error('empty');

      setChildren(status, [el('.hstack', {}, [
        pill('Live · USGS', 'accent'),
        el('.caption', { text: `${features.length} events in the last day` }),
      ])]);

      setChildren(list, [...features.map((feature) => {
        const magnitude = feature.properties.mag ?? 0;
        return el('.row', {}, [
          el('.row-icon', {}, [icon('globe', { size: 20 })]),
          el('.row-text', {}, [
            el('.row-title', { text: feature.properties.place ?? 'Unknown location' }),
            el('.caption', { text: relativeTime(feature.properties.time) }),
          ]),
          pill(`M${magnitude.toFixed(1)}`,
            magnitude >= 6 ? 'red' : magnitude >= 4.5 ? 'amber' : ''),
        ]);
      })]);
    } catch {
      drawHistoric('The live feed did not answer. These are the reference events the '
        + 'simulator uses, which need no network at all.');
    }
  };

  container.append(
    panel('Recent earthquakes', [status, list], {
      iconName: 'globe',
      trailing: button('Refresh', load, { kind: 'quiet' }),
    }),
  );

  load();
  return container;
}
