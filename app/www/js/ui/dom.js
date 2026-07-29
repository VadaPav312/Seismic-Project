// Building blocks.
//
// A tiny element helper instead of a template language. The whole interface is
// built from these, which keeps every screen's markup visible in one place and
// avoids shipping a framework to do what four lines of DOM already do.

/**
 * @param spec 'div.class#id' — tag, then any number of classes, then an id.
 * @param props attributes; `text`, `html`, `on` and `dataset` are special.
 * @param children strings and nodes, nested arrays flattened, null skipped.
 */
export function el(spec, props = {}, children = []) {
  const match = /^([a-zA-Z0-9-]+)?((?:\.[^.#]+)*)(?:#([^.#]+))?$/.exec(spec) ?? [];
  const tag = match[1] || 'div';
  const node = document.createElement(tag);

  if (match[2]) {
    for (const name of match[2].split('.').filter(Boolean)) node.classList.add(name);
  }
  if (match[3]) node.id = match[3];

  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'text') node.textContent = value;
    else if (key === 'html') node.innerHTML = value;
    else if (key === 'on') {
      for (const [event, handler] of Object.entries(value)) node.addEventListener(event, handler);
    } else if (key === 'dataset') {
      for (const [name, item] of Object.entries(value)) node.dataset[name] = item;
    } else if (key === 'class') {
      for (const name of String(value).split(/\s+/).filter(Boolean)) node.classList.add(name);
    } else if (key === 'style' && typeof value === 'object') {
      Object.assign(node.style, value);
    } else if (value === true) {
      node.setAttribute(key, '');
    } else {
      node.setAttribute(key, value);
    }
  }

  append(node, children);
  return node;
}

export function append(parent, children) {
  const list = Array.isArray(children) ? children : [children];
  for (const child of list) {
    if (child === null || child === undefined || child === false) continue;
    if (Array.isArray(child)) { append(parent, child); continue; }
    parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return parent;
}

/**
 * Replaces a node's children, skipping anything falsy.
 *
 * `Node.replaceChildren` stringifies whatever it is given, so a conditional
 * child that evaluates to null becomes the literal text "null" on screen. Every
 * conditional render in this app goes through here instead.
 */
export function setChildren(node, children) {
  clear(node);
  append(node, children);
  return node;
}

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

/**
 * Inline SF-Symbols-like glyphs.
 *
 * Drawn as paths rather than loaded as a font: an icon font is another file to
 * fetch and a flash of missing glyphs on first paint, and this app has to be
 * legible the instant it opens.
 */
const ICONS = {
  home: 'M3 11.2 12 4l9 7.2V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
  wave: 'M2 12h3l2-7 4 14 3-9 2 4 2-2h4',
  cube: 'M12 2 3 7v10l9 5 9-5V7zM3 7l9 5 9-5M12 12v10',
  map: 'M9 3 3 5.5v16L9 19l6 2.5 6-2.5v-16L15 5.5zM9 3v16m6-13.5v16',
  building: 'M4 21V4a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v17M14 21V9h5a1 1 0 0 1 1 1v11M7 7h3M7 11h3M7 15h3M17 13h1M17 17h1M2 21h20',
  shield: 'M12 3 5 6v6c0 5 3 8 7 9 4-1 7-4 7-9V6z',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z',
  checklist: 'M4 6l2 2 3-3M4 13l2 2 3-3M4 20l2 2 3-3M12 6h9M12 14h9M12 21h9',
  people: 'M8 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2 21c0-3.3 2.7-6 6-6s6 2.7 6 6M17 11a3 3 0 1 0 0-6M17 15c2.8 0 5 2.2 5 5',
  network: 'M12 3a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM5 16a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM19 16a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM11 7.5 6.5 15M13 7.5 17.5 15M7.5 18.5h9',
  slider: 'M4 8h16M4 16h16M9 5v6M15 13v6',
  analysis: 'M3 20V8m5 12V4m5 16v-7m5 7V10M2 20h20',
  gear: 'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z',
  sensor: 'M12 13a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM8.5 15.5a5 5 0 0 1 0-7M15.5 8.5a5 5 0 0 1 0 7M5.5 18.5a9 9 0 0 1 0-13M18.5 5.5a9 9 0 0 1 0 13',
  more: 'M6 12h.01M12 12h.01M18 12h.01',
  plus: 'M12 5v14M5 12h14',
  pause: 'M9 5v14M15 5v14',
  play: 'M7 4l12 8-12 8z',
  chevron: 'M9 6l6 6-6 6',
  close: 'M6 6l12 12M18 6L6 18',
  check: 'M4 12l5 5L20 6',
  flame: 'M12 22c4 0 6-2.7 6-6 0-4-3-6-4-10-2 2-2.5 4-2.5 4S10 8 9 6c-1 2-3 4-3 8 0 3.3 2 8 6 8z',
  bolt: 'M13 2 4 14h6l-1 8 9-12h-6z',
  drop: 'M12 3s6 6.6 6 10.5A6 6 0 0 1 6 13.5C6 9.6 12 3 12 3z',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM16 16l5 5',
  star: 'M12 3l2.6 5.6 6 .8-4.4 4.2 1.1 6-5.3-3-5.3 3 1.1-6L3.4 9.4l6-.8z',
  camera: 'M4 8h3l2-3h6l2 3h3v11H4zM12 16.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z',
  info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5M12 7.5h.01',
  warning: 'M12 3 2 20h20zM12 10v5M12 17.5h.01',
  scope: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v10M7 12h10',
  refresh: 'M20 12a8 8 0 1 1-2.6-5.9M20 4v5h-5',
  hand: 'M9 11V5.5a1.5 1.5 0 0 1 3 0V11m0-1.5V5a1.5 1.5 0 0 1 3 0v6m0-3.5a1.5 1.5 0 0 1 3 0V15c0 3.9-2.6 6-6 6s-6-2.1-6-6v-2.5a1.5 1.5 0 0 1 3 0',
  share: 'M12 15V3M8 7l4-4 4 4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4',
  document: 'M6 3h8l4 4v14H6zM14 3v4h4',
  temperature: 'M12 15.5V4a2 2 0 1 1 4 0v11.5a4 4 0 1 1-4 0z',
};

export function icon(name, { size = 20, stroke = 1.8 } = {}) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', stroke);
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');

  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', ICONS[name] ?? ICONS.info);
  svg.append(path);
  return svg;
}

// ── Composites ─────────────────────────────────────────────────────────────

export function panel(label, children, { iconName = null, trailing = null } = {}) {
  return el('section.panel', {}, [
    label && el('.panel-header', {}, [
      el('.panel-label', {}, [iconName && icon(iconName, { size: 15 }), label]),
      trailing,
    ]),
    ...(Array.isArray(children) ? children : [children]),
  ]);
}

export function readout(label, value, { unit = null, large = false, tint = null } = {}) {
  return el('div', {}, [
    el('.readout-label', { text: label }),
    el(`.readout-value${large ? '.large' : ''}`, {
      style: tint ? { color: tint } : {},
    }, [value, unit && el('span.unit', { text: unit })]),
  ]);
}

export function readoutGrid(items) {
  return el('.readout-grid', {}, items);
}

export function button(label, onClick, {
  kind = 'primary', block = false, iconName = null, disabled = false,
} = {}) {
  return el(`button.btn.btn-${kind}${block ? '.block' : ''}`, {
    on: { click: onClick },
    disabled,
    type: 'button',
  }, [iconName && icon(iconName, { size: 18 }), label]);
}

export function pill(text, tone = '') {
  return el(`span.pill${tone ? `.${tone}` : ''}`, { text });
}

export function notice(level, title, body, action = null) {
  const iconName = level === 'critical' ? 'warning' : level === 'warning' ? 'warning' : 'info';
  return el(`.notice${level && level !== 'info' ? `.${level}` : ''}`, {}, [
    icon(iconName, { size: 19 }),
    el('.notice-body', {}, [
      el('.notice-title', { text: title }),
      body && el('.body', { text: body }),
      action,
    ]),
  ]);
}

export function emptyState({
  iconName, title, message, actionTitle, action, secondaryTitle, secondaryAction,
}) {
  return el('.empty', {}, [
    el('.empty-icon', {}, [icon(iconName, { size: 40, stroke: 1.4 })]),
    el('h2.title', { text: title }),
    el('p.body', { text: message }),
    actionTitle && button(actionTitle, action, { block: true }),
    secondaryTitle && button(secondaryTitle, secondaryAction, { kind: 'quiet' }),
  ]);
}

export function segmented(options, selected, onSelect) {
  return el('.segmented', { role: 'tablist' }, options.map((option) => el('button', {
    role: 'tab',
    'aria-selected': String(option.value === selected),
    on: { click: () => onSelect(option.value) },
    type: 'button',
  }, option.label)));
}

export function toggleRow(label, description, checked, onChange) {
  const toggle = el('button.toggle', {
    role: 'switch',
    'aria-checked': String(checked),
    'aria-label': label,
    type: 'button',
  });
  toggle.addEventListener('click', () => {
    const next = toggle.getAttribute('aria-checked') !== 'true';
    toggle.setAttribute('aria-checked', String(next));
    onChange(next);
  });
  return el('.toggle-row', {}, [
    el('.stack-tight', {}, [
      el('.headline', { text: label }),
      description && el('.caption', { text: description }),
    ]),
    toggle,
  ]);
}

export function field(label, { value = '', type = 'text', placeholder = '', onInput = null } = {}) {
  const input = el('input', { type, value, placeholder });
  if (onInput) input.addEventListener('input', () => onInput(input.value));
  return { wrapper: el('.field', {}, [el('label', { text: label }), input]), input };
}

export function row({ iconName, title, subtitle, trailing, onClick, badge }) {
  return el(onClick ? 'button.row' : 'div.row', {
    on: onClick ? { click: onClick } : {},
    type: onClick ? 'button' : null,
  }, [
    iconName && el('.row-icon', {}, [icon(iconName, { size: 21 })]),
    el('.row-text', {}, [
      el('.row-title', { text: title }),
      subtitle && el('.caption', { text: subtitle }),
      badge,
    ]),
    trailing ?? (onClick ? el('.row-chevron', {}, [icon('chevron', { size: 18 })]) : null),
  ]);
}

/** A modal sheet. Returns a close function. */
export function sheet(title, content, { onClose = null } = {}) {
  const backdrop = el('.sheet-backdrop');
  const close = () => {
    backdrop.remove();
    document.body.style.overflow = '';
    onClose?.();
  };

  const panelNode = el('.sheet', {}, [
    el('.sheet-header', {}, [
      el('h2.title', { text: title }),
      el('button.icon-button', {
        on: { click: close }, type: 'button', 'aria-label': 'Close',
      }, [icon('close', { size: 20 })]),
    ]),
    ...(Array.isArray(content) ? content : [content]),
  ]);

  backdrop.append(panelNode);
  // Tapping outside closes; tapping inside must not.
  backdrop.addEventListener('click', (event) => {
    if (event.target === backdrop) close();
  });

  document.body.append(backdrop);
  document.body.style.overflow = 'hidden';
  return close;
}

export function formatNumber(value, digits = 2) {
  if (!Number.isFinite(value)) return '—';
  return value.toFixed(digits);
}

export function relativeTime(timestamp) {
  const seconds = (Date.now() - timestamp) / 1000;
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}
