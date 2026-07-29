// The node: connection, safety actuators, power budget and self-test.
//
// The actuator controls get full-size targets. These close somebody's gas
// supply — a cramped chip is the wrong control for that.

import { store } from '../state.js';
import {
  el, panel, readout, readoutGrid, button, pill, icon, notice, relativeTime, setChildren,} from '../ui/dom.js';
import { ACTUATORS } from '../core/node.js';
import { Haptics } from '../platform.js';

export function renderNode({ node, onCleanup }) {
  const container = el('.stack', { style: { gap: '18px' } });
  const connection = el('.stack');
  const actuators = el('.stack');
  const power = el('.stack');
  const logList = el('.stack-tight');
  const selfTestSlot = el('div');

  const drawConnection = (snapshot) => {
    setChildren(connection, [
      readoutGrid([
        readout('Node', snapshot.nodeName),
        readout('State', capitalise(snapshot.state)),
        readout('Dropped batches', String(snapshot.droppedBatches)),
        readout('Buffered samples', String(snapshot.bufferedSamples)),
      ]),
      el('.hstack', {}, [
        button('Scan for hardware', () => {
          Haptics.selection();
          window.alert('Bluetooth scanning needs the app running on a device with a node '
            + 'in range. The simulated node behaves identically in the meantime.');
        }, { kind: 'secondary' }),
        button('Use simulator', () => { node.connect(); Haptics.selection(); },
          { kind: 'secondary' }),
      ]),
    ]);
  };

  const drawActuators = (snapshot) => {
    setChildren(actuators, [...Object.entries(ACTUATORS).map(([kind, spec]) => {
      const state = snapshot.actuators[kind];
      const tone = state.state === 'confirmed' ? 'green'
        : state.state === 'unconfirmed' ? 'amber'
          : state.state === 'inProgress' ? 'accent' : '';
      return el('.stack-tight', { style: { paddingBottom: '10px' } }, [
        el('.hstack', {}, [
          icon(spec.icon, { size: 20 }),
          el('.stack-tight', { style: { flex: '1' } }, [
            el('.headline', { text: spec.label }),
            el('.caption', { text: capitalise(state.state) }),
          ]),
          // Full 44pt targets, and the padding is on the button so the filled
          // background wraps the label rather than hugging it.
          button('Fire', () => { node.fire(kind); Haptics.impact('Heavy'); },
            { kind: 'secondary' }),
          button('Reset', () => { node.reset(kind); Haptics.selection(); },
            { kind: 'secondary' }),
        ]),
        el('.provenance', {}, [icon('info', { size: 13 }),
          `Will be confirmed by: ${spec.confirmedBy}`]),
        tone && pill(capitalise(state.state), tone),
      ]);
    })]);
  };

  const drawPower = () => {
    const budget = node.powerBudget;
    const fraction = Math.min(budget.drawn / budget.supply, 1);
    setChildren(power, [
      el('div', {
        style: {
          height: '8px', borderRadius: '4px', background: 'var(--surface-highest)',
          overflow: 'hidden',
        },
      }, [el('div', {
        style: {
          width: `${fraction * 100}%`, height: '100%', background: 'var(--accent)',
          transition: 'width 0.2s',
        },
      })]),
      el('.hstack', {}, [
        el('.mono.caption', { text: `${budget.drawn} mA drawn`, style: { flex: '1' } }),
        el('.mono.caption', { text: `${budget.supply} mA available` }),
      ]),
      el('p.caption', {
        text: `${budget.supply} mA supply, ${budget.quiescent} mA quiescent, `
          + `${budget.reserve} mA reserved against brownout, leaving ${budget.available} mA `
          + 'for actuation. Only one motor may move at a time, so actions fire in sequence.',
      }),
    ]);
  };

  container.append(
    panel('Connection', [connection], {
      iconName: 'sensor', trailing: pill('Simulated node', 'violet'),
    }),
    panel('Safety actuators', [actuators], { iconName: 'flame' }),
    panel('Power budget', [power], { iconName: 'bolt' }),
    panel('Self-test', [
      selfTestSlot,
      button('Run a self-test', () => {
        const result = node.selfTest();
        Haptics.notification('SUCCESS');
        setChildren(selfTestSlot, [
          notice(result.passed ? 'info' : 'warning', result.summary, null),
          el('.stack-tight', {}, result.checks.map((check) => el('.hstack', {}, [
            icon(check.passed ? 'check' : 'warning', { size: 16 }),
            el('.body', { text: check.name, style: { flex: '1' } }),
            el('.caption', { text: check.detail }),
          ]))),
        ]);
      }, { block: true, kind: 'secondary' }),
    ], { iconName: 'check' }),
    panel('Log', [logList], { iconName: 'document' }),
  );

  const paint = (snapshot) => {
    if (!snapshot || !container.isConnected) return;
    drawConnection(snapshot);
    drawActuators(snapshot);
    drawPower();
    setChildren(logList, [...node.log.slice(0, 20).map((line) => el('.hstack', {}, [
      el('.caption.mono', { text: relativeTime(line.at), style: { width: '78px', flex: 'none' } }),
      el('.caption', { text: line.text }),
    ]))]);
  };

  paint(store.get('node'));
  const unsubscribe = store.subscribe('node', paint);
  onCleanup(unsubscribe);
  return container;
}

function capitalise(text) {
  const value = String(text ?? '');
  return value.charAt(0).toUpperCase() + value.slice(1);
}
