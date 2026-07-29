// The people who need to know, and whether they are all right.
//
// Roles are about authority over the building, not hierarchy: a viewer sees
// everything and can fire nothing, which is exactly the right shape for a
// worried relative three hundred miles away.

import { store } from '../state.js';
import {
  el, panel, button, pill, icon, field, sheet, notice, emptyState, relativeTime,
} from '../ui/dom.js';
import { Share, Haptics } from '../platform.js';

const ROLES = {
  owner: 'Owner — can do anything, including firing actuators',
  adult: 'Adult — can check in and acknowledge, cannot fire actuators',
  child: 'Child — check-in only',
  viewer: 'Viewer — sees everything, controls nothing',
};

export function renderHousehold({ rerender }) {
  const household = store.get('household');
  const account = store.get('account');
  const container = el('.stack', { style: { gap: '16px' } });

  container.append(panel('Account', [
    el('.hstack', {}, [
      el('.row-icon', {}, [icon('people', { size: 20 })]),
      el('.stack-tight', { style: { flex: '1' } }, [
        el('.headline', { text: account?.name ?? 'Not signed in' }),
        el('.caption', { text: account?.email ?? account?.provider ?? '' }),
      ]),
      account?.isGuest ? pill('Guest') : pill('Signed in', 'accent'),
    ]),
    account?.isGuest && notice('info', 'You are using this without an account',
      'Everything works. Your buildings and assessments live on this device only, and '
      + 'are not backed up. Signing in later keeps everything you have already done.'),
    button('Sign out', () => {
      store.set('account', null);
      window.seismic.render();
    }, { kind: 'quiet' }),
  ], { iconName: 'people' }));

  if (!household) {
    container.append(emptyState({
      iconName: 'people',
      title: 'No household yet',
      message: 'A household is the people who should be told when your building has been '
        + 'shaken — and who can check in so you know they are all right.',
      actionTitle: 'Create a household',
      action: () => {
        store.set('household', {
          id: `household-${Date.now()}`,
          name: 'My household',
          inviteCode: randomCode(),
          members: [{
            id: 'me', name: account?.name ?? 'You', role: 'owner',
            checkedInAt: null, status: 'unknown', phone: '',
          }],
        });
        Haptics.notification('SUCCESS');
        rerender();
      },
    }));
    return container;
  }

  const unaccounted = household.members.filter((m) => m.status === 'unknown');
  const needHelp = household.members.filter((m) => m.status === 'needsHelp');

  container.append(panel('Check-in', [
    needHelp.length > 0
      ? notice('critical', `${needHelp.length} asked for help`,
        needHelp.map((m) => m.name).join(', '))
      : unaccounted.length === 0
        ? notice('info', 'Everyone has checked in',
          `All ${household.members.length} accounted for.`)
        : notice('warning', `${unaccounted.length} have not checked in`,
          `${unaccounted.map((m) => m.name).join(', ')}. Send them a message, or mark them `
          + 'safe if you have heard.'),

    unaccounted.length > 0 && button('Message them', async () => {
      const sent = await Share.send({
        title: 'Are you safe?',
        text: 'There has been an earthquake. Please reply to say you are all right.',
      });
      // No SMS gateway is configured, so the message is handed to the share
      // sheet rather than silently doing nothing.
      if (!sent) window.alert('Copy this and send it yourself:\n\nAre you safe?');
    }, { kind: 'secondary', block: true, iconName: 'share' }),
  ], { iconName: 'checklist' }));

  container.append(panel('Members', [
    el('.stack', {}, household.members.map((member) => el('.row', {}, [
      el('.row-icon', {}, [icon('people', { size: 19 })]),
      el('.row-text', {}, [
        el('.row-title', { text: member.name }),
        el('.caption', { text: ROLES[member.role] ?? member.role }),
        member.checkedInAt && el('.caption', {
          text: `Checked in ${relativeTime(member.checkedInAt)}`,
        }),
      ]),
      el('.hstack', {}, [
        button('Safe', () => {
          updateMember(household, member.id, { status: 'safe', checkedInAt: Date.now() });
          Haptics.notification('SUCCESS');
          window.seismic.render();
        }, { kind: 'secondary' }),
      ]),
    ]))),
    button('Add someone', () => addMember(household), { block: true, iconName: 'plus' }),
  ], { iconName: 'people' }));

  container.append(panel('Invite', [
    el('.center', {}, [
      el('.readout-value.large.mono', {
        text: household.inviteCode,
        style: { letterSpacing: '0.35em' },
      }),
    ]),
    el('p.caption', {
      text: 'Read the six characters out, or share the link. Both do the same thing — '
        + 'the typed version exists because a camera is no use over the phone.',
    }),
    button('Share the link', () => Share.send({
      title: 'Join my household on Seismic',
      text: `Use the code ${household.inviteCode}`,
    }), { kind: 'secondary', block: true, iconName: 'share' }),
  ], { iconName: 'share' }));

  return container;
}

function updateMember(household, id, changes) {
  const members = household.members.map((m) => (m.id === id ? { ...m, ...changes } : m));
  store.set('household', { ...household, members });
}

function addMember(household) {
  const name = field('Name', { placeholder: 'Who is it?' });
  const phone = field('Phone (optional)', { type: 'tel', placeholder: 'For escalation' });
  let role = 'adult';

  const roleRow = el('.stack-tight', {}, [
    el('label', { text: 'ROLE', style: { fontSize: '0.72rem', color: 'var(--text-tertiary)' } }),
    el('.stack', {}, Object.entries(ROLES).map(([key, description]) => el('button.row', {
      type: 'button',
      style: key === role ? { borderColor: 'var(--accent)' } : {},
      on: {
        click: (event) => {
          role = key;
          event.currentTarget.parentElement.querySelectorAll('.row').forEach((node) => {
            node.style.borderColor = '';
          });
          event.currentTarget.style.borderColor = 'var(--accent)';
        },
      },
    }, [el('.row-text', {}, [el('.caption', { text: description })])]))),
  ]);

  const close = sheet('Add someone', [
    name.wrapper,
    phone.wrapper,
    roleRow,
    button('Add', () => {
      if (!name.input.value.trim()) return;
      store.set('household', {
        ...household,
        members: [...household.members, {
          id: `member-${Date.now()}`,
          name: name.input.value.trim(),
          phone: phone.input.value.trim(),
          role,
          status: 'unknown',
          checkedInAt: null,
        }],
      });
      Haptics.notification('SUCCESS');
      close();
      window.seismic.render();
    }, { block: true }),
  ]);
}

function randomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i += 1) {
    code += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return code;
}
