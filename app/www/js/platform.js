// The bridge to the device, and what happens when there is no device.
//
// Every capability here has a working path in a plain browser as well as in the
// native shell. That is not only for development convenience: it is the same
// principle the rest of the app follows — nothing is ever a dead end, and a
// missing capability degrades to something that still works rather than to an
// error.
//
// Plugins are reached through `window.Capacitor.Plugins` rather than imported
// from npm, because there is no bundler in this project and the native bridge
// registers them under that global anyway.

const bridge = () => (typeof window !== 'undefined' ? window.Capacitor : undefined);

export const isNative = () => Boolean(bridge()?.isNativePlatform?.());

function plugin(name) {
  return bridge()?.Plugins?.[name] ?? null;
}

// ── Preferences ────────────────────────────────────────────────────────────

export const Preferences = {
  async set({ key, value }) {
    const native = plugin('Preferences');
    if (native) return native.set({ key, value });
    try { localStorage.setItem(key, value); } catch { /* private mode, quota */ }
    return undefined;
  },
  async get({ key }) {
    const native = plugin('Preferences');
    if (native) return native.get({ key });
    try { return { value: localStorage.getItem(key) }; } catch { return { value: null }; }
  },
  async remove({ key }) {
    const native = plugin('Preferences');
    if (native) return native.remove({ key });
    try { localStorage.removeItem(key); } catch { /* ignore */ }
    return undefined;
  },
};

// ── Haptics ────────────────────────────────────────────────────────────────
//
// Silent when unavailable. A missing vibration is never worth an error, and on
// the web there is nothing sensible to fall back to.

let hapticsEnabled = true;
export function setHapticsEnabled(value) { hapticsEnabled = Boolean(value); }

export const Haptics = {
  selection() { this.impact('Light'); },
  impact(style = 'Medium') {
    if (!hapticsEnabled) return;
    const native = plugin('Haptics');
    if (native?.impact) native.impact({ style }).catch(() => {});
    else if (navigator.vibrate) navigator.vibrate(style === 'Heavy' ? 24 : 10);
  },
  notification(type = 'SUCCESS') {
    if (!hapticsEnabled) return;
    const native = plugin('Haptics');
    if (native?.notification) native.notification({ type }).catch(() => {});
    else if (navigator.vibrate) navigator.vibrate([12, 40, 12]);
  },
  /** The escalating countdown tick. Closer to zero, harder the tap. */
  countdown(secondsRemaining) {
    if (secondsRemaining <= 3) this.impact('Heavy');
    else if (secondsRemaining <= 6) this.impact('Medium');
    else this.impact('Light');
  },
};

// ── Speech ─────────────────────────────────────────────────────────────────
//
// The device's own voice, always. During an earthquake the local voice is the
// better product regardless of budget: it cannot be delayed by the congested
// cell tower the earthquake just congested.

export const Speech = {
  speak(text, { urgent = false } = {}) {
    if (!text || typeof speechSynthesis === 'undefined') return;
    try {
      if (urgent) speechSynthesis.cancel();
      const utterance = new SpeechSynthesisUtterance(text);
      utterance.rate = urgent ? 1.05 : 0.96;
      utterance.pitch = urgent ? 0.95 : 1;
      utterance.lang = 'en-GB';
      speechSynthesis.speak(utterance);
    } catch { /* a voice that will not speak must not stop the app */ }
  },
  stop() {
    try { speechSynthesis?.cancel(); } catch { /* ignore */ }
  },
};

// ── Geolocation ────────────────────────────────────────────────────────────

export const Location = {
  async current() {
    const native = plugin('Geolocation');
    try {
      if (native) {
        const position = await native.getCurrentPosition({ timeout: 8000 });
        return { latitude: position.coords.latitude, longitude: position.coords.longitude };
      }
      if (navigator.geolocation) {
        return await new Promise((resolve, reject) => {
          navigator.geolocation.getCurrentPosition(
            (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
            reject,
            { timeout: 8000 },
          );
        });
      }
    } catch { /* declined, timed out, or unavailable */ }
    return null;
  },
};

// ── Notifications ──────────────────────────────────────────────────────────

export const Notifications = {
  async request() {
    const native = plugin('LocalNotifications');
    if (!native) return false;
    try {
      const result = await native.requestPermissions();
      return result?.display === 'granted';
    } catch { return false; }
  },
  async post({ title, body }) {
    const native = plugin('LocalNotifications');
    if (!native) return;
    try {
      await native.schedule({
        notifications: [{
          title,
          body,
          // A stable-ish id derived from the clock: two assessments a second
          // apart should not collapse into one notification.
          id: Math.floor(Date.now() / 1000) % 2_000_000_000,
          schedule: { at: new Date(Date.now() + 200) },
        }],
      });
    } catch { /* declined */ }
  },
};

// ── Share ──────────────────────────────────────────────────────────────────

export const Share = {
  async send({ title, text, url }) {
    const native = plugin('Share');
    try {
      if (native) { await native.share({ title, text, url }); return true; }
      if (navigator.share) { await navigator.share({ title, text, url }); return true; }
      await navigator.clipboard?.writeText([text, url].filter(Boolean).join('\n'));
      return true;
    } catch { return false; }
  },
};

// ── Camera ─────────────────────────────────────────────────────────────────

export const Camera = {
  async take() {
    const native = plugin('Camera');
    if (native) {
      try {
        const photo = await native.getPhoto({
          quality: 82,
          resultType: 'dataUrl',
          source: 'PROMPT',
          // 2048 is plenty to see a crack width and small enough that a hundred
          // photographs do not fill somebody's phone.
          width: 2048,
        });
        return photo?.dataUrl ?? null;
      } catch { return null; }
    }
    // In a browser, an ordinary file input does the same job.
    return new Promise((resolve) => {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = 'image/*';
      input.capture = 'environment';
      input.onchange = () => {
        const file = input.files?.[0];
        if (!file) { resolve(null); return; }
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result));
        reader.onerror = () => resolve(null);
        reader.readAsDataURL(file);
      };
      input.click();
    });
  },
};

// ── Status bar ─────────────────────────────────────────────────────────────

export async function configureChrome() {
  const status = plugin('StatusBar');
  if (status) {
    try {
      await status.setStyle({ style: 'DARK' });
      await status.setBackgroundColor({ color: '#0a0b0d' });
    } catch { /* not every platform supports it */ }
  }
  const splash = plugin('SplashScreen');
  if (splash) {
    try { await splash.hide(); } catch { /* ignore */ }
  }
}

// ── Network ────────────────────────────────────────────────────────────────

export const Network = {
  get online() { return navigator.onLine !== false; },
  onChange(handler) {
    const fire = () => handler(this.online);
    window.addEventListener('online', fire);
    window.addEventListener('offline', fire);
    return () => {
      window.removeEventListener('online', fire);
      window.removeEventListener('offline', fire);
    };
  },
};
