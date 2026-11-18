
(() => {
  const $ = (s, el = document) => el.querySelector(s), $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const site = document.getElementById('site') || document.body;

  /* ------------------------------------------------ the showcase (P88): each still loads half a screen ahead; each clip gets its source as it nears the screen,
     plays muted while half of it is on screen and pauses off it; reduced motion and Save-Data keep the still. ?showcase=sticky or
     ?showcase=rows previews the other layout. */
  const showEl = $('.show'), lay = new URLSearchParams(location.search).get('showcase');
  if (showEl && (lay === 'rows' || lay === 'sticky')) showEl.dataset.layout = lay;
  const stills = $$('.sbox img[data-src]');
  if (stills.length) {
    const load = (i) => { i.src = i.dataset.src; i.removeAttribute('data-src'); };
    if ('IntersectionObserver' in window) { const io = new IntersectionObserver((es) => es.forEach(e => { if (e.isIntersecting) { load(e.target); io.unobserve(e.target); } }), { rootMargin: '0px 0px 50% 0px' }); stills.forEach(i => io.observe(i)); }
    else stills.forEach(load);
  }
  const clips = $$('.sbox video[data-src]');
  if (clips.length && !reduced && !(navigator.connection && navigator.connection.saveData) && 'IntersectionObserver' in window) {
    const src = (v) => { if (v.getAttribute('src')) return; v.muted = true; v.playsInline = true; v.loop = true; v.preload = 'auto'; v.src = v.dataset.src; };
    const near = new IntersectionObserver((es) => es.forEach(e => { if (e.isIntersecting) { src(e.target); near.unobserve(e.target); } }), { rootMargin: '0px 0px 120px 0px' });
    const run = (v) => { if (v.dataset.paused || document.hidden) return; src(v); v.play().then(() => { v.classList.add('on'); const b = v.nextElementSibling; if (b) b.hidden = false; }).catch(() => {}); };
    const inView = new IntersectionObserver((es) => es.forEach(e => { const v = e.target; v._in = e.intersectionRatio >= .5; if (v._in) run(v); else v.pause(); }), { threshold: [0, .5] });
    /* No clip is asked for before the page has loaded: the hero's is on screen from the start, and fetching it while the
       poster, fonts and styles are still coming would hold back the first paint (Sven, 2026-11-18). */
    const arm = () => clips.forEach(v => { near.observe(v); inView.observe(v); });
    if (document.readyState === 'complete') arm(); else addEventListener('load', arm, { once: true });
    clips.forEach(v => { const b = v.nextElementSibling;
      b?.addEventListener('click', () => { const off = !v.dataset.paused; if (off) { v.dataset.paused = '1'; v.pause(); } else { delete v.dataset.paused; run(v); } b.setAttribute('aria-label', b.getAttribute('aria-label').replace(off ? 'Pause' : 'Play', off ? 'Play' : 'Pause')); $('path', b).setAttribute('d', off ? 'M5 3v10l8-5z' : 'M4.5 3h2.5v10H4.5zM9 3h2.5v10H9z'); }); });
    document.addEventListener('visibilitychange', () => clips.forEach(v => { if (document.hidden) v.pause(); else if (v._in) run(v); }));
  }

  /* ------------------------------------------------ the hero: strike, film */
  const hero = $('.hero');
  if (hero) { const check = () => { const r = hero.getBoundingClientRect(); if (r.top < innerHeight * .85 && r.bottom > 0) { site.classList.add('go'); removeEventListener('scroll', check); } }; addEventListener('scroll', check, { passive: true }); requestAnimationFrame(check); setTimeout(check, 400); }
  const film = $('#film'), play = $('#play'); if (film && play) play.addEventListener('click', () => { film.controls = true; film.play().catch(() => {}); play.remove(); });

  /* ------------------------------------------------ the shader: Liquid (Sven, 2026-11-15, Q260 S2; Glow before it, Q571),
     one fixed canvas behind every page. The haze's fbm warped hard into pools of the theme's accent and of a second hue 40
     degrees round from it, each with a glossy edge, drifting slowly; clear behind the hero's text on the left, stronger
     toward the right and the top. Drawn at 40 % of CSS pixels and stretched, at most 30 frames a second, paused in a
     hidden tab, one still frame with reduced motion; on phones too since Q261, there at a flat 45 % so text keeps reading
     (0.7 ms a frame on an M4 at desktop size, 1.2 ms on a CPU renderer at phone size, round 3's bench).
     A theme change rolls the new theme in from the swatch you pressed (Sven, 2026-11-14): the page is revealed in a widening
     circle (a view transition) and a ring travels on its edge in the new accent, behind it the new colours, ahead the old. */
  const cv = $('#shader');
  const hasShader = !!cv;
  let mode = hasShader ? 'glow' : 'off', gl = null, raf = 0, last = 0, t0 = performance.now(), uni = {}, TK = null;
  let swell = null;   // a theme change in flight: { from: tokens, x, y (CSS px), t: start, d: ms, far: CSS px to the farthest corner }
  const easeOut = (k) => 1 - (1 - k) ** 3;
  const FS = `precision mediump float;
uniform vec2 R; uniform float T; uniform float Y; uniform vec3 C; uniform vec3 C2; uniform vec3 C0; uniform vec3 C20;
uniform float L; uniform float N; uniform vec2 P; uniform float F; uniform float K;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3. - 2. * f); return mix(mix(h(i), h(i + vec2(1., 0.)), f.x), mix(h(i + vec2(0., 1.)), h(i + vec2(1., 1.)), f.x), f.y); }
float fbm(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 4; i++) { v += a * n(p); p = p * 2.03 + 17.; a *= .5; } return v; }
void main(){
  vec2 uv = gl_FragCoord.xy / R;
  vec2 p = vec2(uv.x * R.x / R.y, uv.y - Y) * .9; float t = T * .04;
  vec2 q = vec2(fbm(p + vec2(t, 0.)), fbm(p + vec2(5.2, -t)));
  vec2 r = vec2(fbm(p + q * 2.4 + vec2(1.7, 9.2) + t), fbm(p + q * 2.4 + vec2(8.3, 2.8) - t));
  float f = fbm(p + r * 2.2);
  float pool = smoothstep(.46, .52, f), pool2 = smoothstep(.55, .6, r.x) * (1. - pool);
  float e = f - .52, gloss = smoothstep(0., .02, e) * smoothstep(.06, .02, e);
  float rr = length(gl_FragCoord.xy - P), w = R.y * .07;
  float inside = 1. - smoothstep(F - w, F + w * .3, rr);
  float d = (rr - F) / w;   // no pow: GLSL ES leaves pow undefined for a negative base
  float ring = exp(-d * d) * K;
  vec3 c1 = mix(C0, C, inside), c2 = mix(C20, C2, inside);
  vec3 col = c1 * pool + c2 * pool2 + mix(c1, vec3(1.), .5) * gloss * .5;
  float m = N > .5 ? .45 : smoothstep(.36, .8, uv.x) * (.55 + .45 * uv.y);
  float a = (pool * .75 + pool2 * .6 + gloss * .4) * m * (L > .5 ? .5 : .7);
  float ra = ring * (.18 + .3 * f);
  gl_FragColor = vec4(min(col, 1.) * a + c1 * ra, min(a + ra, .85));
}`;
  const VS = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0., 1.); }';
  const tokens = () => {
    const cs = getComputedStyle(document.documentElement);
    const hex = (v) => { v = v.trim().replace('#', ''); return [0, 2, 4].map(i => parseInt(v.slice(i, i + 2), 16) / 255); };
    const lum = (c) => .2126 * c[0] + .7152 * c[1] + .0722 * c[2];
    const g = hex(cs.getPropertyValue('--g')), c = hex(cs.getPropertyValue('--lime')), t3 = hex(cs.getPropertyValue('--t3')), dark = lum(g) < .5;
    // The strength each theme had before 1.2 (tuned for near-black grounds and vivid accents) is the floor; a muted accent
    // on a tinted ground (Jade, Nord, Gruvbox, Wisteria, Folio) is raised until the haze differs from the ground by one
    // OKLab step of .11, as far as the third text keeps 4.5:1 over the haze's peak (about half of A, measured).
    const floor = dark ? .12 : (lum(c) < .3 ? .06 : .2);
    const lin = (v) => v.map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4);
    const Y = (v) => lum(lin(v)), mix = (a) => g.map((x, i) => x * (1 - a) + c[i] * a);
    const ok = (v) => { const [r, gg, b] = lin(v); const l = Math.cbrt(.4122 * r + .5363 * gg + .0514 * b), m = Math.cbrt(.2119 * r + .6807 * gg + .1074 * b), s = Math.cbrt(.0883 * r + .2817 * gg + .6300 * b);
      return [.2105 * l + .7936 * m - .0041 * s, 1.978 * l - 2.4286 * m + .4506 * s, .0259 * l + .7828 * m - .8087 * s]; };
    const o = ok(g), dE = (a) => Math.hypot(...ok(mix(a)).map((x, i) => x - o[i]));
    const cr = (a) => { const p = Y(t3), q = Y(mix(a)); return (Math.max(p, q) + .05) / (Math.min(p, q) + .05); };
    let want = .06; while (want < .3 && dE(want) < .11) want += .005;
    let cap = .06; while (cap < .3 && cr((cap + .005) / 2) >= 4.5) cap += .005;
    // The second hue: the accent turned 40 degrees round the wheel (HSL), at least as saturated as 55 %.
    const [r0, g0, b0] = c, mx = Math.max(r0, g0, b0), mn = Math.min(r0, g0, b0), l = (mx + mn) / 2, dd = mx - mn;
    let hh = 0, sat = 0;
    if (dd) { sat = dd / (1 - Math.abs(2 * l - 1)); hh = (mx === r0 ? ((g0 - b0) / dd) % 6 : mx === g0 ? (b0 - r0) / dd + 2 : (r0 - g0) / dd + 4) * 60; }
    hh = (hh + 40 + 360) % 360; sat = Math.max(sat, .55);
    const kk = (nn) => (nn + hh / 30) % 12, aa = sat * Math.min(l, 1 - l), ch = (nn) => l - aa * Math.max(-1, Math.min(kk(nn) - 3, Math.min(9 - kk(nn), 1)));
    return { c, c2: [ch(0), ch(8), ch(4)], light: dark ? 0 : 1, a: Math.max(floor, Math.min(want, cap)) };
  };
  const retoken = () => { TK = tokens(); };
  const init = () => {
    gl = cv.getContext('webgl', { premultipliedAlpha: true, alpha: true, antialias: false, powerPreference: 'low-power' });
    if (!gl) { document.documentElement.classList.add('css-fallback'); return false; }
    const sh = (t, src) => { const o = gl.createShader(t); gl.shaderSource(o, src); gl.compileShader(o); return o; };
    const prog = gl.createProgram(); gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { document.documentElement.classList.add('css-fallback'); gl = null; return false; }
    gl.useProgram(prog);
    const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    ['R', 'T', 'Y', 'C', 'C2', 'C0', 'C20', 'L', 'N', 'P', 'F', 'K'].forEach(k => uni[k] = gl.getUniformLocation(prog, k));
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); return true;
  };
  const size = () => { cv.width = Math.max(1, Math.round(innerWidth * .4)); cv.height = Math.max(1, Math.round(innerHeight * .4)); if (gl) gl.viewport(0, 0, cv.width, cv.height); };
  window.__frames = 0;
  const frame = (tt) => {
    if (!gl) return; window.__frames++; const k = TK || (TK = tokens());
    gl.uniform2f(uni.R, cv.width, cv.height); gl.uniform1f(uni.T, tt); gl.uniform1f(uni.Y, reduced ? 0 : scrollY / innerHeight * .35);
    gl.uniform3fv(uni.C, k.c); gl.uniform3fv(uni.C2, k.c2); gl.uniform1f(uni.L, k.light); gl.uniform1f(uni.N, innerWidth < 600 ? 1 : 0);
    // the swell: progress k0 eases out; its front sits where the page's circle is (both from the same ease and corner)
    const s = cv.width / innerWidth, w = swell, k0 = w ? Math.min(1, (performance.now() - w.t) / w.d) : 1;
    if (w && k0 >= 1) swell = null;
    gl.uniform3fv(uni.C0, w ? w.from.c : k.c); gl.uniform3fv(uni.C20, w ? w.from.c2 : k.c2);
    gl.uniform2f(uni.P, w ? w.x * s : 0, w ? cv.height - w.y * s : 0); gl.uniform1f(uni.F, w ? easeOut(k0) * w.far * s : 2 * (cv.width + cv.height));   // at rest: past every pixel, inside mediump's range
    gl.uniform1f(uni.K, w ? (1 - k0) ** .6 : 0);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 3);
  };
  const loop = (now) => { raf = 0; if (mode === 'off' || document.hidden) return; if (swell || now - last >= 33) { last = now; frame((now - t0) / 1000); } raf = requestAnimationFrame(loop); };
  const apply = () => {
    if (!hasShader) return; cancelAnimationFrame(raf); raf = 0;
    const off = mode === 'off';   // phones too since Q261
    document.documentElement.classList.toggle('no-fx', off);
    if (off || !gl) return; size();
    if (reduced) frame(2.2); else raf = requestAnimationFrame(loop);
  };
  if (hasShader && init()) { addEventListener('resize', apply); document.addEventListener('visibilitychange', apply); }
  window.__shader = () => gl ? (gl.getParameter(gl.RENDERER) || 'webgl') : 'css-fallback';

  /* ------------------------------------------------ the theme: Refreshed by default, or one of Pilot's own themes */
  const tbtn = $('.tbtn'), tpop = $('.tpop');
  // A pressed swatch rolls the theme in from where it was pressed (see the shader); a first load, reduced motion or a browser
  // without view transitions switches at once, the haze still rolling where WebGL runs.
  const setTheme = (t, from) => {
    const cur = document.documentElement.dataset.theme || '';
    if (from && !reduced && cur !== (t || '')) {
      const r = from.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      const far = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y)), d = 1100;
      const old = TK || tokens();
      const go = () => { applyTheme(t); if (gl && !document.documentElement.classList.contains('no-fx')) swell = { from: old, x, y, t: performance.now(), d, far }; };
      if (!document.startViewTransition) return go();
      const vt = document.startViewTransition(go);
      vt.ready.then(() => document.documentElement.animate(
        { clipPath: Array.from({ length: 13 }, (_, i) => `circle(${easeOut(i / 12) * far}px at ${x}px ${y}px)`) },
        { duration: d, easing: 'linear', pseudoElement: '::view-transition-new(root)' })).catch(() => {});
      return;
    }
    applyTheme(t);
  };
  const applyTheme = (t) => {
    if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
    try { t ? localStorage.setItem('pilot-theme', t) : localStorage.removeItem('pilot-theme'); } catch (_) {}
    $$('.tpop [data-t]').forEach(b => b.setAttribute('aria-checked', b.dataset.t === (t || '')));
    $$('.tryth [data-t]').forEach(b => b.setAttribute('aria-pressed', b.dataset.t === (t || '')));
    const tn = $('.hthemes .tname'), pk = $(`.tryth [data-t="${t || ''}"]`); if (tn && pk) tn.textContent = pk.title;
    const on = $(`.tpop [data-t="${t || ''}"] .tsw`); if (on && tbtn) $('.tsw', tbtn).innerHTML = on.innerHTML;
    retoken(); if (hasShader) apply();
  };
  if (tbtn && tpop) {
    const close = () => { tpop.hidden = true; tbtn.setAttribute('aria-expanded', 'false'); };
    tbtn.addEventListener('click', (e) => { e.stopPropagation(); const o = tpop.hidden; tpop.hidden = !o; tbtn.setAttribute('aria-expanded', String(o)); if (o) $('.tpop [aria-checked=true]')?.focus(); });
    tpop.addEventListener('click', (e) => { const b = e.target.closest('[data-t]'); if (b) { setTheme(b.dataset.t, tbtn); close(); tbtn.focus(); } });
    tpop.addEventListener('keydown', (e) => { const items = $$('.tpop [data-t]'), i = items.indexOf(document.activeElement); if (e.key === 'Escape') { close(); tbtn.focus(); } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); items[(i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length].focus(); } });
    document.addEventListener('click', (e) => { if (!tpop.hidden && !e.target.closest('.thm-menu')) close(); });
    let saved = ''; try { saved = localStorage.getItem('pilot-theme') || ''; } catch (_) {}
    setTheme(new URLSearchParams(location.search).get('theme') ?? saved);
  }
  $$('.tryth [data-t]').forEach(b => b.addEventListener('click', () => setTheme(b.dataset.t, b)));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { retoken(); if (hasShader) apply(); });
  const tabRow = $('.atabs .row'), tabOn = $('.atabs [aria-current]');
  if (tabRow && tabOn && tabRow.scrollWidth > tabRow.clientWidth) tabRow.scrollLeft = tabOn.offsetLeft - tabRow.clientWidth / 2 + tabOn.offsetWidth / 2;
  apply();
  /* external links open in a new tab, so the Pilot tab stays (Sven 2026-10-29); the generator marks its own, this catches
     the approved privacy text */
  const markOut = (root) => $$('a[href^="http"]', root).forEach(a => { if (a.host !== location.host && !/\/download\//.test(a.pathname)) { a.target = '_blank'; a.rel = 'noopener'; } });
  markOut(document);
})();
