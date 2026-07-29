// Settings, and an honest account of what this build can and cannot do.

import { store } from '../state.js';
import {
  el, panel, button, toggleRow, notice, readout, readoutGrid, pill, icon,
} from '../ui/dom.js';
import { setHapticsEnabled, isNative, Notifications, Speech } from '../platform.js';

export function renderSettings({ navigate, rerender }) {
  const settings = store.get('settings');
  const container = el('.stack', { style: { gap: '16px' } });

  const update = (key, value) => {
    store.set('settings', { ...store.get('settings'), [key]: value });
  };

  container.append(
    panel('Voice and feedback', [
      toggleRow('Speak assessments out loud',
        'Uses the device\'s own voice, which works offline — and cannot be delayed by '
        + 'the congested cell tower the earthquake just congested.',
        settings.speaksAutomatically !== false,
        (value) => update('speaksAutomatically', value)),
      toggleRow('Haptics', 'Taps for selections, and an escalating countdown during an event.',
        settings.hapticsEnabled !== false,
        (value) => { update('hapticsEnabled', value); setHapticsEnabled(value); }),
      button('Test the voice', () => Speech.speak(
        'This is how an assessment will be read out. Restricted use. Something changed, '
        + 'and it should be looked at before the building is used normally again.',
      ), { kind: 'secondary', block: true, iconName: 'wave' }),
    ], { iconName: 'wave' }),

    panel('Alerts', [
      el('p.body', {
        text: 'Local notifications work with no server and no account. Push alerts for '
          + 'early warning would need both, and this build has neither — so nothing here '
          + 'pretends to give you seconds of warning it cannot deliver.',
      }),
      button('Enable notifications', async () => {
        const granted = await Notifications.request();
        window.alert(granted
          ? 'Notifications enabled.'
          : 'Notifications were declined. Everything else is unaffected.');
      }, { kind: 'secondary', block: true }),
    ], { iconName: 'warning' }),

    panel('Demonstration', [
      button('Replay the introduction', () => {
        store.set('didCompleteOnboarding', false);
        window.seismic.render();
      }, { kind: 'secondary', block: true, iconName: 'refresh' }),
      button('Take the guided tour again', () => {
        store.set('didCompleteTutorial', false);
        navigate('home');
      }, { kind: 'secondary', block: true, iconName: 'hand' }),
    ], { iconName: 'play' }),

    panel('This build', [
      readoutGrid([
        readout('Platform', isNative() ? 'Native (Capacitor)' : 'Web'),
        readout('Buildings', String(store.get('buildings').length)),
        readout('Assessments', String(store.get('assessments').length)),
        readout('Queued to sync', String(store.get('syncQueue').length)),
      ]),
      el('p.caption', {
        text: 'Everything runs on this device: the signal processing, the structural '
          + 'solver and the 3D. Nothing here needs a network or an API key.',
      }),
    ], { iconName: 'info' }),

    panel('What this build does not do', [
      ...[
        ['No live building import', 'The bundled reference library answers instead, and '
          + 'anything you describe is modelled from what you enter.'],
        ['No cloud sync', 'Changes are queued locally and nothing is lost; there is simply '
          + 'no server behind it yet.'],
        ['No Bluetooth node', 'The simulated node runs the same physics real hardware '
          + 'would be measuring.'],
        ['Not an engineering assessment', 'It is evidence, and good evidence. It is not a '
          + 'substitute for an engineer where one is available.'],
      ].map(([title, detail]) => el('.stack-tight', {}, [
        el('.hstack', {}, [icon('info', { size: 15 }), el('.headline', { text: title })]),
        el('p.caption', { text: detail }),
      ])),
    ], { iconName: 'document' }),

    panel('Data', [
      button('Reset everything', () => {
        // eslint-disable-next-line no-alert
        if (!window.confirm('This deletes your buildings, assessments and household. '
          + 'It cannot be undone.')) return;
        localStorage.clear();
        location.reload();
      }, { kind: 'danger', block: true }),
    ], { iconName: 'warning' }),
  );

  return container;
}
