// Sign-in, and the first thing anybody sees.
//
// It says what the app is before asking for anything, because a sign-in form
// with no context is a reason to close an app rather than to use one. And
// "Continue without an account" is a first-class option, not fine print: a
// guest account is a real account locally, and nothing in the app is withheld
// for declining.

import { store } from '../state.js';
import { el, button, field, icon, notice, setChildren} from '../ui/dom.js';
import { Haptics } from '../platform.js';

export function renderAuth({ onDone }) {
  let mode = 'signIn';
  let error = null;

  const container = el('main#screen');

  const signIn = (account) => {
    Haptics.notification('SUCCESS');
    store.set('account', account);
    onDone();
  };

  const draw = () => {
    setChildren(container, []);

    const email = field('Email', { type: 'email', placeholder: 'you@example.com' });
    const password = field('Password', { type: 'password', placeholder: 'At least 6 characters' });
    const name = field('Name', { placeholder: 'What should we call you?' });

    const submit = () => {
      const address = email.input.value.trim();
      if (!address.includes('@') || password.input.value.length < 6) {
        error = 'Enter an email address and a password of at least six characters.';
        draw();
        return;
      }
      signIn({
        id: `local-${address}`,
        name: mode === 'signUp' && name.input.value ? name.input.value : address,
        email: address,
        provider: 'email',
        isGuest: false,
      });
    };

    const inner = el('.screen-inner', {
      // Wider margins and a measured column: this is a full screen, not a
      // sheet, and a form running edge to edge on a 6.9-inch phone reads as
      // unfinished.
      style: { maxWidth: '460px', padding: '28px', gap: '20px' },
    }, [
      el('.stack-tight', {}, [
        icon('wave', { size: 34, stroke: 1.3 }),
        el('h1', {
          text: 'SEISMIC',
          style: { fontSize: '1.7rem', fontWeight: '600', letterSpacing: '0.3em' },
        }),
        el('p.body', {
          text: 'Know whether your building is safe to be in — from its own '
            + 'measurements, not from a guess.',
        }),
      ]),

      el('p.body', {
        text: 'Signing in backs up your buildings and lets a household share them. '
          + 'It is not required for anything else.',
      }),

      button('Continue with Apple', () => signIn({
        id: 'apple-local', name: 'Apple account', provider: 'apple', isGuest: false,
      }), { kind: 'secondary', block: true, iconName: 'star' }),

      button('Continue with Google', () => signIn({
        id: 'google-local', name: 'Google account', provider: 'google', isGuest: false,
      }), { kind: 'secondary', block: true, iconName: 'globe' }),

      el('div', { style: { height: '1px', background: 'var(--hairline)' } }),

      el('.segmented', { role: 'tablist' }, [
        el('button', {
          role: 'tab', type: 'button', 'aria-selected': String(mode === 'signIn'),
          on: { click: () => { mode = 'signIn'; error = null; draw(); } },
        }, 'Sign in'),
        el('button', {
          role: 'tab', type: 'button', 'aria-selected': String(mode === 'signUp'),
          on: { click: () => { mode = 'signUp'; error = null; draw(); } },
        }, 'Create an account'),
      ]),

      mode === 'signUp' && name.wrapper,
      email.wrapper,
      password.wrapper,
      error && notice('critical', 'That did not work', error),

      button(mode === 'signIn' ? 'Sign in' : 'Create the account', submit, { block: true }),

      el('p.caption', {
        text: 'Accounts are kept on this device in this build. Nothing is sent anywhere.',
        style: { textAlign: 'center' },
      }),

      button('Continue without an account', () => signIn({
        id: `guest-${Date.now()}`, name: 'Guest', provider: 'guest', isGuest: true,
      }), { kind: 'quiet', block: true }),
    ]);

    container.append(inner);
  };

  draw();
  return container;
}
