(function () {
  const P = {
    clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    running: '<g><circle cx="12" cy="12" r="9" stroke-dasharray="3.2 2.6"/><animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="2.5s" repeatCount="indefinite"/></g>',
    'circle-dashed': '<circle cx="12" cy="12" r="9" stroke-dasharray="3.2 2.6"/>',
    alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    seal: '<path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"/><path d="m9 12 2 2 4-4"/>',
    half: '<circle cx="12" cy="12" r="10"/><path d="M12 18a6 6 0 0 0 0-12v12z" fill="currentColor"/>',
    octx: '<path d="M2.586 16.726A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2h6.624a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586z"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>',
    refresh: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
    hourglass: '<path d="M5 22h14"/><path d="M5 2h14"/><path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"/><path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/>',
    lock: '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    gear: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
    left: '<path d="m15 18-6-6 6-6"/>', down: '<path d="m6 9 6 6 6-6"/>', right: '<path d="m9 18 6-6-6-6"/>',
    copy: '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
    ext: '<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
    branch: '<line x1="6" x2="6" y1="3" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>',
    check: '<path d="M20 6 9 17l-5-5"/>', x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    more: '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
    link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    pause: '<rect x="14" y="4" width="4" height="16" rx="1"/><rect x="6" y="4" width="4" height="16" rx="1"/>',
    offline: '<path d="M12 20h.01"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/><path d="M5 12.859a10 10 0 0 1 5.17-2.69"/><path d="M19 12.859a10 10 0 0 0-2.007-1.523"/><path d="M2 8.82a15 15 0 0 1 4.177-2.643"/><path d="M22 8.82a15 15 0 0 0-11.288-3.764"/><path d="m2 2 20 20"/>',
    msg: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    ok: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    fail: '<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>',
    slash: '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
    dot: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="1" fill="currentColor"/>',
    inbox: '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    gitlab: '<path d="m22 13.29-3.33-10a.42.42 0 0 0-.14-.18.38.38 0 0 0-.22-.11.39.39 0 0 0-.23.07.42.42 0 0 0-.14.18l-2.26 6.67H8.32L6.1 3.26a.42.42 0 0 0-.1-.18.38.38 0 0 0-.26-.08.39.39 0 0 0-.23.07.42.42 0 0 0-.14.18L2 13.29a.74.74 0 0 0 .27.83L12 21l9.69-6.88a.71.71 0 0 0 .31-.83Z"/>',
    github: '<path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/><path d="M9 18c-4.51 2-5-2-7-2"/>',
    bell: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/>',
    shield: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>',
    user: '<circle cx="12" cy="8" r="5"/><path d="M20 21a8 8 0 0 0-16 0"/>',
    filter: '<polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>',
    cpu: '<rect width="16" height="16" x="4" y="4" rx="2"/><rect width="6" height="6" x="9" y="9" rx="1"/><path d="M15 2v2M15 20v2M2 15h2M2 9h2M20 15h2M20 9h2M9 2v2M9 20v2"/>',
    sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
    pr: '<circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M13 6h3a2 2 0 0 1 2 2v7"/><line x1="6" x2="6" y1="9" y2="21"/>',
    arrow: '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
    plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
    play: '<polygon points="6 3 20 12 6 21 6 3"/>'
  };
  class RBIcon extends HTMLElement {
    static get observedAttributes() { return ['name', 'size', 'stroke']; }
    connectedCallback() { if (!this.shadowRoot) this.attachShadow({ mode: 'open' }); this.draw(); }
    attributeChangedCallback() { if (this.shadowRoot) this.draw(); }
    draw() {
      const s = this.getAttribute('size') || 14, w = this.getAttribute('stroke') || 1.75;
      this.shadowRoot.innerHTML = `<style>:host{display:inline-flex;flex:none;line-height:0}</style><svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round">${P[this.getAttribute('name')] || ''}</svg>`;
    }
  }
  const BASE = {
    '--rb-sans': '-apple-system, "SF Pro Text", "SF Pro", Inter, BlinkMacSystemFont, system-ui, sans-serif',
    '--rb-mono': 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace'
  };
  const T = {
    light: { '--rb-desk': '#f6f6f8', '--rb-pop': '#ffffff', '--rb-sunk': '#f2f2f5', '--rb-raised': '#f2f2f5', '--rb-hover': '#f2f2f5', '--rb-head': '#1d1d1f', '--rb-ink': '#3a3a40', '--rb-mute': '#6b6b73', '--rb-faint': '#8e8e95', '--rb-line': 'rgba(0,0,0,.08)', '--rb-edge': 'rgba(0,0,0,.12)', '--rb-rule': 'rgba(0,0,0,.08)', '--rb-btn': 'rgba(0,0,0,.05)', '--rb-btnh': 'rgba(0,0,0,.08)', '--rb-key': '#1d1d1f', '--rb-keyh': '#2c2c30', '--rb-keytx': '#f6f6f8', '--rb-keyshadow': 'inset 0 1px 0 rgba(255,255,255,.14), 0 1px 2px rgba(0,0,0,.18)', '--rb-red': '#c8302b', '--rb-orange': '#a65500', '--rb-green': '#1a7f43', '--rb-blue': '#0b62c4', '--rb-purple': '#7b45c9', '--rb-yellow': '#8a6a00', '--rb-grey': '#6b6b73', '--rb-tint': 'rgba(200,48,43,.07)', '--rb-seg': '#ffffff', '--rb-segshadow': '0 0 0 .5px rgba(0,0,0,.12), 0 1px 2px rgba(0,0,0,.12)', '--rb-shadow': '0 16px 40px rgba(0,0,0,.12), 0 0 0 1px rgba(0,0,0,.12)' },
    dark: { '--rb-desk': '#08090a', '--rb-pop': '#0f1011', '--rb-sunk': '#141516', '--rb-raised': '#141516', '--rb-hover': '#141516', '--rb-head': '#f7f8f8', '--rb-ink': '#d0d6e0', '--rb-mute': '#8a8f98', '--rb-faint': '#62666d', '--rb-line': 'rgba(255,255,255,.08)', '--rb-edge': 'rgba(255,255,255,.12)', '--rb-rule': 'rgba(255,255,255,.08)', '--rb-btn': 'rgba(255,255,255,.05)', '--rb-btnh': 'rgba(255,255,255,.09)', '--rb-key': '#e6e6e6', '--rb-keyh': '#f2f2f2', '--rb-keytx': '#111214', '--rb-keyshadow': 'inset 0 1px 0 rgba(255,255,255,.8), 0 0 0 1px rgba(0,0,0,.5), 0 1px 2px rgba(0,0,0,.4)', '--rb-red': '#ff6b66', '--rb-orange': '#ffa54d', '--rb-green': '#4ccb7a', '--rb-blue': '#5aa6ff', '--rb-purple': '#c39bff', '--rb-yellow': '#f2c94c', '--rb-grey': '#8a8f98', '--rb-tint': 'rgba(255,107,102,.07)', '--rb-seg': '#26272a', '--rb-segshadow': 'inset 0 1px 0 rgba(255,255,255,.08), 0 1px 2px rgba(0,0,0,.5)', '--rb-shadow': '0 20px 48px rgba(0,0,0,.6), 0 0 0 1px rgba(255,255,255,.12)' }
  };
  const decl = o => Object.entries(o).map(([k, v]) => `${k}:${v};`).join('');
  if (!document.getElementById('rb-inter')) {
    const l = document.createElement('link'); l.id = 'rb-inter'; l.rel = 'stylesheet';
    l.href = 'https://fonts.googleapis.com/css2?family=Inter:wght@400..600&display=swap'; document.head.appendChild(l);
  }
  if (!document.getElementById('rb-theme-css')) {
    const st = document.createElement('style');
    st.id = 'rb-theme-css';
    st.textContent = `rb-theme,[data-rb-mode]{${decl(BASE)}${decl(T.light)}color-scheme:light}rb-theme{display:contents}rb-theme[block]{display:block}rb-theme[mode=dark],[data-rb-mode=dark]{${decl(T.dark)}color-scheme:dark}`;
    document.head.appendChild(st);
  }
  class RBTheme extends HTMLElement {}
  if (!customElements.get('rb-icon')) customElements.define('rb-icon', RBIcon);
  if (!customElements.get('rb-theme')) customElements.define('rb-theme', RBTheme);
})();
