
(() => {
  const D = window.PILOT_DATA || { areas: [], feats: [], exts: [], groups: [] };
  const IC = (i) => `<svg class="i" aria-hidden="true"><use href="#i-${i}"/></svg>`;
  const $ = (s, el = document) => el.querySelector(s), $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const esc = (s) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const site = document.getElementById('site') || document.body;
  const lines = (ws) => ws.map(w => `<div class="ln" style="width:${w}%"></div>`).join('');
  const holdable = (el, on, off) => {
    let down = false;
    const start = (e) => { if (down) return; down = true; el.classList.add('down'); on(); if (e && e.pointerId !== undefined) try { el.setPointerCapture(e.pointerId); } catch (_) {} };
    const end = () => { if (!down) return; down = false; el.classList.remove('down'); off(); };
    el.addEventListener('pointerdown', (e) => { e.preventDefault(); start(e); });
    ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(t => el.addEventListener(t, end));
    el.addEventListener('keydown', (e) => { if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); start(e); } });
    el.addEventListener('keyup', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); end(); } });
    el.addEventListener('blur', end); el.addEventListener('contextmenu', (e) => e.preventDefault());
  };
  /* Pilot's window: rail, page list, page */
  const RAIL = [['home', 'Home'], ['command', 'Keys'], ['search', 'Launcher'], ['grid', 'Desktop'], ['sliders', 'Mac'], ['wrench', 'Tools'], ['apps', 'Apps'], ['spark', 'AI'], ['puzzle', 'Extensions']];
  const win = (rail, side, sideOn, title, tabs, body, right = '') => `<div class="win2"><div class="rail"><span class="dots"><i></i><i></i><i></i></span>${RAIL.map(([i, l]) => `<span class="ri${l === rail ? ' on' : ''}">${IC(i)}${l}</span>`).join('')}</div><div class="side"><div class="h5">${rail}</div><span class="ss">${IC('search')}Search settings</span>${side.map(([l, s], n) => `<button type="button" class="si${n === sideOn ? ' on' : ''}" data-side="${n}">${l}${s ? `<small>${s}</small>` : ''}</button>`).join('')}</div><div class="main"><div class="mh"><div class="h4">${title}</div>${tabs}<span class="sp"></span>${right}</div><div class="mb">${body}</div></div></div>`;
  const seg = (name, opts, on) => `<span class="sg" role="group" data-sg="${name}">${opts.map((o, i) => `<button type="button" data-v="${i}" aria-pressed="${i === on}">${o}</button>`).join('')}</span>`;
  const wireSeg = (el, name, fn) => $$(`[data-sg="${name}"] button`, el).forEach(b => b.addEventListener('click', () => { $$(`[data-sg="${name}"] button`, el).forEach(x => x.setAttribute('aria-pressed', x === b)); fn(+b.dataset.v); }));
  const menuShell = (mode, q, ph, filters, foot, split) => `<div class="p-menu"><div class="mnu pn"><label class="q">${mode ? `<span class="md">${mode}</span>` : ''}<span class="pr">❱</span><input type="text" value="${esc(q)}" placeholder="${ph}" autocomplete="off" spellcheck="false" aria-label="Search, as in Pilot's menu"></label>${filters || ''}<div class="bd${split ? ' split' : ''}"><div class="res" role="listbox" aria-label="Results"></div>${split ? '<div class="pvw"></div>' : ''}</div><div class="ft">${foot}</div></div></div>`;

  /* ------------------------------------------------ the seventeen previews */
  const P = {};

  /* ---------------------------------------------------------------- Windows: Pilot's tiler with real app windows */
  const APPW = {
    ghostty: ['Ghostty', 'term', '~/code/site — zsh'], zed: ['Zed', 'code', 'pilot.js — site'], safari: ['Safari', 'globe', 'Pilot for Mac'],
    mail: ['Mail', 'at', 'Inbox — 3 unread'], notes: ['Notes', 'note', 'Launch week'], music: ['Music', 'music', 'Now playing'],
  };
  const winBody = (k) => ({
    ghostty: `<div class="wc term2"><p><b>❯</b> pilot status</p><p class="d">Pilot 1.0 · tiling on · 51 binds on Hyper</p><p><b>❯</b> git log --oneline -3</p><p class="d">c90eae8 site: pill nav with GitHub</p><p class="d">64fc573 site: area lists show keys</p><p class="d">6a79521 site: one mini Pilot desktop</p><p><b>❯</b> <i class="cur"></i></p></div>`,
    zed: `<div class="wc code2">${[['1', '<k>const</k> show = (s) => {'], ['2', '  <k>if</k> (!P[s]) <k>return</k>;'], ['3', '  cur = s;'], ['4', '  fill(s);'], ['5', '};'], ['6', ''], ['7', '<k>export</k> <k>function</k> <f>tile</f>(ws) {'], ['8', '  <k>return</k> ws.<f>layout</f>(<s>"tiles"</s>);'], ['9', '}']].map(([n, l]) => `<p><i>${n}</i>${l}</p>`).join('')}</div>`,
    safari: `<div class="wc web2"><div class="url">${IC('lock')}${esc(D.host || '')}</div><div class="hero3"><b>Window manager. Launcher. Pilot.</b><span></span><span class="s"></span></div><div class="cards3"><i></i><i></i><i></i></div></div>`,
    mail: `<div class="wc mail2">${[['Maya Lind', 'Design review moved to Thursday', '09:41', 1], ['GitHub', '[pilot] CI passed on main', '09:12', 1], ['Shippers Club', 'Demo night: who is in?', 'Yesterday', 0], ['Stripe', 'Your receipt from Vercel', 'Tue', 0]].map(([f, s, t, u]) => `<p class="${u ? 'u' : ''}"><b>${f}</b><span>${s}</span><small>${t}</small></p>`).join('')}</div>`,
    notes: `<div class="wc note2"><b>Launch week</b><p>☑ Record the film</p><p>☑ Site pass</p><p>☐ Post on X at 16:00</p><p>☐ Reply to every comment</p></div>`,
    music: `<div class="wc music2"><i class="art"></i><b>Hold On</b><small>Chord Overstreet</small><span class="pr"><i></i></span><span class="ctl">⏮ ⏸ ⏭</span></div>`,
  })[k];
  P.windows = { app: 'Ghostty', try: 'Click the windows, then <b>← → ↑ ↓</b> move focus and <b>Shift + arrows</b> swap (Hyper + arrows in Pilot); try <b>Scrolling</b>, <b>Float</b>, <b>Gaps</b>, <b>Defocus</b> and <b>1 2 3</b> in the top bar', render(el) {
    const st = { ws: 2, layout: 'tiles', gaps: true, W: { 1: ['notes'], 2: ['ghostty', 'zed', 'safari'], 3: ['mail', 'music'] }, f: { 1: 0, 2: 0, 3: 0 }, fl: new Set() };
    el.innerHTML = `<div class="p-win" tabindex="0" aria-label="Pilot's tiler: arrow keys move focus, Shift swaps"><div class="area"></div><div class="bar">${seg('lay', ['Tiles', 'Scrolling'], 0)}<span class="sp"></span><button type="button" class="bt" data-act="open">${IC('window')}Open</button><button type="button" class="bt" data-act="close">${IC('xwin')}Close <span class="k2 s">⇪ W</span></button><span class="sp"></span><button type="button" class="bt" data-act="float" aria-pressed="false">${IC('float')}Float</button><button type="button" class="bt" data-act="gaps" aria-pressed="true">${IC('gaps')}Gaps</button><button type="button" class="bt" data-act="defocus" aria-pressed="false">${IC('focus')}Defocus</button></div></div>`;
    const root = $('.p-win', el), area = $('.area', el);
    const rects = (ids, W, H, fi) => {
      const g = st.gaps ? 10 : 2, tiled = ids.filter(a => !st.fl.has(a)), out = {};
      if (st.layout === 'scroll') { const w = Math.round(W * .5); const fiT = Math.max(0, tiled.indexOf(ids[fi])); const off = Math.max(0, Math.min(fiT * (w + g) - (W - w) / 2, tiled.length * (w + g) - g - W)); tiled.forEach((a, i) => { out[a] = [i * (w + g) - off, 0, w, H]; }); }
      else if (tiled.length === 1) out[tiled[0]] = [0, 0, W, H];
      else if (tiled.length === 2) { const w = (W - g) / 2; out[tiled[0]] = [0, 0, w, H]; out[tiled[1]] = [w + g, 0, w, H]; }
      else if (tiled.length) { const mw = Math.round((W - g) * .56), sw = W - g - mw, sh = (H - g * (tiled.length - 2)) / (tiled.length - 1); out[tiled[0]] = [0, 0, mw, H]; tiled.slice(1).forEach((a, i) => { out[a] = [mw + g, i * (sh + g), sw, sh]; }); }
      ids.filter(a => st.fl.has(a)).forEach((a, i) => { out[a] = [W * .22 + i * 24, H * .14 + i * 24, W * .56, H * .66]; });
      return out;
    };
    const draw = () => {
      const ids = st.W[st.ws], { width, height } = area.getBoundingClientRect(), fi = Math.min(st.f[st.ws], ids.length - 1);
      $$('.win', area).forEach(w => { if (!ids.includes(w.dataset.a) || w.dataset.ws != st.ws) w.remove(); });
      const R = rects(ids, width, height, fi);
      ids.forEach((a, i) => {
        let w = area.querySelector(`.win[data-a="${a}"][data-ws="${st.ws}"]`);
        if (!w) { w = document.createElement('div'); w.className = 'win new'; w.dataset.a = a; w.dataset.ws = st.ws; w.innerHTML = `<div class="wt"><span class="dots"><i></i><i></i><i></i></span>${IC(APPW[a][1])}<span>${APPW[a][2]}</span></div>${winBody(a)}`; area.appendChild(w); requestAnimationFrame(() => w.classList.remove('new')); }
        const [x, y, ww, hh] = R[a]; Object.assign(w.style, { left: x + 'px', top: y + 'px', width: ww + 'px', height: hh + 'px', zIndex: st.fl.has(a) ? 3 : 1 });
        w.classList.toggle('f', i === fi); w.classList.toggle('fl', st.fl.has(a));
      });
      setApp(ids.length ? APPW[ids[fi]][0] : 'Finder');
      $$('#desk .tbws [data-ws]').forEach(b => b.classList.toggle('on', +b.dataset.ws === st.ws));
      $('[data-act="float"]', el).setAttribute('aria-pressed', ids.length > 0 && st.fl.has(ids[fi]));
    };
    const dirMove = (dx, dy, swap) => {
      const ids = st.W[st.ws]; if (ids.length < 2) return; const fi = st.f[st.ws];
      const box = (a) => { const w = area.querySelector(`.win[data-a="${a}"]`); return w ? [w.offsetLeft + w.offsetWidth / 2, w.offsetTop + w.offsetHeight / 2] : [0, 0]; };
      const [cx, cy] = box(ids[fi]); let best = -1, bd = 1e9;
      ids.forEach((a, i) => { if (i === fi) return; const [x, y] = box(a), vx = x - cx, vy = y - cy; if ((dx && Math.sign(vx) !== dx) || (dy && Math.sign(vy) !== dy) || (dx && Math.abs(vx) < 4) || (dy && Math.abs(vy) < 4)) return; const d = Math.abs(vx) + Math.abs(vy) * (dx ? 2 : .5); if (d < bd) { bd = d; best = i; } });
      if (best < 0) return;
      if (swap) { [ids[fi], ids[best]] = [ids[best], ids[fi]]; st.f[st.ws] = best; } else st.f[st.ws] = best;
      draw();
    };
    area.addEventListener('pointerdown', (e) => { const w = e.target.closest('.win'); if (w) { st.f[st.ws] = st.W[st.ws].indexOf(w.dataset.a); draw(); root.focus({ preventScroll: true }); } });
    root.addEventListener('keydown', (e) => { const d = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key]; if (!d) return; e.preventDefault(); dirMove(d[0], d[1], e.shiftKey); });
    wireSeg(el, 'lay', (i) => { st.layout = i ? 'scroll' : 'tiles'; draw(); });
    $$('[data-act]', el).forEach(b => b.addEventListener('click', () => {
      const ids = st.W[st.ws], fi = st.f[st.ws], k = b.dataset.act;
      if (k === 'open') { const free = Object.keys(APPW).find(a => !Object.values(st.W).flat().includes(a)) || Object.keys(APPW).find(a => !ids.includes(a)); if (!free || ids.length >= 5) return toast('Five is plenty for one workspace'); ids.push(free); st.f[st.ws] = ids.length - 1; }
      else if (k === 'close') { if (!ids.length) return; const [a] = ids.splice(fi, 1); st.fl.delete(a); st.f[st.ws] = Math.max(0, fi - 1); toast(`Closed ${APPW[a][0]}`); }
      else if (k === 'float') { const a = ids[fi]; if (!a) return; st.fl.has(a) ? st.fl.delete(a) : st.fl.add(a); }
      else if (k === 'gaps') { st.gaps = !st.gaps; b.setAttribute('aria-pressed', st.gaps); }
      else if (k === 'defocus') { const on = root.classList.toggle('defocus'); b.setAttribute('aria-pressed', on); }
      draw();
    }));
    this.ws = (n) => { st.ws = n; draw(); };
    new ResizeObserver(draw).observe(area); draw();
  }, ws: null };

  /* ---------------------------------------------------------------- Convert: Finder and Pilot's own file actions (Hyper + right-click) */
  P.convert = { app: 'Finder', try: '<b>Right-click</b> (or tap) a file for Pilot’s actions: <b>Convert to</b> a format, <b>Show preview</b>; or <b>Find duplicates</b>', render(el) {
    const files = [['IMG_2041.heic', 'image', 'HEIC', '3.1 MB'], ['launch-clip.mov', 'video', 'MOV', '48 MB'], ['notes.docx', 'doc', 'DOCX', '86 KB'], ['voice-memo.m4a', 'audio', 'M4A', '2.4 MB'], ['diagram.png', 'image', 'PNG', '412 KB'], ['diagram copy.png', 'image', 'PNG', '412 KB'], ['invoice-october.pdf', 'pdf', 'PDF', '212 KB']].map(f => ({ n: f[0], k: f[1], x: f[2], s: f[3] }));
    const TO = { image: ['PNG', 'JPG', 'HEIC', 'WebP', 'PDF'], video: ['MP4', 'GIF', 'MP3'], doc: ['PDF', 'DOCX', 'TXT'], audio: ['MP3', 'WAV'], pdf: ['PNG', 'JPG', 'DOCX'] };
    const thumb = (f) => `<span class="fth ${f.k}">${f.k === 'video' ? '<i class="play">▶</i>' : f.k === 'audio' ? '<i class="wv"></i>' : f.k === 'doc' || f.k === 'pdf' ? '<i class="pg"></i>' : ''}<b>${f.x}</b></span>`;
    el.innerHTML = `<div class="fnd2 pn"><div class="ftb"><span class="dots"><i></i><i></i><i></i></span><span class="nav2">‹ ›</span><b>Downloads</b><span class="sp"></span><button type="button" class="bt" data-dup>${IC('combine')}Find duplicates</button><span class="srch">${IC('search')}Search</span></div><div class="fbd"><aside>${[['Favourites', 0], ['AirDrop', 'arrowcirc'], ['Recents', 'history'], ['Applications', 'apps'], ['Desktop', 'display'], ['Documents', 'doc'], ['Downloads', 'download']].map(([n, i]) => i === 0 ? `<small>${n}</small>` : `<span class="${n === 'Downloads' ? 'on' : ''}">${IC(i)}${n}</span>`).join('')}</aside><div class="fgrid"></div></div><div class="fst"><span class="cnt"></span><span>Hyper + right-click any file for Pilot’s actions</span></div></div>`;
    const grid = $('.fgrid', el);
    const draw = () => { grid.innerHTML = files.map((f, i) => `<button type="button" class="fi2${f.nw ? ' new' : ''}" data-i="${i}">${thumb(f)}<span class="nm">${esc(f.n)}</span>${f.p ? '<span class="prog"><i></i></span>' : `<small>${f.s}</small>`}</button>`).join(''); $('.cnt', el).textContent = `${files.length} items`; };
    const closeMenus = () => $$('.cmenu2, .qlook', el).forEach(m => m.remove());
    const menu = (btn, x, y) => {
      closeMenus(); $$('.fi2', el).forEach(b => b.classList.toggle('sel', b === btn));
      const f = files[+btn.dataset.i], fmts = TO[f.k].filter(t => t !== f.x);
      const m = document.createElement('div'); m.className = 'cmenu2 pn';
      m.innerHTML = `<div class="mh2">${LOGO_MINI}<b>Pilot</b><span>${esc(f.n)}</span></div>${[['image', 'Show preview', 'Space', 'look'], ['speaker', 'Read aloud', '', 'read'], ['spark', 'Ask AI about it', '', 'ai']].map(([i, n, k, a]) => `<button type="button" class="mi" data-m="${a}">${IC(i)}<span>${n}</span>${k ? `<small>${k}</small>` : ''}</button>`).join('')}<div class="sub2"><span class="mi lbl">${IC('refresh')}<span>Convert to</span></span><div class="fmts2">${fmts.map(t => `<button type="button" data-t="${t}">${t}</button>`).join('')}</div></div>${f.k === 'image' ? [['scaleup', 'Upscale 4×', 'up'], ['resize', 'Resize…', 'resize']].map(([i, n, a]) => `<button type="button" class="mi" data-m="${a}">${IC(i)}<span>${n}</span></button>`).join('') : ''}<button type="button" class="mi" data-m="icon">${IC('palette')}<span>Change icon</span></button><button type="button" class="mi" data-m="path">${IC('copy')}<span>Copy path</span></button>`;
      el.appendChild(m); const r = el.getBoundingClientRect(); m.style.left = Math.max(8, Math.min(x - r.left, r.width - m.offsetWidth - 8)) + 'px'; m.style.top = Math.max(8, Math.min(y - r.top, r.height - m.offsetHeight - 8)) + 'px';
      m.addEventListener('click', (ev) => {
        const t = ev.target.closest('[data-t]'); const a = ev.target.closest('[data-m]');
        if (t) { m.remove(); const base = f.n.replace(/\.[^.]+$/, ''), to = t.dataset.t, kind = to === 'GIF' || ['PNG', 'JPG', 'HEIC', 'WebP'].includes(to) ? 'image' : to === 'MP4' ? 'video' : ['MP3', 'WAV'].includes(to) ? 'audio' : to === 'PDF' ? 'pdf' : 'doc'; const nf = { n: `${base}.${to.toLowerCase()}`, k: kind, x: to, s: '—', nw: 1, p: 1 }; files.push(nf); draw(); requestAnimationFrame(() => { const p = grid.querySelector('.fi2:last-child .prog i'); if (p) p.style.width = '100%'; }); setTimeout(() => { nf.p = 0; nf.s = f.s; draw(); toast(`${nf.n} is next to the original`); }, reduced ? 0 : 1000); return; }
        if (!a) return; m.remove(); const k = a.dataset.m;
        if (k === 'look') { const q = document.createElement('div'); q.className = 'qlook pn'; q.innerHTML = `${thumb(f)}<b>${esc(f.n)}</b><small>${f.s} · ${f.x}</small><button type="button" class="bt">Close</button>`; el.appendChild(q); $('button', q).addEventListener('click', () => q.remove()); }
        else toast({ read: `Reading ${f.n} aloud`, ai: `${f.n} added to the AI chat`, up: 'Upscaled 4× with the model on this Mac', resize: 'Resize: width, height or a percentage', icon: 'Pick an emoji, a picture or a folder design', path: `~/Downloads/${f.n} copied` }[k]);
      });
    };
    grid.addEventListener('contextmenu', (e) => { const b = e.target.closest('.fi2'); if (b) { e.preventDefault(); menu(b, e.clientX, e.clientY); } });
    grid.addEventListener('click', (e) => { const b = e.target.closest('.fi2'); if (b) { const r = b.getBoundingClientRect(); menu(b, r.left + r.width * .6, r.top + r.height * .55); } else closeMenus(); });
    $('[data-dup]', el).addEventListener('click', () => { closeMenus(); const q = document.createElement('div'); q.className = 'qlook pn dupc'; q.innerHTML = `<b>2 identical files</b><small>diagram.png and diagram copy.png · 412 KB each</small><p>The extra goes to the Trash after one ask; the newest copy stays.</p><div><button type="button" class="bt">Keep both</button><button type="button" class="bt ink">Move extra to Trash</button></div>`; el.appendChild(q); $$('button', q).forEach(b => b.addEventListener('click', () => { if (b.classList.contains('ink')) { const i = files.findIndex(f => f.n === 'diagram copy.png'); if (i >= 0) files.splice(i, 1); draw(); toast('diagram copy.png moved to the Trash'); } q.remove(); })); });
    draw();
  } };

  /* ---------------------------------------------------------------- Notes: the panel (InstrumentNotes), drawer, format bar, snippets */
  P.notes = { app: 'Pilot', try: 'Open the drawer (☰) for your notes, select words for the format bar, tick a box; type <b>;cm</b>, <b>;date</b> or <b>;addr</b> in the note', render(el) {
    const today = now().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' });
    const SNIP = { ';cm': 'Thanks for the call this morning. Notes to follow by Friday.', ';date': today, ';addr': '12 Rua das Flores, 1200-195 Lisboa' };
    const N = [
      { id: 's', t: 'Scratch', when: 'empty', grp: '', html: '<p><br></p>' },
      { id: 'p', t: 'Pilot v1 punch list', when: 'Licence screen', grp: 'Pinned', html: '<h1>Pilot v1 punch list</h1><div class="todo done" contenteditable="false"><i>✓</i><span>Licence screen</span></div><div class="todo" contenteditable="false"><i></i><span>Idle CPU under 1 %</span></div><div class="todo" contenteditable="false"><i></i><span>Sparkle feed on GitHub Releases</span></div>' },
      { id: 'm', t: 'buy oat milk', when: '22:48', grp: 'Today', html: '<h1>buy oat milk</h1><p>and coffee beans</p>' },
      { id: 'n', t: 'Ship the notes panel', when: '14:20', grp: 'Today', html: '<h1>Ship the notes panel</h1><p>Round 1 for <b>Pilot</b>: keep it calm, the text is the hero.</p><h2>Today</h2><div class="todo done" contenteditable="false"><i>✓</i><span>Read the quick notes brief</span></div><div class="todo" contenteditable="false"><i></i><span>Wire <code>Hyper+N</code> to the panel</span></div><div class="todo" contenteditable="false"><i></i><span>Trash confirm inside the panel</span></div><h2>Links</h2><p>Markdown files in a folder you pick, with a format bar and pasted pictures.</p>' },
      { id: 'e', t: 'Spanish: ser vs estar', when: '', grp: 'Yesterday', html: '<h1>Spanish: ser vs estar</h1><p><b>Ser</b> is what something is; <b>estar</b> is how or where it is.</p><div class="todo done" contenteditable="false"><i>✓</i><span>Soy de Malta</span></div><div class="todo" contenteditable="false"><i></i><span>Estoy cansado, ¿y tú?</span></div>' },
    ];
    let cur = 'n', drawer = false;
    el.innerHTML = `<div class="p-notes2"><div class="np pn"><div class="nh"><button type="button" class="nbt" data-drawer aria-label="Notes drawer" aria-pressed="false">${IC('list')}</button><span class="crumb3"><span class="when"></span> › <b class="ttl"></b></span><span class="wc2"></span><span class="k2 s">⌘K</span><button type="button" class="nbt" data-new aria-label="New note">+</button></div><div class="nbd"><aside class="ndr"><label class="nq">${IC('search')}<input type="text" placeholder="Find a note" aria-label="Find a note"></label><div class="nl2"></div><div class="nft2"><span>↵ Open</span><span>⌘K Actions</span><span>esc Hide</span></div></aside><div class="nwrap"><div class="nfmt" role="toolbar" aria-label="Format">${[['AA', 'formatBlock', 'h2'], ['B', 'bold'], ['I', 'italic'], ['code', 'code'], ['•', 'insertUnorderedList'], ['☑', 'todo']].map(([l, c, v]) => `<button type="button" data-c="${c}" data-v="${v || ''}"${l === 'code' ? ' aria-label="Code"' : ''}>${l === 'code' ? IC('code') : l}</button>`).join('')}</div><div class="ned2" contenteditable="true" spellcheck="false" role="textbox" aria-multiline="true" aria-label="The note"></div></div></div><div class="nsn">${IC('snippet')}<span>Snippets work in any app: try <b>;cm</b>, <b>;date</b> or <b>;addr</b> in the note</span></div></div></div>`;
    const ed = $('.ned2', el), list = $('.nl2', el), np = $('.np', el), q = $('.nq input', el);
    const words = () => { const n = ed.innerText.trim().split(/\s+/).filter(Boolean).length; $('.wc2', el).textContent = `${n} words · ${hhmm()}`; };
    const save = () => { const n = N.find(x => x.id === cur); n.html = ed.innerHTML; const h = ed.querySelector('h1'); if (h) n.t = h.textContent.trim() || n.t; };
    const open = (id) => { if (cur) save(); cur = id; const n = N.find(x => x.id === id); ed.innerHTML = n.html; $('.ttl', el).textContent = n.t; $('.when', el).textContent = n.grp || 'Scratch'; words(); renderList(); };
    const renderList = () => { const t = q.value.trim().toLowerCase(); let g = null, h = ''; N.filter(n => !t || (n.t + ' ' + n.html.replace(/<[^>]+>/g, ' ')).toLowerCase().includes(t)).forEach(n => { if (n.grp !== g) { g = n.grp; if (g) h += `<small class="ph">${g}</small>`; } h += `<button type="button" class="${n.id === cur ? 'on' : ''}" data-id="${n.id}">${n.id === 's' ? IC('edit') : ''}<b>${esc(n.t)}</b><em>${esc(n.when)}</em></button>`; }); list.innerHTML = h || '<small class="ph">No note has that</small>'; };
    $('[data-drawer]', el).addEventListener('click', (e) => { drawer = !drawer; np.classList.toggle('dr', drawer); e.currentTarget.setAttribute('aria-pressed', drawer); if (drawer) q.focus({ preventScroll: true }); });
    list.addEventListener('click', (e) => { const b = e.target.closest('[data-id]'); if (b) open(b.dataset.id); });
    q.addEventListener('input', renderList);
    $('[data-new]', el).addEventListener('click', () => { save(); const id = 'x' + N.length; N.splice(1, 0, { id, t: 'Untitled', when: hhmm(), grp: 'Today', html: '<h1>Untitled</h1><p><br></p>' }); open(id); ed.focus(); });
    ed.addEventListener('click', (e) => { const t = e.target.closest('.todo'); if (t) { t.classList.toggle('done'); $('i', t).textContent = t.classList.contains('done') ? '✓' : ''; save(); } });
    ed.addEventListener('input', () => {
      const s = getSelection(); if (s.rangeCount) { const n = s.anchorNode, o = s.anchorOffset; if (n && n.nodeType === 3) { const before = n.textContent.slice(0, o); const k = Object.keys(SNIP).find(x => before.endsWith(x)); if (k) { n.textContent = before.slice(0, -k.length) + SNIP[k] + n.textContent.slice(o); const r = document.createRange(); r.setStart(n, before.length - k.length + SNIP[k].length); r.collapse(true); s.removeAllRanges(); s.addRange(r); toast(`${k} typed itself`); } } }
      words(); save(); const h = ed.querySelector('h1'); if (h) $('.ttl', el).textContent = h.textContent.trim();
    });
    $$('.nfmt button', el).forEach(b => { b.addEventListener('pointerdown', (e) => e.preventDefault()); b.addEventListener('click', () => {
      const c = b.dataset.c;
      if (c === 'todo') { document.execCommand('insertHTML', false, '<div class="todo" contenteditable="false"><i></i><span>New item</span></div>'); }
      else if (c === 'code') { const t = getSelection().toString() || 'code'; document.execCommand('insertHTML', false, `<code>${esc(t)}</code>`); }
      else if (c === 'formatBlock') document.execCommand('formatBlock', false, 'h2');
      else document.execCommand(c);
      save();
    }); });
    open('n');
  } };

  /* ---------------------------------------------------------------- Dictation: hold or tap, the real overlay, and Read aloud */
  P.dictation = { app: 'Notes', try: 'Hold <b>Right Control</b> and talk (or switch to <b>Tap</b>); let go and the words land in the note; then <b>Read aloud</b>', render(el) {
    const PHRASES = ['Book the 9:40 train to Sintra, then lunch near the castle.', 'Remind Maya the design review moved to Thursday at ten.'];
    const W = [30, 52, 70, 88, 62, 96, 74, 58, 84, 100, 66, 90, 54, 78, 92, 60, 72, 48, 82, 56, 38, 64, 44, 26];
    let mode = 0, said = '', i = 0, t = null, live = false, round = 0;
    el.innerHTML = `<div class="p-dic"><div class="nt pn" style="width:min(100%,600px)"><div class="hd">${IC('list')}Today › <b>Lisbon weekend</b><span class="wc">0 words</span></div><div class="ed"><h1>Lisbon weekend</h1><p class="out"><span class="tx"></span><span class="cur" style="visibility:hidden"></span></p></div></div><div class="dpill" aria-hidden="true"><span class="dx">✕</span><span class="dw"><span></span></span><span class="dbars">${W.map((h, n) => `<i style="--n:${n};height:${h}%"></i>`).join('')}</span><span class="dok">✓</span></div><div class="rpill" aria-hidden="true">${IC('speaker')}<span>Reading aloud · Kokoro, on this Mac</span><i class="rp"><b></b></i></div><div class="dset pn"><span class="ds1">${IC('mic')}<b>Dictation</b></span><span class="k2">Right Control</span>${seg('dmode', ['Hold', 'Tap'], 0)}<span class="ds2">Parakeet · on this Mac · pauses your music</span><button type="button" class="bt" data-read>${IC('speaker')}Read aloud</button></div><button type="button" class="hold"><span class="k2">Right Control</span><span class="hl2">Hold to talk</span></button></div>`;
    const root = $('.p-dic', el), pill = $('.dpill', el), dw = $('.dw span', el), tx = $('.tx', el), wc = $('.wc', el), cur = $('.ed .cur', el), btn = $('.hold', el), rp = $('.rpill', el);
    const upd = () => { const w = said.trim().split(/\s+/).filter(Boolean); dw.textContent = w.slice(-7).join(' '); pill.classList.toggle('words', w.length > 0); };
    const start = () => { if (live) return; live = true; root.classList.remove('writing'); root.classList.add('on'); said = ''; i = 0; upd(); const P2 = PHRASES[round % PHRASES.length]; if (reduced) { said = P2; upd(); } else t = setInterval(() => { if (i >= P2.length) return; i++; said = P2.slice(0, i); upd(); }, 55); };
    const stop = () => { if (!live) return; live = false; clearInterval(t); root.classList.remove('on'); if (!said) return; round++; root.classList.add('writing'); setTimeout(() => { root.classList.remove('writing'); pill.classList.remove('words'); tx.textContent = (tx.textContent ? tx.textContent + ' ' : '') + said.trim(); cur.style.visibility = 'visible'; wc.textContent = `${tx.textContent.trim().split(/\s+/).length} words`; said = ''; }, reduced ? 0 : 450); };
    let holdOn = null;
    holdable(btn, () => { if (mode === 0) start(); }, () => { if (mode === 0) stop(); });
    btn.addEventListener('click', () => { if (mode === 1) { live ? stop() : start(); $('.hl2', el).textContent = live ? 'Tap to stop' : 'Tap to talk'; } });
    wireSeg(el, 'dmode', (m) => { mode = m; $('.hl2', el).textContent = m ? 'Tap to talk' : 'Hold to talk'; });
    $('[data-read]', el).addEventListener('click', () => {
      const text = tx.textContent.trim() || 'Lisbon weekend'; const ws = text.split(/\s+/);
      tx.innerHTML = ws.map(w => `<span class="rw2">${esc(w)}</span>`).join(' '); const spans = $$('.rw2', tx); root.classList.add('reading'); let k = 0;
      const tick = () => { spans.forEach((s, j) => s.classList.toggle('on', j === k)); $('.rp b', rp).style.width = `${((k + 1) / spans.length) * 100}%`; k++; if (k <= spans.length) setTimeout(tick, reduced ? 0 : 260); else { root.classList.remove('reading'); tx.textContent = text; } };
      tick();
    });
  } };

  /* ---------------------------------------------------------------- Web apps: make one, see what it lacks, it opens as its own app */
  P.webapps = { app: 'Pilot', try: 'Click a recommended site or paste one and <b>Make app…</b>; read what it lacks, pick its window top, then try <b>⌘ Tab</b>', render(el) {
    const REC = [['Gmail', 'mail.google.com', '#EA4335'], ['Google Calendar', 'calendar.google.com', '#4285F4'], ['WhatsApp', 'web.whatsapp.com', '#25D366'], ['Slack', 'app.slack.com', '#611F69'], ['Wikipedia', 'en.wikipedia.org', '#6B6B6B']];
    const made = [];
    const body = `<p class="lead">Any site as its own app, signed with Pilot’s certificate, in ~/Applications: its own Dock icon, Cmd+Tab entry and logins, no browser chrome.</p><div class="card2"><div class="chd">${IC('link')}New web app</div><div class="wrow"><input type="text" class="url" placeholder="Paste a link, e.g. https://x.com" aria-label="A link"><button type="button" class="bt ink" data-make>Make app…</button></div></div><div class="card2"><div class="chd">${IC('star')}Recommended<small>Popular sites as apps</small></div><div class="recs">${REC.map(([n, u, c]) => `<button type="button" data-u="${u}" data-n="${n}" data-c="${c}"><span class="pl">+</span><i style="background:${c}">${n[0]}</i><b>${n}</b><small>${u}</small></button>`).join('')}</div></div><div class="card2"><div class="chd">${IC('apps')}Your web apps<small class="yc">none yet</small></div><div class="yl"></div></div>`;
    el.innerHTML = win('Apps', [['Install', 'Catalogue, web apps, helpers'], ['Open with'], ['Configs']], 0, 'Install', seg('it', ['Catalogue', 'Web apps', 'Helpers'], 1), body) + `<div class="dock3"><i class="d0">${IC('folder')}</i><i class="d1">${IC('globe')}</i><i class="d2">${IC('term')}</i></div><button type="button" class="cmdtab bt">⌘ Tab</button>`;
    $('.win2', el).style.bottom = '70px';
    const dock = $('.dock3', el);
    const ask = (n, u, c) => {
      const sh = document.createElement('div'); sh.className = 'wsheet pn';
      sh.innerHTML = `<b>Make ${esc(n)} a Mac app?</b><p>A web app cannot do everything a browser does. ${esc(n)} will not have:</p><ul><li>Password autofill from your browser</li><li>Browser extensions</li><li>Notifications while it is closed</li></ul><div class="wtop"><small>Window top</small>${seg('wt', ['Nothing', 'On hover', 'Slim strip', 'Title bar'], 1)}</div><div class="wa2"><button type="button" class="bt" data-no>Cancel</button><button type="button" class="bt ink" data-yes>Make ${esc(n)}</button></div>`;
      el.appendChild(sh); let top = 1; wireSeg(sh, 'wt', (i) => { top = i; });
      $('[data-no]', sh).addEventListener('click', () => sh.remove());
      $('[data-yes]', sh).addEventListener('click', () => { sh.innerHTML = `<b>Making ${esc(n)}…</b><p>Signing it with Pilot’s certificate</p><span class="prog"><i></i></span>`; requestAnimationFrame(() => { const p = $('.prog i', sh); if (p) p.style.width = '100%'; }); setTimeout(() => { sh.remove(); made.push([n, u, c]); dock.insertAdjacentHTML('beforeend', `<i class="app" style="background:${c}" title="${esc(n)}">${esc(n[0])}</i>`); $('.yc', el).textContent = `${made.length}`; $('.yl', el).insertAdjacentHTML('beforeend', `<div class="trow" style="grid-template-columns:22px minmax(0,1fr) auto"><span class="ico" style="background:${c};color:#fff;border-color:transparent">${esc(n[0])}</span><span>${esc(n)}<small>${esc(u)} · ~/Applications</small></span><button type="button" class="bt" data-openapp="${made.length - 1}">Open</button></div>`); openApp(made.length - 1, top); }, reduced ? 0 : 1100); });
    };
    const openApp = (i, top = 1) => {
      $$('.wapp', el).forEach(w => w.remove()); const [n, u, c] = made[i];
      const w = document.createElement('div'); w.className = 'wapp pn top' + top;
      w.innerHTML = `${top === 3 ? `<div class="wtb"><span class="dots"><i></i><i></i><i></i></span><b>${esc(n)}</b></div>` : top === 2 ? `<div class="wslim" style="background:${c}"></div>` : `<span class="dots hov"><i></i><i></i><i></i></span>`}<div class="wpage"><aside style="background:${c}"><b>${esc(n[0])}</b>${'<i></i>'.repeat(5)}</aside><div class="wcol"><div class="wh">${esc(u)}</div>${lines([70, 50, 84, 40, 66, 58, 76])}</div></div><button type="button" class="wclose" aria-label="Close ${esc(n)}">✕</button>`;
      el.appendChild(w); setApp(n); $('.wclose', w).addEventListener('click', () => { w.remove(); setApp('Pilot'); });
    };
    $$('[data-u]', el).forEach(b => b.addEventListener('click', () => { if (made.some(m => m[1] === b.dataset.u)) return toast(`${b.dataset.n} is already an app`); ask(b.dataset.n, b.dataset.u, b.dataset.c); }));
    $('[data-make]', el).addEventListener('click', () => { const v = $('.url', el).value.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '') || 'x.com'; const n = v.replace(/^(www|app|web|mail)\./, '').split('.')[0]; ask(n[0].toUpperCase() + n.slice(1), v, '#333333'); });
    el.addEventListener('click', (e) => { const o = e.target.closest('[data-openapp]'); if (o) openApp(+o.dataset.openapp); });
    $('.cmdtab', el).addEventListener('click', () => { const sw = document.createElement('div'); sw.className = 'cmdsw pn'; sw.innerHTML = [['Finder', '#2A7DE1', 'folder'], ['Safari', '#3B82F6', 'globe'], ['Ghostty', '#222', 'term'], ...made.map(([n, , c]) => [n, c, ''])].map(([n, c, i], k, a) => `<span class="${k === a.length - 1 ? 'on' : ''}"><i style="background:${c}">${i ? IC(i) : esc(n[0])}</i><small>${esc(n)}</small></span>`).join(''); el.appendChild(sw); setTimeout(() => sw.remove(), 1600); });
  } };

  /* ---------------------------------------------------------------- Extensions: the catalogue, bar items with their popovers, make one with AI */
  const installed = new Set(), customExt = [];
  const EXTBAR = { weather: 'weather', markets: 'markets', pomodoro: 'timer' };
  const topExt = () => { const t = $('#tb-ext'); if (!t) return; t.innerHTML = [...[...installed].filter(id => !EXTBAR[id]).map(id => { const e = D.exts.find(x => x[0] === id); return e ? e[4] : ''; }), ...customExt.map(c => c[2])].map(x => `<span>${x}</span>`).join(''); };
  P.extensions = { app: 'Pilot', try: '<b>Install</b> Weather or Markets, then click its item in the top bar; or describe one and let the AI make it', render(el) {
    D.exts.forEach(e => { if (EXTBAR[e[0]] && BARON[EXTBAR[e[0]]]) installed.add(e[0]); });
    let side = 1;
    const row = (e) => { const on = installed.has(e[0]); return `<div class="trow erow" style="grid-template-columns:34px minmax(0,1fr) auto"><span class="ico eic">${e[1]}</span><span>${esc(e[2])}<small>${esc(e[3])}</small></span><button type="button" class="bt${on ? '' : ' ink'}" data-x="${e[0]}" aria-pressed="${on}">${on ? 'Installed' : 'Install'}</button></div>`; };
    const draw = () => {
      const inst = D.exts.filter(e => installed.has(e[0]));
      const body = side === 1 ? `<p class="lead">Extensions add commands to Hyper+Space, pages to Pilot and items to the top bar. ${D.exts.length} in the catalogue here; the pilot command drives it all from a terminal or an agent.</p><div class="card2">${D.exts.map(row).join('')}</div><div class="card2 mk2"><div class="chd">${IC('wand')}Make one with AI<small>it writes it, tests it and installs it</small></div><div class="wrow"><input type="text" class="desc" value="Remind me to drink water every hour, with a count in the bar" aria-label="Describe an extension"><button type="button" class="bt ink" data-ai>Make it</button></div><div class="steps2"></div></div>`
        : `<p class="lead">${inst.length + customExt.length ? 'Installed on this Mac.' : 'Nothing installed yet: pick some from the catalogue.'}</p><div class="card2">${inst.map(row).join('')}${customExt.map(c => `<div class="trow erow" style="grid-template-columns:34px minmax(0,1fr) auto"><span class="ico eic">${c[0]}</span><span>${esc(c[1])}<small>Made with AI on this Mac</small></span><span class="k2 s">yours</span></div>`).join('')}</div>`;
      el.innerHTML = win('Extensions', [['Installed', `${inst.length + customExt.length} on this Mac`], ['Catalogue', `${D.exts.length} to add`]], side, side ? 'Catalogue' : 'Installed', '', body);
      $$('.si', el).forEach(b => b.addEventListener('click', () => { side = +b.dataset.side; draw(); }));
      $$('[data-x]', el).forEach(b => b.addEventListener('click', () => { const id = b.dataset.x; const on = !installed.has(id); on ? installed.add(id) : installed.delete(id); if (EXTBAR[id]) { BARON[EXTBAR[id]] = on ? 1 : 0; if (id === 'pomodoro') tmr.run = on; } applyBar(); topExt(); draw(); if (on) { toast(`${D.exts.find(e => e[0] === id)[2]} installed: it is in the top bar`); const it = $(`#desk [data-tb="${EXTBAR[id] === 'timer' ? 'timer' : EXTBAR[id]}"]`); if (it && POPS[EXTBAR[id] === 'timer' ? 'timer' : EXTBAR[id]]) setTimeout(() => openPop(it, EXTBAR[id] === 'timer' ? 'timer' : EXTBAR[id]), 250); } }));
      $('[data-ai]', el)?.addEventListener('click', () => { const s = $('.steps2', el); const steps = ['Writing water-reminder/index.ts', 'Testing: 4 checks passed', 'Installed: 💧 in the top bar']; s.innerHTML = ''; steps.forEach((t2, k) => setTimeout(() => { s.insertAdjacentHTML('beforeend', `<p>${k < 2 ? '<span class="spin"></span>' : '<span class="ok">✓</span>'}${t2}</p>`); if (k === 2) { if (!customExt.length) customExt.push(['💧', 'Water reminder', '💧 0/8']); topExt(); $$('.spin', s).forEach(x => x.outerHTML = '<span class="ok">✓</span>'); } }, reduced ? 0 : 600 * (k + 1))); });
    };
    draw();
  } };

  /* ---------------------------------------------------------------- Look: style, the menu's look, window layout, Pilot's themes, glass */
  P.look = { app: 'Pilot', try: 'Click a <b>theme</b>: the whole desktop takes it, top bar included; try <b>Toybox</b> and the menu looks', render(el) {
    const mini = (t) => `<span class="tmini" style="background:${t[4]};border-color:${t[9]}"><span class="td">${[t[13], t[11], t[12]].map(c => `<i style="background:${c}"></i>`).join('')}</span><span class="tl3"><i style="background:${t[6]};border-color:${t[8]}"></i><i style="background:${t[7]}"></i></span><span class="tln">${[70, 50, 84].map(w => `<i style="width:${w}%;background:${t[12]}"></i>`).join('')}</span><span class="tbars">${[40, 70, 55, 90, 62].map((h, k) => `<i style="height:${h}%;background:${k % 2 ? t[13] : t[11]}"></i>`).join('')}</span></span>`;
    const menuLook = (k) => `<span class="mlook ${k}"><span class="q"></span>${k === 'rail' ? '<span class="rl"><i></i><i></i><i></i></span>' : ''}<span class="rs">${[1, 1, 1, 1].map((_, j) => `<i class="${j === 0 ? 'on' : ''}"></i>`).join('')}</span></span>`;
    const body = `<div class="ph">Style</div><div class="stl">${[['Instrument', 'Hairlines, mono numbers, one signal colour'], ['Toybox', 'Chunky keycaps, candy colours']].map(([n, d], i) => `<button type="button" data-st="${i}" aria-pressed="${i === 0}"><b>${n}</b><small>${d}</small><span class="kp"><span class="k2 s">Hyper</span><span class="k2 s">Space</span></span></button>`).join('')}</div><div class="ph">Hyper+Space menu</div><div class="mlooks">${[['line', 'Line', 'Default. Classic’s list; the first key grows into a wide search.'], ['classic', 'Classic', 'A terminal pane, bigger mono, keys on the left.'], ['rail', 'Rail', 'The kinds down the left, each with its count.']].map(([k, n, d], i) => `<button type="button" data-ml="${k}" aria-pressed="${i === 0}">${menuLook(k)}<b>${n}</b><small>${d}</small></button>`).join('')}</div><div class="ph">Theme</div><div class="thm2">${D.themes.map((t, i) => `<button type="button" data-t="${i}" aria-pressed="false">${mini(t)}<b>${t[1]}</b><small>${t[2]}</small></button>`).join('')}</div><div class="glr"><span>Glass</span>${seg('gl', ['Glass', 'Solid'], 0)}<small>The window, the menu, clipboard history, notes and Quick AI on the top bar’s Liquid Glass.</small></div>`;
    el.innerHTML = win('Desktop', [['Tiling', 'Running'], ['Menu bar', 'Top bar on'], ['Look', 'Instrument · Void']], 2, 'Look', '', body);
    const desk = $('#desk');
    $$('[data-t]', el).forEach(b => b.addEventListener('click', () => {
      const t = D.themes[+b.dataset.t]; $$('[data-t]', el).forEach(x => x.setAttribute('aria-pressed', x === b));
      const s = desk.style; const sel = t[3] ? 0.16 : 0.14;
      s.setProperty('--m-bg', t[6]); s.setProperty('--m-bg2', t[7]); s.setProperty('--m-rail', t[5]); s.setProperty('--m-line', t[9]); s.setProperty('--m-fg', t[10]); s.setProperty('--m-fg2', t[11]); s.setProperty('--m-fg3', t[12]);
      s.setProperty('--m-sel', `color-mix(in srgb, ${t[13]} ${sel * 100}%, ${t[6]})`); s.setProperty('--m-barbg', `color-mix(in srgb, ${t[4]} 80%, transparent)`);
      s.setProperty('--m-wall', `radial-gradient(120% 90% at 85% 0%, color-mix(in srgb, ${t[13]} 30%, ${t[4]}) 0%, transparent 60%), linear-gradient(170deg, ${t[7]}, ${t[4]})`);
      s.setProperty('--lime', t[13]); s.setProperty('--lime-edge', t[13]); s.setProperty('--lime-ink', t[13]); s.setProperty('--on-lime', t[3] ? t[5] : '#FFFFFF');
      const sm = $('.side .si.on small', el); if (sm) sm.textContent = `${$('[data-st][aria-pressed=true] b', el).textContent} · ${t[1]}`; toast(`${t[1]}: every Pilot surface takes it`);
    }));
    $$('[data-st]', el).forEach(b => b.addEventListener('click', () => { $$('[data-st]', el).forEach(x => x.setAttribute('aria-pressed', x === b)); desk.classList.toggle('toybox', b.dataset.st === '1'); }));
    $$('[data-ml]', el).forEach(b => b.addEventListener('click', () => { $$('[data-ml]', el).forEach(x => x.setAttribute('aria-pressed', x === b)); toast(`The Hyper+Space menu opens as ${b.querySelector('b').textContent}`); }));
    wireSeg(el, 'gl', (i) => desk.classList.toggle('solid', i === 1));
  } };

  /* ---------------------------------------------------------------- Desktop and widgets (1.0.2, 1.0.3): the desk widgets (WidgetRenders,
     DeskWidgetRenders), Hyper + right-click's desktop menu (DesktopMenu), the wallpaper Gallery (GalleryWindow) and Home's grid
     (HomeLayoutRenders). A page cannot see Hyper, so a plain right-click (or a tap) stands in for it. */
  const WALLS = [
    ['Dunes', 'linear-gradient(165deg, #F2C48D 0%, #D9875A 42%, #7A3F33 100%)'], ['Night', 'radial-gradient(90% 70% at 70% 20%, #3B4C8C 0%, #141A33 55%, #07090F 100%)'],
    ['Fern', 'radial-gradient(80% 80% at 20% 90%, #9CC77A 0%, #3E6B3A 45%, #16261A 100%)'], ['Tide', 'linear-gradient(200deg, #BFE3EA 0%, #4E9BB4 45%, #173B57 100%)'],
    ['Haze', 'radial-gradient(100% 80% at 85% 10%, #E6F7A8 0%, #A7C66A 30%, #2E3A26 100%)'], ['Paper', 'linear-gradient(180deg, #F4F1EA 0%, #E2DDD2 100%)'],
    ['Ember', 'radial-gradient(90% 90% at 50% 100%, #FF8A4C 0%, #9B2D3A 50%, #1B0C14 100%)'], ['Slate', 'linear-gradient(150deg, #5D6672 0%, #2B3038 60%, #15181C 100%)'],
  ];
  const NOTES_MD = [['Launch week', 'Record the film · Site pass · Post at 16:00'], ['Reading list', 'Designing Data-Intensive Apps, ch. 7'], ['Groceries', 'Oats, lemons, coffee beans'], ['Ideas', 'A widget for the train times']];
  P.desktop = { app: 'Finder', try: '<b>Right-click</b> (or tap) the bare desktop: <b>Change wallpaper</b>, <b>Add widget</b>, <b>Desktop icons</b>; drag a widget (Hyper + drag in Pilot); open <b>Home</b> and drag a block’s corner', render(el) {
    const desk = $('#desk');
    const st = { icons: true, playing: true, home: false, view: 0 };
    const spark = '0,30 12,26 24,28 36,18 48,21 60,12 72,15 84,8 96,11 108,4 120,6';
    const W = {
      clock: [.03, .05, 240, 128, () => `<div class="wg-clock"><p class="eb"><span>Clock · Lisbon</span><span>${now().toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</span></p><b>${hhmm()}</b><small>${now().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}</small></div>`],
      music: [.03, .36, 260, 110, () => `<div class="wg-np"><i class="art"></i><span class="tx"><p class="eb"><span>Now playing</span></p><b>Night Trains</b><small>Pilot film</small><span class="ctl"><button type="button" data-np="prev" aria-label="Previous">${IC('chev')}</button><button type="button" class="pp" data-np="play" aria-label="${st.playing ? 'Pause' : 'Play'}">${st.playing ? '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 3h2.5v10H4.5zM9 3h2.5v10H9z" fill="currentColor"/></svg>' : '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3v10l8-5z" fill="currentColor"/></svg>'}</button><button type="button" data-np="next" aria-label="Next">${IC('chev')}</button></span></span></div>`],
      markets: [.30, .05, 300, 150, () => `<div class="wg-mk"><p class="eb"><span>BTCUSD</span><span>Crypto</span></p><p class="px"><b>77,907.05</b><small>▲ 1.84%</small></p><button type="button" class="chart" data-tv aria-label="Open BTCUSD on TradingView"><svg viewBox="0 0 120 34" preserveAspectRatio="none"><polyline points="${spark}"/></svg></button><span class="rk">${['1D', '1W', '1M', '1Y'].map((k, i) => `<button type="button" data-rk aria-pressed="${i === 0}">${k}</button>`).join('')}</span></div>`],
      github: [.30, .40, 300, 96, () => `<div class="wg-gh"><p class="eb"><span>GitHub</span><span>1,284 this year</span></p><span class="cells">${Array.from({ length: 26 * 5 }, (_, i) => `<i style="--a:${[0, 0, .14, .14, .3, .5, .75, 0, .3][(i * 7 + (i >> 3) * 5) % 9]}"></i>`).join('')}</span></div>`],
      notes: [.58, .05, 220, 172, () => `<div class="wg-nt"><p class="eb"><span>Notes</span><span>${NOTES_MD.length}</span></p>${NOTES_MD.map(([t]) => `<span>${t}</span>`).join('')}</div>`],
      folder: [.58, .42, 220, 76, () => `<div class="wg-fd"><p class="eb"><span>Downloads</span><span>3</span></p><span class="fl">${[['doc', 'invoice.pdf'], ['video', 'clip.mov'], ['image', 'IMG_2041']].map(([i, n]) => `<span>${IC(i)}<small>${n}</small></span>`).join('')}</span></div>`],
      mac: [0, 0, 176, 104, () => `<div class="wg-mac"><p class="eb"><span>This Mac</span></p>${[['CPU', 18], ['Mem', 56], ['Disk', 71]].map(([n, v]) => `<p><span>${n}</span><i><b style="width:${v}%"></b></i><small>${v}%</small></p>`).join('')}</div>`],
      weather: [0, 0, 176, 84, () => `<div class="wg-wx"><p class="eb"><span>Lisbon · Sunny</span></p><b>24°</b><small>H 26° · L 19°</small></div>`],
    };
    const TITLES = { clock: 'Clock and calendar', music: 'Now playing', markets: 'Markets', github: 'GitHub', notes: 'Notes', folder: 'Folder', mac: 'This Mac', weather: 'Weather' };
    const placed = ['clock', 'music', 'markets', 'github', 'notes', 'folder'];
    el.innerHTML = `<div class="p-desk"><div class="dk"><div class="dk-ic">${[['folder', 'Projects'], ['image', 'Screenshot.png'], ['doc', 'Invoice.pdf']].map(([i, n]) => `<span>${IC(i)}<small>${n}</small></span>`).join('')}</div><div class="dk-w"></div></div><div class="home2" hidden></div><div class="bar">${seg('dv', ['Desktop', 'Home'], 0)}<span class="sp"></span><button type="button" class="bt" data-open>${IC('rightclick')}Desktop menu</button></div></div>`;
    const root = $('.p-desk', el), dk = $('.dk', el), wl = $('.dk-w', el);
    const pos = {};
    const draw = () => {
      wl.innerHTML = placed.map(k => { const [x, y, w, h, body] = W[k]; const p = pos[k] || (pos[k] = [Math.round(x * dk.clientWidth), Math.round(y * dk.clientHeight)]); return `<div class="wg pn" data-w="${k}" style="left:${p[0]}px;top:${p[1]}px;width:${w}px;height:${h}px" aria-label="${TITLES[k]} widget">${body()}</div>`; }).join('');
    };
    const setWall = (i, scope) => { dk.style.background = WALLS[i][1]; dk.dataset.w = i; if (scope) toast(`${WALLS[i][0]} is the wallpaper for this ${scope}`); };
    const close = () => $$('.cmenu2, .gal', el).forEach(m => m.remove());
    const place = (m, x, y) => { const r = el.getBoundingClientRect(); m.style.left = Math.max(8, Math.min(x - r.left, r.width - m.offsetWidth - 8)) + 'px'; m.style.top = Math.max(8, Math.min(y - r.top, r.height - m.offsetHeight - 8)) + 'px'; };
    const gallery = () => {
      close(); const g = document.createElement('div'); g.className = 'gal pn'; g.setAttribute('role', 'dialog'); g.setAttribute('aria-label', 'Gallery');
      const body = (v) => v === 0
        ? WALLS.map(([n, bg], i) => `<button type="button" class="gc${dk.dataset.w !== undefined && +dk.dataset.w === i ? ' on' : ''}" data-wall="${i}"><i style="background:${bg}"></i><small>${n.toLowerCase()}.jpg</small></button>`).join('')
        : NOTES_MD.map(([t, l]) => `<button type="button" class="gc md" data-md><span><b>${t}</b><small>${l}</small></span><small>${t.toLowerCase().replace(/ /g, '-')}.md</small></button>`).join('');
      g.innerHTML = `<div class="gt"><span class="dots"><i></i><i></i><i></i></span><b>Gallery</b><small data-gn>Wallpapers · ${WALLS.length} pictures</small><span class="sp"></span>${seg('gf', ['Wallpapers', 'Notes'], 0)}</div><div class="gg">${body(0)}</div><div class="gs"><span data-gs>A click sets it for this screen</span><span class="sp"></span>${seg('gsc', ['Screen', 'Workspace'], 0)}</div>`;
      el.appendChild(g); let scope = 'screen';
      wireSeg(g, 'gf', (v) => { $('.gg', g).innerHTML = body(v); $('[data-gn]', g).textContent = v ? `~/Notes · ${NOTES_MD.length} notes` : `Wallpapers · ${WALLS.length} pictures`; $('[data-gs]', g).textContent = v ? 'A click previews; right-click acts' : `A click sets it for this ${scope}`; });
      wireSeg(g, 'gsc', (v) => { scope = v ? 'workspace' : 'screen'; $('[data-gs]', g).textContent = `A click sets it for this ${scope}`; });
      $('.gg', g).addEventListener('click', (e) => {
        const b = e.target.closest('[data-wall]'); if (b) { setWall(+b.dataset.wall, scope); $$('[data-wall]', g).forEach(x => x.classList.toggle('on', x === b)); return; }
        const m = e.target.closest('[data-md]'); if (m) toast(`${$('b', m).textContent}: a preview, as Quick Look shows it`);
      });
    };
    const menu = (x, y) => {
      close(); const free = Object.keys(W).filter(k => !placed.includes(k));
      const m = document.createElement('div'); m.className = 'cmenu2 pn'; m.setAttribute('role', 'menu');
      m.innerHTML = `<div class="mh2">${LOGO_MINI}<b>Pilot</b><span>Desktop</span></div>${[['gallery', 'Change wallpaper…', 'gal'], ['mountain', 'Wallpaper settings…', 'set']].map(([i, n, a]) => `<button type="button" class="mi" role="menuitem" data-m="${a}">${IC(i)}<span>${n}</span></button>`).join('')}<div class="sub2"><span class="mi lbl">${IC('widgets')}<span>Add widget</span></span><div class="fmts2">${free.length ? free.map(k => `<button type="button" data-add="${k}">${TITLES[k]}</button>`).join('') : '<small>Every widget is placed</small>'}</div></div>${[['note', 'New note', 'note', 'Hyper+N'], ['display', 'Show desktop', 'show', '⌥↓'], ['shapes', 'Style: Instrument', 'style', ''], ['eyeoff', 'Desktop icons', 'icons', st.icons ? '✓' : '']].map(([i, n, a, k]) => `<button type="button" class="mi" role="menuitem" data-m="${a}">${IC(i)}<span>${n}</span>${k ? `<small>${k}</small>` : ''}</button>`).join('')}`;
      el.appendChild(m); place(m, x, y);
      m.addEventListener('click', (ev) => {
        const add = ev.target.closest('[data-add]'); if (add) { const k = add.dataset.add, r = dk.getBoundingClientRect(); pos[k] = [Math.max(8, Math.min(x - r.left, r.width - W[k][2] - 8)), Math.max(8, Math.min(y - r.top, r.height - W[k][3] - 8))]; placed.push(k); draw(); m.remove(); toast(`${TITLES[k]} sits where you clicked`); return; }
        const a = ev.target.closest('[data-m]'); if (!a) return; m.remove();
        ({ gal: gallery, set: () => toast('Look › Wallpaper opens at this screen’s row'), note: () => toast('A new note opens in the notes panel'),
           show: () => toast('Every window steps aside; a click in the Dock brings one back'), style: () => toast('Style and theme switch here as on the Look page'),
           icons: () => { st.icons = !st.icons; $('.dk-ic', el).hidden = !st.icons; toast(st.icons ? 'Finder’s desktop icons are back' : 'Finder’s desktop icons are hidden'); } })[a.dataset.m]();
      });
    };
    dk.addEventListener('contextmenu', (e) => { if (e.target.closest('.wg')) { e.preventDefault(); const k = e.target.closest('.wg').dataset.w; close(); const m = document.createElement('div'); m.className = 'cmenu2 pn'; m.innerHTML = `<div class="mh2">${LOGO_MINI}<b>${TITLES[k]}</b><span>Widget</span></div><button type="button" class="mi" data-e>${IC('edit')}<span>Edit widget…</span></button><button type="button" class="mi" data-r>${IC('xwin')}<span>Remove from desktop</span></button>`; el.appendChild(m); place(m, e.clientX, e.clientY); m.addEventListener('click', (ev) => { if (ev.target.closest('[data-r]')) { placed.splice(placed.indexOf(k), 1); draw(); toast(`${TITLES[k]} left the desktop; Add widget brings it back`); } else if (ev.target.closest('[data-e]')) toast('Edit widget: its layout, symbols, folder or note'); m.remove(); }); return; } e.preventDefault(); menu(e.clientX, e.clientY); });
    dk.addEventListener('click', (e) => {
      if (e.target.closest('.gal, .cmenu2')) return;
      const np = e.target.closest('[data-np]'); if (np) { if (np.dataset.np === 'play') { st.playing = !st.playing; draw(); } else toast(np.dataset.np === 'next' ? 'Next track' : 'Previous track'); return; }
      if (e.target.closest('[data-tv]')) { toast('BTC opens on TradingView'); return; }
      const rk = e.target.closest('[data-rk]'); if (rk) { $$('[data-rk]', rk.parentNode).forEach(x => x.setAttribute('aria-pressed', x === rk)); return; }
      if (e.target.closest('.wg')) return;
      if ($('.cmenu2, .gal', el)) { close(); return; }
      menu(e.clientX, e.clientY);
    });
    $('[data-open]', el).addEventListener('click', (e) => { e.stopPropagation(); const r = dk.getBoundingClientRect(); menu(r.left + r.width * .62, r.top + r.height * .3); });
    /* drag a widget: Hyper + drag in Pilot */
    wl.addEventListener('pointerdown', (e) => {
      const w = e.target.closest('.wg'); if (!w || e.button !== 0 || e.target.closest('button') || getComputedStyle(w).position !== 'absolute') return;
      const k = w.dataset.w, r = dk.getBoundingClientRect(), sx = e.clientX, sy = e.clientY, [ox, oy] = pos[k]; w.setPointerCapture(e.pointerId); w.classList.add('drag');
      const mv = (ev) => { pos[k] = [Math.max(0, Math.min(ox + ev.clientX - sx, r.width - w.offsetWidth)), Math.max(0, Math.min(oy + ev.clientY - sy, r.height - w.offsetHeight))]; w.style.left = pos[k][0] + 'px'; w.style.top = pos[k][1] + 'px'; };
      const up = () => { w.classList.remove('drag'); w.removeEventListener('pointermove', mv); w.removeEventListener('pointerup', up); };
      w.addEventListener('pointermove', mv); w.addEventListener('pointerup', up);
    });
    /* Home: blocks on a grid of cells, each resized by its corner (Edit Home) */
    const H = [['Status', 'ok', 4, 2, '<p class="hs"><i></i>Pilot is running · 51 binds on Hyper</p>'], ['Keyboard map', 'command', 8, 4, `<div class="hk">${'QWERTYUIOPASDFGHJKLZXCVBNM'.split('').map((c, i) => `<i class="${[1, 4, 9, 12, 17, 22].includes(i) ? 'on' : ''}">${c}</i>`).join('')}</div>`], ['This Mac', 'laptop', 4, 2, '<p class="hs">CPU 18% · Memory 56% · Disk 71%</p>'], ['Now playing', 'music', 4, 2, '<p class="hs">Night Trains · Pilot film</p>'], ['Most used', 'trend', 6, 2, '<p class="hs">Hyper+Space · Hyper+V · Hyper+1</p>']];
    const home = $('.home2', el);
    const drawHome = () => {
      home.innerHTML = `<div class="hh"><b>Home</b><span class="sp"></span><button type="button" class="bt${st.edit ? ' ink' : ''}" data-edit>${st.edit ? 'Done' : 'Edit Home'}</button></div><div class="hg${st.edit ? ' edit' : ''}">${H.map(([t, i, c, r, b], n) => `<div class="hb pn" data-b="${n}" style="grid-column:span ${c};grid-row:span ${r}"><p class="ht">${IC(i)}${t}${st.edit ? `<small>${c} × ${r}</small>` : ''}</p>${b}${st.edit ? `<span class="grip" data-grip="${n}" role="slider" tabindex="0" aria-label="Resize ${t}: arrow keys" aria-valuetext="${c} by ${r} cells"></span>` : ''}</div>`).join('')}</div>`;
      $('[data-edit]', home).addEventListener('click', () => { st.edit = !st.edit; drawHome(); if (st.edit) toast('Drag a block’s corner: the others make room'); });
    };
    const resize = (n, dc, dr) => { H[n][2] = Math.max(2, Math.min(12, H[n][2] + dc)); H[n][3] = Math.max(1, Math.min(5, H[n][3] + dr)); };
    home.addEventListener('pointerdown', (e) => {
      const g = e.target.closest('[data-grip]'); if (!g) return; e.preventDefault();
      const n = +g.dataset.grip, cell = $('.hg', home).getBoundingClientRect().width / 12, sx = e.clientX, sy = e.clientY, c0 = H[n][2], r0 = H[n][3];
      const mv = (ev) => { const c = Math.round((ev.clientX - sx) / cell), r = Math.round((ev.clientY - sy) / 34); if (c0 + c !== H[n][2] || r0 + r !== H[n][3]) { H[n][2] = c0; H[n][3] = r0; resize(n, c, r); drawHome(); } };
      const up = () => { removeEventListener('pointermove', mv); removeEventListener('pointerup', up); };
      addEventListener('pointermove', mv); addEventListener('pointerup', up);
    });
    home.addEventListener('keydown', (e) => { const g = e.target.closest('[data-grip]'); const d = { ArrowRight: [1, 0], ArrowLeft: [-1, 0], ArrowDown: [0, 1], ArrowUp: [0, -1] }[e.key]; if (!g || !d) return; e.preventDefault(); const n = +g.dataset.grip; resize(n, ...d); drawHome(); $(`[data-grip="${n}"]`, home)?.focus(); });
    wireSeg(el, 'dv', (v) => { close(); st.home = v === 1; dk.hidden = st.home; home.hidden = !st.home; setApp(st.home ? 'Pilot' : 'Finder'); if (st.home) drawHome(); });
    draw();
    if (desk) desk.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  } };

  /* ================================================================ the mini Pilot desktop (preview pass, Sven 2026-10-29, Q576)
     One desktop with Pilot's real top bar; the sidebar of areas drives it. Each surface is drawn from Pilot's own offscreen renders:
     the menu (InstrumentMenuRenders), Binds (InstrumentBindsRenders, Pilot default from PilotDefault.swift), the clipboard panel
     (ClipboardTabsRenders), the top bar and its popovers (InstrumentTopBarRenders), AI chat (AIChatPanelRenders), the selection box
     (SelectionBoxRenders), Stats (StatsViewsRenders) and the capture editor (CaptureEditorRenders). */
  const LOGO_MINI = '<svg viewBox="0 0 1024 1024" class="lgo" aria-hidden="true"><rect x="8" y="8" width="1008" height="1008" rx="232" fill="currentColor" opacity=".14"/><rect x="242" y="242" width="248" height="248" rx="58" fill="var(--lime)"/><rect x="534" y="242" width="248" height="248" rx="58" fill="currentColor"/><rect x="242" y="534" width="248" height="248" rx="58" fill="currentColor"/><rect x="534" y="534" width="248" height="248" rx="58" fill="currentColor"/></svg>';
  const toast = (msg) => { const d = $('#desk'); if (!d) return; let t = $('.dtoast', d); if (!t) { t = document.createElement('div'); t.className = 'dtoast'; d.appendChild(t); } t.textContent = msg; t.classList.remove('on'); void t.offsetWidth; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 1800); };
  const closePop = () => $$('#desk .pop2').forEach(p => p.remove());
  const popAt = (btn, html, cls = '') => { closePop(); const desk = $('#desk'), r = btn.getBoundingClientRect(), s = desk.getBoundingClientRect(); const p = document.createElement('div'); p.className = 'pop2 pn ' + cls; p.innerHTML = html; desk.appendChild(p); const w = p.offsetWidth; p.style.left = Math.max(8, Math.min(r.left - s.left + r.width / 2 - w / 2, s.width - w - 8)) + 'px'; return p; };
  const now = () => new Date();
  const hhmm = (d = now()) => d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  const dayLabel = (d = now()) => d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }).replace(',', '');
  const week = (d) => { const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())); const day = t.getUTCDay() || 7; t.setUTCDate(t.getUTCDate() + 4 - day); const y = new Date(Date.UTC(t.getUTCFullYear(), 0, 1)); return Math.ceil(((t - y) / 864e5 + 1) / 7); };
  /* the top bar as Pilot draws it (InstrumentTopBarRenders): every item a button with its own popover; Desktop › Menu bar switches them */
  const BARON = { ws: 1, app: 1, timer: 0, weather: 0, markets: 0, term: 1, ask: 1, cpu: 1, ram: 1, net: 1, vol: 1, kb: 1, wifi: 1, batt: 1, clock: 1 };
  const BARITEMS = [['ws', 'Workspaces', 'grid', 'left'], ['app', 'Focused app', 'apps', 'left'], ['timer', 'Focus timer', 'timer', 'centre'], ['weather', 'Weather (extension)', 'sun', 'right'], ['markets', 'Markets (extension)', 'trend', 'right'], ['term', 'Terminal', 'term', 'right'], ['ask', 'Ask AI', 'spark', 'right'], ['cpu', 'CPU', 'chip', 'right'], ['ram', 'Memory', 'stack', 'right'], ['net', 'Network', 'arrows', 'right'], ['vol', 'Volume', 'speaker', 'right'], ['kb', 'Keyboard layout', 'text', 'right'], ['wifi', 'Wi-Fi', 'arrowcirc', 'right'], ['batt', 'Battery', 'battery', 'right'], ['clock', 'Clock', 'cal', 'right']];
  const topBar = () => `<div class="tb2"><button type="button" class="tbi tbp" data-tb="pilot" aria-label="Pilot's menu">${LOGO_MINI}</button><span class="tbws" data-bi="ws"><button type="button" class="tbg" data-tb="wslist" aria-label="3 workspaces">${IC('grid')}3</button>${[1, 2, 3].map(n => `<button type="button" data-ws="${n}" class="${n === 2 ? 'on' : ''}" aria-label="Workspace ${n}">${n}</button>`).join('')}</span><button type="button" class="tbi tbapp" data-tb="app" data-bi="app"><span class="tbic">${IC('apps')}</span><span id="tb-app">Pilot</span></button><span class="tbmid"><button type="button" class="tbi tbtimer" data-tb="timer" data-bi="timer"><i class="dot"></i>Focus <b id="tb-timer">25:00</b></button></span><span class="tbr"><span class="ext" id="tb-ext"></span><button type="button" class="tbi" data-tb="weather" data-bi="weather">☀️ <b>24°</b></button><button type="button" class="tbi" data-tb="markets" data-bi="markets">SPY <b class="up">▲0.28%</b></button><button type="button" class="tbi opt2" data-tb="term" data-bi="term" aria-label="Terminal">${IC('term')}<span>TERMINAL</span></button><button type="button" class="tbi opt2" data-tb="ask" data-bi="ask" aria-label="Ask AI">${IC('spark')}<span>ASK AI</span></button><button type="button" class="tbi rd opt" data-tb="read" data-bi="cpu"><i>CPU</i><b id="tb-cpu">9%</b></button><button type="button" class="tbi rd opt" data-tb="read" data-bi="ram"><i>RAM</i><b>56%</b></button><button type="button" class="tbi rd opt3" data-tb="read" data-bi="net"><i>NET</i><b>↓1.2M ↑40K</b></button><span class="sep opt"></span><button type="button" class="tbi opt" data-tb="vol" data-bi="vol" aria-label="Volume">${IC('speaker')}</button><button type="button" class="tbi opt3" data-tb="kb" data-bi="kb"><b>BR</b></button><button type="button" class="tbi opt" data-tb="wifi" data-bi="wifi" aria-label="Wi-Fi">${IC('arrowcirc')}</button><button type="button" class="tbi opt" data-tb="batt" data-bi="batt">${IC('battery')}<b>82%</b></button><span class="sep opt"></span><button type="button" class="tbi tbclock" data-tb="clock" data-bi="clock"><span class="opt">${dayLabel()}</span><b id="tb-time">${hhmm()}</b></button></span></div>`;
  const applyBar = () => $$('#desk [data-bi]').forEach(e => { e.hidden = !BARON[e.dataset.bi]; });
  const spk = (pts, w = 120, h = 22) => { const mx = Math.max(...pts) * 1.15; const d = 'M' + pts.map((v, i) => `${(i * w / (pts.length - 1)).toFixed(1)},${(h - v / mx * h).toFixed(1)}`).join('L'); return `<svg class="spk" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none"><path d="${d}"/></svg>`; };
  const wave = (n, base, amp) => Array.from({ length: n }, (_, i) => base + amp * Math.sin(i / 2.2) + amp * .6 * Math.sin(i * 1.7));
  const tmr = { total: 1500, left: 1500, run: false, paused: false };
  const tmrText = () => `${String(Math.floor(tmr.left / 60)).padStart(2, '0')}:${String(tmr.left % 60).padStart(2, '0')}`;
  const ends = () => { const d = new Date(Date.now() + tmr.left * 1000); return hhmm(d); };
  const POPS = {
    wslist: () => `<div class="wsl"><b class="ttl">Workspaces</b>${[[1, 'Ghostty, Zed'], [2, 'Safari, Mail'], [3, 'Music']].map(([n, a]) => `<button type="button" class="${n === +($('#desk .tbws .on')?.dataset.ws || 2) ? 'on' : ''}" data-wsgo="${n}"><i>${n}</i>${a}</button>`).join('')}</div>`,
    app: () => `<div class="appc"><span class="aic">${IC('apps')}</span><span><b>${esc($('#tb-app')?.textContent || 'Pilot')}</b><small>Workspace ${$('#desk .tbws .on')?.dataset.ws || 2}</small></span></div>`,
    timer: () => { const r = 46, c = 2 * Math.PI * r, p = tmr.left / tmr.total; return `<div class="tmr"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="${r}" class="bgc"/><circle cx="55" cy="55" r="${r}" class="fgc" stroke-dasharray="${c.toFixed(1)}" stroke-dashoffset="${(c * (1 - p)).toFixed(1)}"/></svg><b class="tt">${tmrText()}</b><b class="tn">Focus</b><small>${tmr.paused ? 'Paused' : 'Ends at ' + ends()}</small><div class="ta"><button type="button" class="bt ink" data-tmr="pause">${tmr.paused ? 'Resume' : 'Pause'}</button><button type="button" class="bt" data-tmr="skip">Skip</button></div></div>`; },
    read: () => `<div class="rdg">${[['CPU', wave(30, 9, 3), cpuNow + '%'], ['RAM', wave(30, 56, 1.5).map((v, i) => v + i * .05), '56%'], ['NET', wave(30, 1.2, .5).map(Math.abs), '1.2 MB/s']].map(([n, s, v]) => `<div class="rr"><span>${n}</span>${spk(s)}<b>${v}</b></div>`).join('')}<button type="button" class="bt" data-go2="stats">Open Stats in Pilot</button></div>`,
    vol: () => `<div class="snd"><div class="sh"><b>Sound</b><span id="volv">50 %</span></div><div class="sl">${IC('speaker')}<input type="range" min="0" max="100" value="50" aria-label="Volume"></div><small class="ph">Output</small>${[['MacBook Speakers', 1], ['Studio Display', 0], ['AirPods Pro', 0]].map(([n, on]) => `<button type="button" class="sro${on ? ' on' : ''}">${IC('speaker')}<span>${n}</span>${on ? '<i>✓</i>' : ''}</button>`).join('')}</div>`,
    wifi: () => `<div class="wifi"><div class="sh"><b>Wi-Fi</b><span>On</span></div><p><span>Signal</span> −55 dBm · 3 of 4</p><p><span>Rate</span> 573 Mb/s</p><small>The network’s name needs Location access, which Pilot never asks.</small><button type="button" class="bt" data-go2="stats">Wi-Fi in Pilot</button></div>`,
    batt: () => `<div class="batt">${IC('battery')}<b>82%</b><small>Charging · health 96 %</small></div>`,
    kb: () => `<div class="wsl"><b class="ttl">Keyboard layout</b><button type="button" class="on"><i>BR</i>British</button><button type="button"><i>US</i>U.S.</button><button type="button"><i>PT</i>Portuguese</button></div>`,
    weather: () => `<div class="wx"><div class="sh"><b>☀️ 24°</b><span>Valletta</span></div><p>Feels like 26°, high 27°, low 19°, rain 10 %, wind 14 km/h</p><div class="hrs">${['Now', '22', '23', '00', '01', '02'].map((h, i) => `<span><small>${h}</small>${i < 2 ? '☀️' : '🌙'}<b>${24 - i}°</b></span>`).join('')}</div><small class="src">Weather extension · free data from Open-Meteo</small></div>`,
    markets: () => `<div class="mkt">${[['SPY', '582.10', '+0.28%', 1], ['BTC', '68,240', '+1.4%', 1], ['EURUSD', '1.0821', '−0.12%', 0]].map(([s, p, c, up]) => `<div class="mr"><b>${s}</b>${spk(wave(24, 10, up ? 1.2 : 1).map((v, i) => v + (up ? i * .08 : -i * .05)), 80, 18)}<span>${p}</span><em class="${up ? 'up' : 'dn'}">${c}</em></div>`).join('')}<small class="src">Markets extension · TradingView data</small></div>`,
  };
  const openPop = (it, k) => {
    if ($(`#desk .pop2.p-${k}`)) { closePop(); return; }
    const p = popAt(it, POPS[k](), 'p-' + k);
    p.addEventListener('click', (ev) => {
      const w = ev.target.closest('[data-wsgo]'); if (w) { const b = $(`#desk .tbws [data-ws="${w.dataset.wsgo}"]`); closePop(); b?.click(); return; }
      const g = ev.target.closest('[data-go2]'); if (g) { closePop(); show(g.dataset.go2); return; }
      const t = ev.target.closest('[data-tmr]'); if (t) { if (t.dataset.tmr === 'pause') tmr.paused = !tmr.paused; else { tmr.left = tmr.total; tmr.paused = false; toast('Focus skipped; break next'); } p.innerHTML = POPS.timer(); return; }
      const o = ev.target.closest('.sro'); if (o) { $$('.sro', p).forEach(x => { x.classList.toggle('on', x === o); $('i', x)?.remove(); }); o.insertAdjacentHTML('beforeend', '<i>✓</i>'); }
    });
    const r = $('input[type=range]', p); if (r) r.addEventListener('input', () => { $('#volv', p).textContent = r.value + ' %'; });
  };
  setInterval(() => { if (!tmr.run || tmr.paused) return; tmr.left = Math.max(0, tmr.left - 1); const t = $('#tb-timer'); if (t) t.textContent = tmrText(); const p = $('#desk .pop2.p-timer'); if (p && !reduced) { const c = $('.fgc', p), tt = $('.tt', p); if (c) { const L = 2 * Math.PI * 46; c.setAttribute('stroke-dashoffset', (L * (1 - tmr.left / tmr.total)).toFixed(1)); } if (tt) tt.textContent = tmrText(); } }, 1000);
  const setApp = (a) => { const e = $('#tb-app'); if (e) e.textContent = a; };
  const calHTML = (off = 0) => {
    const d = now(), base = new Date(d.getFullYear(), d.getMonth() + off, 1), y = base.getFullYear(), m = base.getMonth();
    const start = new Date(y, m, 1 - ((base.getDay() + 6) % 7)); let rows = '';
    for (let r = 0; r < 6; r++) { const w0 = new Date(start.getFullYear(), start.getMonth(), start.getDate() + r * 7); if (r === 5 && w0.getMonth() !== m) break; rows += `<span class="wk">${week(w0)}</span>`; for (let c = 0; c < 7; c++) { const x = new Date(w0.getFullYear(), w0.getMonth(), w0.getDate() + c); const today = x.toDateString() === d.toDateString(); rows += `<span class="${x.getMonth() !== m ? 'out' : ''}${today ? ' today' : ''}">${x.getDate()}</span>`; } }
    const yp = Math.round(((d - new Date(d.getFullYear(), 0, 1)) / (new Date(d.getFullYear() + 1, 0, 1) - new Date(d.getFullYear(), 0, 1))) * 100);
    return `<div class="calp" data-off="${off}"><div class="cbig">${IC('cal')}<b>${d.getDate()} ${d.toLocaleString('en-GB', { month: 'long' })}</b></div><div class="csub"><b>${hhmm()}</b> · Week ${week(d)}</div><div class="cyear"><span>${d.getFullYear()}</span><i><b style="width:${yp}%"></b></i><span>${yp}%</span></div><div class="cgrid"><span class="wk">W</span>${['M', 'T', 'W', 'T', 'F', 'S', 'S'].map(x => `<span class="hd">${x}</span>`).join('')}${rows}</div><div class="cnav"><button type="button" data-cal="-1" aria-label="Previous month">‹</button><b>${base.toLocaleString('en-GB', { month: 'long', year: 'numeric' }).toUpperCase()}</b><button type="button" data-cal="1" aria-label="Next month">›</button></div><div class="crow">${IC('cal')}<span>Calendar events</span><button type="button" class="bt">Show events</button></div><div class="crow"><button type="button" class="bt">Open Calendar</button><span class="sz">${IC('globe')}Second zone</span></div></div>`;
  };
  const switches = { hyper: true, tiling: true, topbar: true, awake: false, clip: true };
  const dropHTML = () => `<div class="pdrop"><div class="pst"><span class="dot"></span><span><b>Pilot is running</b><small>Tiling on, ${D.binds.filter(b => b[3]).length} binds on Hyper</small></span></div><div class="ph">quick switches</div><div class="qs">${[['hyper', 'capslock', 'Hyper key', 'binds on'], ['tiling', 'grid', 'Tiling', "Pilot's tiler"], ['topbar', 'menubar', 'Top bar', 'shown'], ['awake', 'coffee', 'Keep awake', 'off'], ['clip', 'clip', 'Clipboard', 'recording']].map(([k, i, n, s]) => `<button type="button" data-sw="${k}" aria-pressed="${switches[k]}">${IC(i)}<span><b>${n}</b><small>${switches[k] ? s : 'off'}</small></span><i class="tgl"></i></button>`).join('')}</div><div class="ph">now</div><div class="pnow">${IC('timer')}No timer running</div><div class="pacts">${[['apps', 'Open Pilot', '⌘ ,', ''], ['search', 'Pilot menu', '⇪ Space', 'launcher'], ['clip', 'Clipboard history', '⇪ V', 'clipboard'], ['spark', 'AI chat', '⇪ Q', 'ai'], ['bubble', 'Send feedback', '', '']].map(([i, n, k, go]) => `<button type="button" data-go="${go}">${IC(i)}<span>${n}</span>${k ? `<span class="k2 s">${k}</span>` : ''}</button>`).join('')}</div></div>`;
  let cpuNow = 9;

  /* ---------------------------------------------------------------- the menu (Hyper+Space), as Instrument draws it */
  const APPS = [['Safari', 'globe'], ['Mail', 'at'], ['Notes', 'note'], ['Music', 'music'], ['Calendar', 'cal'], ['Finder', 'folder'], ['Ghostty', 'term'], ['Zed', 'code'], ['Messages', 'bubble'], ['System Settings', 'cog'], ['Pilot', 'grid']];
  const WINS = [['Ghostty', '~/code/site — zsh', 'term'], ['Safari', 'Pilot for Mac', 'globe'], ['Zed', 'pilot.js — site', 'code']];
  const PKGS = [['Ghostty', '1.2.0 → 1.2.1'], ['Zed', '0.165.4 → 0.166.0'], ['ripgrep', '14.1.0 → 14.1.1']];
  const FILES = [['invoice-october.pdf', '~/Documents/Bills', 'PDF', 'file', '12 Oct', ''], ['Invoices 2026', '~/Documents', 'Folder', 'folder', '28 Oct', ''], ['invoice-template.docx', '~/Documents/Templates', 'Word', 'doc', '03 Sep', ''], ['Screenshot 20.41.png', '~/Desktop', 'Image', 'image', 'Today', 'Delivery details · Full name · Address · Email'], ['launch-week.md', '~/Notes', 'Markdown', 'note', 'Yesterday', ''], ['pilot-film.mp4', '~/Movies', 'Movie', 'video', '26 Oct', ''], ['receipt-lisbon.heic', '~/Pictures', 'Image', 'image', '19 Oct', 'Café · Lisboa · Total 12,40 €'], ['budget.numbers', '~/Documents', 'Numbers', 'chart', '02 Oct', '']];
  const UNITS = { km: [1000, 'm'], mi: [1609.344, 'm'], m: [1, 'm'], ft: [.3048, 'm'], kg: [1, 'kg'], lb: [.45359237, 'kg'], cm: [.01, 'm'], in: [.0254, 'm'] };
  const TZ = { tokyo: 'Asia/Tokyo', london: 'Europe/London', 'new york': 'America/New_York', lisbon: 'Europe/Lisbon', malta: 'Europe/Malta' };
  const answer = (t) => {
    if (/^[\d\s.+\-*/()]+$/.test(t) && /\d\s*[+\-*/]\s*[\d(]/.test(t)) { try { const v = Function('"use strict";return (' + t + ')')(); if (Number.isFinite(v)) return { v: String(+v.toFixed(8)), i: 'calc', k: 'sum' }; } catch (_) {} }
    let m = t.match(/^([\d.]+)\s*([a-z]+)\s+(?:in|to)\s+([a-z]+)$/i); if (m && UNITS[m[2]] && UNITS[m[3]] && UNITS[m[2]][1] === UNITS[m[3]][1]) return { v: `${(+m[1] * UNITS[m[2]][0] / UNITS[m[3]][0]).toFixed(2)} ${m[3]}`, i: 'calc', k: 'unit' };
    m = t.match(/^time in (.+)$/i); if (m && TZ[m[1].toLowerCase()]) return { v: now().toLocaleTimeString('en-GB', { timeZone: TZ[m[1].toLowerCase()], hour: '2-digit', minute: '2-digit' }) + ' in ' + m[1][0].toUpperCase() + m[1].slice(1), i: 'globe', k: 'time' };
    if (/^#[0-9a-f]{6}$/i.test(t)) return { v: t.toUpperCase(), sw: t, k: 'colour' };
    return null;
  };
  const lev = (a, b) => { const d = Array.from({ length: a.length + 1 }, (_, i) => [i]); for (let j = 1; j <= b.length; j++) d[0][j] = j; for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)); return d[a.length][b.length]; };
  const near = (name, t) => { const n = name.toLowerCase(); return n.includes(t) || n.split(/[^a-z0-9]+/).some(w => w.length >= 3 && lev(w.slice(0, t.length + 1), t) <= 1); };
  const hl = (name, q) => { if (!q) return esc(name); const i = name.toLowerCase().indexOf(q.toLowerCase()); return i < 0 ? esc(name) : esc(name.slice(0, i)) + '<u>' + esc(name.slice(i, i + q.length)) + '</u>' + esc(name.slice(i + q.length)); };
  const row = (o) => ({ hint: '', hk: false, arrow: false, icon: 'list', name: '', kind: '', right: '', ...o });
  const updState = { done: false, running: false };
  const VIEWS = {
    go: () => ({ mode: 'go', ph: 'Go…', crumb: 'pilot', hints: '↵ open&nbsp;&nbsp;⌘K actions&nbsp;&nbsp;esc close', sections: [['go to', [['apps', 'Apps', 'apps'], ['book', 'Learn', 'learn'], ['bolt', 'Trigger', 'trigger'], ['download', 'Install', 'install'], ['trash', 'Remove', 'remove'], ['refresh', 'Update', 'update'], ['spark', 'Clean', 'clean'], ['puzzle', 'Extensions', 'exts'], ['info', 'About', 'about'], ['power', 'System', 'system']].map(([i, n, go]) => row({ icon: i, name: n, go }))]] }),
    apps: () => ({ mode: 'apps', ph: 'Filter…', crumb: 'pilot › apps', hints: '↵ open&nbsp;&nbsp;esc back', filter: true, sections: [['apps', APPS.map(([n, i]) => row({ icon: i, name: n, kind: 'app', act: () => toast(`Opening ${n}`) }))]] }),
    learn: () => ({ mode: 'learn', ph: 'Filter…', crumb: 'pilot › learn', hints: '↵ run&nbsp;&nbsp;esc back', filter: true, sections: [['every bind', D.binds.filter(b => b[3] && !b[2].length).slice(0, 24).map(b => row({ hint: 'HYPER + ' + keyCap(b[1]), hk: true, arrow: true, icon: 'command', name: b[5], kind: b[6].toLowerCase() }))]] }),
    trigger: () => ({ mode: 'trigger', ph: 'Filter…', crumb: 'pilot › trigger', hints: '↵ run&nbsp;&nbsp;esc back', filter: true, sections: [['trigger', [['pipette', 'Pick a colour'], ['qr', 'Make a QR code'], ['qrscan', 'Read a QR code'], ['lock', 'Lock keyboard'], ['timer', 'Start a timer'], ['speaker', 'Read aloud']].map(([i, n]) => row({ icon: i, name: n, act: () => toast(n) }))]] }),
    install: () => ({ mode: 'install', ph: 'Search apps and Homebrew…', crumb: 'pilot › install', hints: '↵ install, asks first&nbsp;&nbsp;esc back', filter: true, sections: [['catalogue', [['globe', 'Browsers', 12], ['code', 'Editors', 14], ['term', 'Terminals', 7], ['spark', 'AI', 11], ['text', 'Fonts', 30]].map(([i, n, c]) => row({ icon: i, name: n, hint: `${c} apps`, right: '›' }))], ['homebrew', [row({ icon: 'store', name: 'Every formula and cask in Homebrew', hint: 'brew' })]]] }),
    remove: () => ({ mode: 'remove', ph: 'Filter…', crumb: 'pilot › remove', hints: '↵ shows what goes, asks first&nbsp;&nbsp;esc back', filter: true, sections: [['least used first', [['Calendar', 'cal', 'opened 41 days ago'], ['Messages', 'bubble', 'opened 12 days ago'], ['Zed', 'code', 'opened yesterday']].map(([n, i, h]) => row({ icon: i, name: n, hint: h, right: '›' }))]] }),
    exts: () => ({ mode: 'extensions', ph: 'Filter…', crumb: 'pilot › extensions', hints: '↵ open&nbsp;&nbsp;esc back', filter: true, sections: [['installed', D.exts.slice(0, 2).map(e => row({ icon: 'puzzle', name: e[2], kind: 'extension' }))], ['catalogue', D.exts.slice(2).map(e => row({ icon: 'puzzle', name: e[2], hint: 'add', right: '›' }))]] }),
    about: () => ({ mode: 'about', ph: '', crumb: 'pilot › about', hints: 'esc back', sections: [['pilot', [row({ icon: 'info', name: 'Pilot 1.0', hint: 'version' }), row({ icon: 'code', name: 'Free and open source, MIT', hint: 'licence' }), row({ icon: 'shield', name: 'No analytics, no crash reports', hint: 'privacy' })]]] }),
    system: () => ({ mode: 'system', ph: 'Filter…', crumb: 'pilot › system', hints: '↵ switch&nbsp;&nbsp;esc back', filter: true, sections: [['switches', [['moon', 'Dark mode', 'dark'], ['coffee', 'Keep awake', 'awake'], ['sun', 'Night Shift', 'night'], ['bell', 'Do not disturb', 'dnd']].map(([i, n, k]) => row({ icon: i, name: n, sw: k, right: `<i class="tgl${sysSw[k] ? ' on' : ''}"></i>`, act: () => { sysSw[k] = !sysSw[k]; } }))], ['power', [['lock', 'Lock screen'], ['moon', 'Sleep'], ['refresh', 'Restart'], ['power', 'Shut down'], ['user', 'Log out']].map(([i, n]) => row({ icon: i, name: n, hint: n === 'Shut down' || n === 'Restart' ? 'asks first' : '', act: () => toast(n + (n === 'Shut down' || n === 'Restart' ? ' asks first' : '')) }))]] }),
    update: () => ({ mode: 'update', ph: 'Filter…', crumb: 'pilot › update', hints: '↵ update, asks first&nbsp;&nbsp;esc back', filter: true, sections: [['', [row({ icon: 'download', name: updState.done ? 'Everything is up to date' : (updState.running ? 'Updating…' : 'Update all'), hint: 'package', act: () => runUpdate() }), row({ icon: 'apps', name: 'Apps', hint: 'Zed, Xcode', right: updState.done ? '<span class="ok">✓</span>' : '›' }), row({ icon: 'term', name: 'Command-line tools', hint: 'ripgrep, ruff', right: updState.done ? '<span class="ok">✓</span>' : '›' }), row({ icon: 'laptop', name: 'macOS', hint: 'macOS 27.0.2', right: updState.done ? '<span class="ok">✓</span>' : '›' }), row({ icon: 'refresh', name: 'Apps that update themselves: Off', hint: 'package' }), row({ icon: 'doc', name: 'Reports', hint: 'package', right: '›' })]]] }),
    clean: () => ({ mode: 'clean', ph: 'Filter…', crumb: 'pilot › clean', hints: '↵ on clean asks first&nbsp;&nbsp;esc back', cleanView: true, sections: [] }),
    files: () => ({ mode: 'files', ph: 'Part of a file’s name…', crumb: '', hints: '↵ open&nbsp;&nbsp;⌘K convert', files: true, sections: [] }),
  };
  const sysSw = { dark: true, awake: false, night: false, dnd: false };
  let runUpdate = () => {};
  const keyCap = (k) => ({ return: '↵', space: 'SPACE', escape: 'ESC', left: '←', right: '→', up: '↑', down: '↓', tab: '⇥', delete: '⌫' }[k] || k.toUpperCase());
  function lmenu(el, start, firstQuery = '') {
    el.innerHTML = `<div class="p-menu"><div class="lm pn"><label class="lq"><span class="lmode"></span><span class="lchev">❱</span><input type="text" autocomplete="off" spellcheck="false" aria-label="Search, as in Pilot's menu"></label><div class="lflt"></div><div class="lbody"><div class="lres" role="listbox" aria-label="Results" tabindex="0"></div><div class="lpv"></div></div><div class="lft"><span class="lchip"></span><span class="ltabs"></span><span class="lhints"></span></div></div></div>`;
    const q = $('input', el), res = $('.lres', el), ft = $('.lft', el), chip = $('.lchip', el), tabs = $('.ltabs', el), hints = $('.lhints', el), md = $('.lmode', el), flt = $('.lflt', el), pv = $('.lpv', el), box = $('.lm', el);
    const stack = [start]; let rows = [], sel = 0, kind = 'all';
    q.value = firstQuery;
    const searchView = (t) => {
      const tl = t.toLowerCase(), A = answer(t), S = [];
      const apps = APPS.filter(a => a[0].toLowerCase().includes(tl)).map(([n, i]) => row({ icon: i, name: n, kind: 'app', k: 'apps', act: () => toast(`Opening ${n}`) }));
      const acts = D.feats.filter(f => f[0].toLowerCase().includes(tl)).slice(0, 5).map(f => row({ hint: f[3] ? f[3].replace('Hyper+', 'HYPER + ').toUpperCase() : 'action', hk: !!f[3], arrow: !!f[3], icon: f[1], name: f[0], k: 'actions' }));
      const wins = WINS.filter(w => (w[0] + ' ' + w[1]).toLowerCase().includes(tl)).map(([a, t2, i]) => row({ hint: 'window', icon: i, name: t2, kind: a, k: 'windows' }));
      const files = FILES.filter(f => near(f[0], tl)).slice(0, 3).map(f => row({ hint: f[4], icon: f[3], name: f[0], kind: f[1], k: 'files' }));
      const pkgs = PKGS.filter(p => p[0].toLowerCase().includes(tl)).map(([n, v]) => row({ hint: v, icon: 'store', name: n, k: 'packages' }));
      const best = A ? row({ hint: A.k, icon: A.i || 'pipette', sw: A.sw, name: A.v, big: true, act: () => toast('Copied ' + A.v) }) : (apps[0] ? { ...apps[0], hint: 'best', right: '<span class="dotr"></span>' } : (acts[0] || wins[0] || files[0]));
      if (best) S.push(['best match', [best]]);
      S.push(['ask or search', [row({ hint: 'ai', icon: 'spark', name: 'Ask AI', kind: `“${t}”`, right: '›', act: () => show('ai') }), row({ hint: 'web', icon: 'globe', name: 'Search the web', kind: `“${t}”`, right: '›', act: () => toast('Searching the web') }), row({ hint: 'files', icon: 'search', name: `Search files for "${t}"`, right: '›', act: () => show('files') })]]);
      const pools = { apps, windows: wins, files, actions: acts, packages: pkgs };
      const counts = Object.fromEntries(Object.entries(pools).map(([k, v]) => [k, v.length]));
      if (kind === 'all') { if (apps.length > (best === apps[0] ? 1 : 0)) S.push(['apps', apps.filter(a => a !== apps[0] || !best || best.k !== 'apps')]); if (acts.length) S.push(['actions', acts]); if (pkgs.length) S.push(['install', pkgs]); if (wins.length || files.length) S.push(['windows and files', [...wins, ...files]]); }
      else S.splice(0, S.length, ...(A ? [['best match', [best]]] : []), [kind, pools[kind]]);
      return { mode: '', ph: 'Search…', search: true, counts, hints: '⇥ kind&nbsp;&nbsp;↵ open&nbsp;&nbsp;⌘K actions', sections: S };
    };
    const render = () => {
      const top = stack[stack.length - 1], t = q.value.trim();
      const v = top === 'go' && t ? searchView(t) : VIEWS[top]();
      box.dataset.view = top; md.textContent = v.mode && v.mode !== 'go' ? v.mode : ''; q.placeholder = v.ph;
      chip.textContent = (v.search ? 'search' : v.mode || 'go').toUpperCase();
      if (v.search) { const c = v.counts, all = Object.values(c).reduce((a, b) => a + b, 0); tabs.innerHTML = [['all', all], ...Object.entries(c)].map(([k, n]) => `<button type="button" data-kind="${k}" class="${k === kind ? 'on' : ''}">${k} ${n || ''}</button>`).join(''); }
      else tabs.innerHTML = `<span class="crumb2">${v.crumb}</span>`;
      hints.innerHTML = v.hints;
      flt.hidden = !v.files; pv.hidden = !v.files; box.classList.toggle('split', !!v.files);
      let h = ''; rows = [];
      if (v.files) {
        flt.innerHTML = ['Kind: Any ⌘1', 'Where: Home ⌘2', 'When: Any time ⌘3', 'Hidden files ⌘.'].map((l, i) => `<button type="button" aria-pressed="${i === 0}">${IC(['file', 'folder', 'cal', 'eyeoff'][i])}${l}</button>`).join('');
        const tl = t.toLowerCase(), byName = tl ? FILES.filter(f => near(f[0], tl)) : FILES.slice(0, 5), byText = tl ? FILES.filter(f => f[5] && f[5].toLowerCase().includes(tl) && !byName.includes(f)) : [];
        const fr = (f) => row({ hint: f[4], icon: f[3], name: f[0], kind: f[1], file: f, act: () => toast(`Opening ${f[0]}`) });
        v.sections = []; if (byName.length) v.sections.push([tl ? 'best match' : 'recent', byName.map(fr)]); if (byText.length) v.sections.push(['words inside pictures', byText.map(fr)]);
        tabs.innerHTML = `<span class="crumb2">files ${byName.length + byText.length}</span><span class="crumb2 dim">Pilot’s own index of your home folder, not Spotlight</span>`;
      }
      if (v.cleanView) { h = cleanHTML(); }
      const fq = v.filter ? t.toLowerCase() : '';
      v.sections.forEach(([head, rs]) => {
        const list = rs.filter(r => r && (!fq || r.name.toLowerCase().includes(fq)));
        if (!list.length) return;
        if (head) h += `<div class="lh">${head}</div>`;
        list.forEach(r => { const i = rows.length; rows.push(r); h += `<div class="lr${r.big ? ' big' : ''}" role="option" data-i="${i}"><span class="lhint${r.hk ? ' k' : ''}">${esc(r.hint)}</span><span class="larr">${r.arrow ? '→' : ''}</span>${r.sw ? `<span class="lsw" style="background:${r.sw}"></span>` : IC(r.icon)}<span class="lname"><b>${hl(r.name, v.search || v.files ? t : fq)}</b>${r.kind ? `<em>${esc(r.kind)}</em>` : ''}</span><span class="lright">${r.right}</span></div>`; });
      });
      res.innerHTML = h || (v.cleanView ? h : `<div class="lempty">Nothing by that name. Press ⇥ to try another kind, or ↵ to ask AI.</div>`);
      if (v.cleanView) wireClean();
      box.classList.toggle('nohint', rows.length > 0 && rows.every(r => !r.hint && !r.arrow));
      sel = Math.min(sel, Math.max(0, rows.length - 1)); mark();
    };
    const mark = () => { $$('.lr', res).forEach(r => r.classList.toggle('sel', +r.dataset.i === sel)); const s = $('.lr.sel', res); if (s) s.scrollIntoView({ block: 'nearest' }); const r = rows[sel]; if (r && r.file && !pv.hidden) { const f = r.file, t = q.value.trim(); const words = f[5] && t ? esc(f[5]).replace(new RegExp(t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'ig'), m => `<mark>${m}</mark>`) : ''; pv.innerHTML = `<div class="th">${IC(f[3])}</div><b>${esc(f[0])}</b><small>${esc(f[1])} · ${f[2]} · ${f[4]}</small>${words ? `<small>Text in the image: ${words}</small>` : ''}`; } };
    const act = () => { const r = rows[sel]; if (!r) return; if (r.go) { stack.push(r.go); q.value = ''; sel = 0; render(); q.focus(); return; } if (r.act) { r.act(); render(); } };
    const back = () => { if (q.value) { q.value = ''; sel = 0; render(); return; } if (stack.length > 1) { stack.pop(); sel = 0; render(); } };
    q.addEventListener('input', () => { sel = 0; render(); });
    q.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(rows.length - 1, sel + 1); mark(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); mark(); }
      else if (e.key === 'Enter') { e.preventDefault(); act(); }
      else if (e.key === 'Escape') { e.preventDefault(); back(); }
      else if (e.key === 'Tab' && stack[stack.length - 1] === 'go' && q.value.trim()) { e.preventDefault(); const ks = ['all', 'apps', 'windows', 'files', 'actions', 'packages']; kind = ks[(ks.indexOf(kind) + (e.shiftKey ? ks.length - 1 : 1)) % ks.length]; sel = 0; render(); }
    });
    res.addEventListener('click', (e) => { const r = e.target.closest('.lr'); if (r) { sel = +r.dataset.i; mark(); act(); } });
    tabs.addEventListener('click', (e) => { const b = e.target.closest('[data-kind]'); if (b) { kind = b.dataset.kind; sel = 0; render(); q.focus(); } });
    flt.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) $$('button', flt).forEach(x => x.setAttribute('aria-pressed', x === b)); });
    runUpdate = () => { if (updState.running || updState.done) return; updState.running = true; render(); setTimeout(() => { updState.running = false; updState.done = true; render(); toast('Updated 5 packages; kept in Reports'); }, reduced ? 0 : 1600); };
    let cleanStep = 0;
    const CL = [['globe', 'Browser caches', 1.8], ['code', 'Developer tools', 3.1], ['list', 'Logs', .4], ['trash', 'Trash', .9], ['bubble', 'Message apps', .6], ['film', 'Media apps', .3], ['cog', 'System caches', .7], ['apps', 'App leftovers', .2]];
    const total = CL.reduce((a, c) => a + c[2], 0).toFixed(1);
    const cleanHTML = () => cleanStep === 0 ? `<div class="lstep"><span class="spin"></span><span><b>Mole is previewing what it would remove</b><small>Mole is starting its preview, which takes a minute or two; it keeps going if you close the menu.</small></span></div><div class="lstep">${IC('search')}<span><b>Mole previews</b><small>mo clean --dry-run reads every cache, log and leftover; nothing is removed</small></span><em class="k">now</em></div><div class="lstep">${IC('list')}<span><b>You read the list</b><small>each line under its section with its size, the total on top</small></span><em>next</em></div><div class="lstep">${IC('spark')}<span><b>Clean asks first</b><small>↵ on Clean, then a confirm; mo clean removes what the list showed</small></span><em>next</em></div>`
      : cleanStep === 1 ? `<div class="lh">mole previewed ${total} gb</div>${CL.map(([i, n, g]) => `<div class="lr static"><span class="lhint">${g.toFixed(1)} GB</span><span class="larr"></span>${IC(i)}<span class="lname"><b>${n}</b></span><span class="lright"></span></div>`).join('')}<button type="button" class="lr cleanbtn"><span class="lhint k">↵</span><span class="larr"></span>${IC('spark')}<span class="lname"><b>Clean ${total} GB</b><em>asks first</em></span><span class="lright"></span></button>`
      : cleanStep === 2 ? `<div class="lask"><b>Clean ${total} GB?</b><span>Mole removes only what the list showed. Nothing goes until you confirm.</span><div><button type="button" class="bt" data-c="no">Cancel</button><button type="button" class="bt ink" data-c="yes">Clean</button></div></div>`
      : `<div class="lask"><b><span class="ok">✓</span> Freed ${total} GB</b><span>Kept in Reports with what ran and its output.</span></div>`;
    const wireClean = () => { if (cleanStep === 0) setTimeout(() => { if (box.dataset.view === 'clean' && cleanStep === 0) { cleanStep = 1; render(); } }, reduced ? 0 : 1400); $('.cleanbtn', res)?.addEventListener('click', () => { cleanStep = 2; render(); }); $$('[data-c]', res).forEach(b => b.addEventListener('click', () => { cleanStep = b.dataset.c === 'yes' ? 3 : 1; render(); })); };
    render();
    return { focus: () => q.focus() };
  }
  P.launcher = { app: 'Pilot', try: 'Type <b>ghost</b>, <b>12*7</b>, <b>5 km in mi</b> or <b>#C6F432</b>; press ⇥ for kinds, open <b>Update</b> or <b>System</b>', render(el) { lmenu(el, 'go'); } };
  P.files = { app: 'Pilot', try: 'Type with a typo: <b>invoce</b>; or words inside a picture: <b>delivery</b>', render(el) { lmenu(el, 'files', 'invoce'); } };
  P.update = { app: 'Pilot', try: '<b>Update all</b>, then <b>esc</b> back and open <b>Clean</b>: it previews, then asks first', render(el) { const m = lmenu(el, 'go'); const inp = $('input', el); inp.value = ''; /* start inside Update */ $$('.lr', el).find(r => r.textContent.includes('Update'))?.click(); } };

  /* ---------------------------------------------------------------- Binds: Pilot default on the real board */
  const GROUP_FILL = { Apps: 'var(--g-apps)', Windows: 'var(--g-win)', Workspaces: 'var(--g-ws)', Captures: 'var(--g-cap)', System: 'var(--g-sys)', Pilot: 'var(--g-pilot)' };
  const LAYERS = [['Hyper', []], ['Shift', ['shift']], ['Ctrl', ['ctrl']], ['Alt', ['alt']]];
  const HKEYS = [['Caps Lock', '⇪', 'caps', 'Suggested. A tap alone sends Escape, and Shift+Caps Lock still types capitals; it is Caps Lock again when Pilot quits.'], ['Left Control', '⌃', 'lctrl', 'Left Control is Hyper by itself; Control shortcuts need right Control, which a MacBook keyboard lacks.'], ['Right Control', '⌃', 'rctrl', 'Right Control is Hyper by itself; left Control stays normal.'], ['Left Option', '⌥', 'lopt', 'Left Option is Hyper by itself; right Option still types accents and Option shortcuts.'], ['Right Option', '⌥', 'ropt', 'Right Option is Hyper by itself; left Option stays normal.'], ['Left Command', '⌘', 'lcmd', 'Left Command is Hyper by itself; Cmd+C, Cmd+V and Cmd+Tab then need right Command.'], ['Right Command', '⌘', 'rcmd', 'Right Command is Hyper by itself; left Command stays normal, so Cmd+C still copies.']];
  const BOARD = [
    ['escape', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
    ['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', ['delete', 6]],
    [['tab', 6], 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\\'],
    [['caps', 7], 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", ['return', 7]],
    [['shift', 9], 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', ['rshift', 9]],
    ['fn', 'lctrl', 'lopt', ['lcmd', 5], ['space', 16], ['rcmd', 5], 'ropt', 'rctrl', 'ARROWS'],
  ];
  const CAP = { escape: 'esc', delete: 'delete', tab: 'tab', caps: 'caps', return: 'return', shift: 'shift', rshift: 'shift', fn: 'fn', lctrl: 'ctrl', rctrl: 'ctrl', lopt: 'opt', ropt: 'opt', lcmd: 'cmd', rcmd: 'cmd', space: 'space' };
  P.keys = { app: 'Pilot', try: 'Pick your Hyper key, hold it for the overlay, click a key on <b>Binds</b> then <b>Change key</b>, and try <b>Mouse</b>', render(el) {
    const st = { hyper: new Set(['caps']), layer: 0, sel: 'space', moving: false, binds: D.binds.map(b => [...b]), view: 0 };
    const layerBinds = () => st.binds.filter(b => b[3] && JSON.stringify(b[2]) === JSON.stringify(LAYERS[st.layer][1]));
    const bindOn = (k) => layerBinds().find(b => b[1] === k);
    const counts = () => LAYERS.map(([, m]) => st.binds.filter(b => b[3] && JSON.stringify(b[2]) === JSON.stringify(m)).length);
    const keyHTML = (spec) => {
      if (spec === 'ARROWS') return `<div class="arw">${[['up', '▲'], ['left', '◀'], ['down', '▼'], ['right', '▶']].map(([k, g]) => { const b = bindOn(k); return `<button type="button" class="bk ${k}${b ? ' on' : ''}${st.sel === k ? ' sel' : ''}" data-k="${k}" style="${b ? '--f:' + GROUP_FILL[b[6]] : ''}" aria-label="${k}${b ? ': ' + b[5] : ''}">${g}</button>`; }).join('')}</div>`;
      const [k, w] = Array.isArray(spec) ? spec : [spec, 4];
      const isH = st.layer >= 0 && st.hyper.has(k), b = bindOn(k), cap = CAP[k] || k.toUpperCase();
      if (isH) return `<button type="button" class="bk hyp" style="--w:${w}" data-hold aria-label="${cap} Hyper, hold for the overlay"><span>${cap}</span> <small>Hyper</small></button>`;
      if (!b) return `<button type="button" class="bk${st.moving ? ' free' : ''}" style="--w:${w}" data-k="${k}" aria-label="${cap}, free"><span>${cap}</span><small></small></button>`;
      return `<button type="button" class="bk on${st.sel === k ? ' sel' : ''}" style="--w:${w};--f:${GROUP_FILL[b[6]]}" data-k="${k}" aria-label="${cap}: ${b[5]}"><span>${cap}</span><small>${esc(b[4])}</small></button>`;
    };
    const legend = () => { const c = {}; layerBinds().forEach(b => { c[b[6]] = (c[b[6]] || 0) + 1; }); return `<div class="blg"><span class="all">All ${layerBinds().length}</span>${Object.keys(GROUP_FILL).filter(g => c[g]).map(g => `<span><i style="background:${GROUP_FILL[g]}"></i>${g} ${c[g]}</span>`).join('')}<span class="hint3">Hold <span class="k2 s">${HKEYS.find(h => st.hyper.has(h[2]))[1]}</span> for the overlay</span></div>`; };
    const detail = () => { const b = layerBinds().find(x => x[1] === st.sel); if (!b) return `<div class="bdet2 pn"><span class="ico">${IC('command')}</span><div><b>${st.moving ? 'Press a free key on the board' : 'A free key'}</b><small>${st.moving ? 'The bind moves there; esc cancels.' : 'Click it in Pilot to give it a job.'}</small></div></div>`; const mods = b[2].map(m => m[0].toUpperCase() + m.slice(1)).join(' + '); return `<div class="bdet2 pn"><span class="ico" style="background:${GROUP_FILL[b[6]]};color:#F2F2F2;border-color:transparent">${IC('command')}</span><div><b>${esc(b[5])}</b><small>${b[6]} · Pilot default · <code>${b[0]}</code></small></div><span class="kk"><span class="k2">⇪ Hyper</span>${mods ? `<span class="k2">${mods}</span>` : ''}<span class="k2">${keyCap(b[1])}</span></span><span class="acts"><button type="button" class="bt${st.moving ? ' on' : ''}" data-move>${st.moving ? 'Press a key…' : 'Change key'}</button><button type="button" class="bt" data-unbind>Unbind</button></span></div>`; };
    const list = () => `<div class="card2 blist"><div class="trow th" style="grid-template-columns:120px minmax(0,1fr) minmax(0,1fr)"><span>Trigger</span><span>Action</span><span>Route</span></div>${layerBinds().slice().sort((a, b) => a[6].localeCompare(b[6])).slice(0, 14).map(b => `<button type="button" class="trow${b[1] === st.sel ? ' on' : ''}" data-k="${b[1]}" style="grid-template-columns:120px minmax(0,1fr) minmax(0,1fr)"><span class="kk"><span class="k2 s">⇪</span>${b[2].map(m => `<span class="k2 s">${m[0].toUpperCase() + m.slice(1)}</span>`).join('')}<span class="k2 s">${keyCap(b[1])}</span></span><span><i class="gd" style="background:${GROUP_FILL[b[6]]}"></i>${esc(b[5])}</span><code>${b[0]}</code></button>`).join('')}</div>`;
    const board = () => `<div class="bboard">${BOARD.map(r => `<div class="kr">${r.map(keyHTML).join('')}</div>`).join('')}</div>${legend()}${detail()}${list()}`;
    const hyperView = () => { const names = HKEYS.filter(h => st.hyper.has(h[2])).map(h => h[0]); const g = HKEYS.find(h => st.hyper.has(h[2]))[1]; return `<div class="hpick"><p class="hline">Pick your <span class="kc2"><i>${g}</i><b>hyper</b></span> key. <span>Hold it. The whole Mac answers.</span></p><div class="card2 hlist" role="group" aria-label="Hyper keys"><div class="hh"><b>Hyper key</b><span>${names.join(', ')}</span></div>${HKEYS.map(([n, gl, id, note]) => `<button type="button" class="hrow" role="checkbox" aria-checked="${st.hyper.has(id)}" data-h="${id}"><span class="rad"></span><span><b>${n}</b><small>${note}</small></span><span class="k2">${gl}</span></button>`).join('')}</div><div class="bfoot"><span>Pick one or more. Then hold it: every key under it does what you set.</span><button type="button" class="bt hold2" data-hold>Hold <span class="k2 s">${g}</span> for the overlay</button></div></div>`; };
    const MB = [['Mouse 3', 'Middle'], ['Mouse 4', 'Back'], ['Mouse 5', 'Forward'], ['Mouse Scroll Up', 'Wheel']];
    const mouse = () => { const cur = MB[st.mb || 0]; const plain = D.mouse.find(m => m[0] === cur[0] && !m[1]), hy = D.mouse.find(m => m[0] === cur[0] && m[1]); const scroll = cur[0].includes('Scroll'); return `<div class="mouse2"><svg class="m" viewBox="0 0 120 190" aria-label="A mouse; click a button"><path class="body" d="M60 6c30 0 50 22 50 60v58c0 34-22 60-50 60S10 158 10 124V66C10 28 30 6 60 6z"/><path class="bn${st.mb === 0 || !st.mb ? ' on' : ''}" data-mb="0" d="M54 22h12a4 4 0 0 1 4 4v26a4 4 0 0 1-4 4H54a4 4 0 0 1-4-4V26a4 4 0 0 1 4-4z"/><path class="bn${st.mb === 1 ? ' on' : ''}" data-mb="1" d="M8 92h8a3 3 0 0 1 3 3v22a3 3 0 0 1-3 3H8z"/><path class="bn${st.mb === 2 ? ' on' : ''}" data-mb="2" d="M8 64h8a3 3 0 0 1 3 3v20a3 3 0 0 1-3 3H8z"/><path class="bn${st.mb === 3 ? ' on' : ''}" data-mb="3" d="M57 60h6v14h-6z"/></svg><div><div class="ph">${cur[1]} ${scroll ? '' : 'button'} · ${cur[0]}</div><p class="lead">Pilot default for this button. Click another on the drawing; Hyper gives each a second action.</p><div class="card2">${scroll ? '' : `<div class="trow" style="grid-template-columns:110px 1fr"><span class="k2 s">Click</span><span>${plain ? esc(plain[3]) : 'Its usual job'}</span></div>`}<div class="trow" style="grid-template-columns:110px 1fr"><span class="kk"><span class="k2 s">⇪</span><span class="k2 s">${scroll ? 'Wheel' : 'Click'}</span></span><span>${hy ? esc(hy[3]) + (scroll ? '; down: Volume down' : '') : 'Free'}</span></div></div></div></div>`; };
    const SK = ['Caps Lock', 'Left Control', 'Right Control', 'Left Option', 'Right Option', 'Left Command', 'Right Command', 'Escape', 'Tab', 'Return', 'Delete', 'F1', 'F2', 'F13'];
    const swap = () => `<div class="swap"><p class="lead">Two keys swapped at the hardware level while Pilot runs: each types the other.</p><div class="add"><select aria-label="First key">${SK.map((k, i) => `<option${i === 7 ? ' selected' : ''}>${k}</option>`).join('')}</select><span>⇄</span><select aria-label="Second key">${SK.map((k, i) => `<option${i === 0 ? ' selected' : ''}>${k}</option>`).join('')}</select><button type="button" class="bt ink" data-addswap>Swap them</button></div><div class="card2"><div class="chd">${IC('swap')}Swapped keys<small class="cnt2">${(st.swaps || []).length ? (st.swaps.length + ' swapped') : 'none yet'}</small></div>${(st.swaps || []).map(([a, b]) => `<div class="trow" style="grid-template-columns:auto auto auto 1fr"><span class="k2">${a}</span>⇄<span class="k2">${b}</span><small>each types the other</small></div>`).join('')}</div></div>`;
    const overlay = () => { const groups = {}; layerBinds().forEach(b => { (groups[b[6]] = groups[b[6]] || []).push(b); }); const order = ['Apps', 'Windows', 'Workspaces', 'Captures', 'System', 'Pilot'].filter(g => groups[g]); const g = HKEYS.find(h => st.hyper.has(h[2]))[1]; return `<div class="ovl3 pn" aria-hidden="true"><div class="hd"><span class="kk2">${g}</span>Hyper<small>Add Shift or Ctrl for more</small></div><div class="cols">${order.map(gr => `<div class="col"><div class="ph">${gr}</div>${groups[gr].slice(0, gr === 'Workspaces' ? 3 : 5).map(b => `<div class="it"><span class="k2">${keyCap(b[1])}</span>${esc(b[5])}</div>`).join('')}</div>`).join('')}</div></div>`; };
    const views = [['Hyper key', 'Picked in setup'], ['Binds', 'Keyboard, layer by layer'], ['Mouse', 'Buttons and Hyper + mouse'], ['Swap keys', 'Two keys trade places']];
    const draw = () => {
      const v = st.view, c = counts();
      const tabs = v === 1 ? `<span class="sg" role="group">${LAYERS.map(([n], i) => `<button type="button" data-layer="${i}" aria-pressed="${i === st.layer}">${n} <em>${c[i]}</em></button>`).join('')}</span>` : '';
      el.innerHTML = win('Keys', views, v, views[v][0], tabs, [hyperView, board, mouse, swap][v](), v === 1 ? '<span class="bt">Preset · Pilot default</span>' : '') + overlay();
      $$('.si', el).forEach(b => b.addEventListener('click', () => { st.view = +b.dataset.side; st.moving = false; draw(); }));
      $$('[data-hold]', el).forEach(h => holdable(h, () => el.classList.add('held'), () => el.classList.remove('held')));
      $$('[data-h]', el).forEach(b => b.addEventListener('click', () => { const id = b.dataset.h; if (st.hyper.has(id) && st.hyper.size === 1) return; st.hyper.has(id) ? st.hyper.delete(id) : st.hyper.add(id); draw(); $(`[data-h="${id}"]`, el)?.focus(); }));
      $$('[data-layer]', el).forEach(b => b.addEventListener('click', () => { st.layer = +b.dataset.layer; st.sel = (layerBinds()[0] || [])[1]; draw(); }));
      $$('.bboard [data-k], .blist [data-k]', el).forEach(b => b.addEventListener('click', () => {
        const k = b.dataset.k;
        if (st.moving) { const cur = layerBinds().find(x => x[1] === st.sel); if (cur && !bindOn(k)) { cur[1] = k; st.sel = k; toast(`${cur[5]} moved to Hyper + ${keyCap(k)}`); } st.moving = false; draw(); return; }
        st.sel = k; draw();
      }));
      $('[data-move]', el)?.addEventListener('click', () => { st.moving = !st.moving; draw(); });
      $('[data-unbind]', el)?.addEventListener('click', () => { const i = st.binds.findIndex(x => x[3] && x[1] === st.sel && JSON.stringify(x[2]) === JSON.stringify(LAYERS[st.layer][1])); if (i >= 0) { toast(`${st.binds[i][5]} unbound`); st.binds.splice(i, 1); } draw(); });
      $$('.bn', el).forEach(b => b.addEventListener('click', () => { st.mb = +b.dataset.mb; draw(); }));
      $('[data-addswap]', el)?.addEventListener('click', () => { const [a, b] = $$('select', el).map(s => s.value); st.swaps = st.swaps || []; if (a !== b && !st.swaps.some(p => p.includes(a) || p.includes(b))) st.swaps.push([a, b]); draw(); });
    };
    draw();
  } };

  /* ---------------------------------------------------------------- Clipboard: the real panel */
  const CLIP = [
    { t: 'Pilot makes a Mac feel as close to Omarchy as macOS allows.', k: 'text', from: 'Notes', at: '19:45', pin: 1, tag: '#pilot' },
    { t: '#FF6B2C', k: 'colour', from: 'Pilot', at: '19:44', pin: 1, tag: '' },
    { t: 'Image', k: 'image', from: 'Pilot', at: '19:51', pin: 0, tag: '#pilot', dim: '1440 × 900' },
    { t: 'open -g "pilot://run?action=workspaces.go:2"', k: 'text', from: 'Ghostty', at: '19:48', pin: 0, tag: '#pilot' },
    { t: 'https://github.com/banozz0/pilot', k: 'link', from: 'Safari', at: '19:46', pin: 0, tag: '', title: 'banozz0/pilot: one key for the whole Mac' },
    { t: 'someone@example.com', k: 'email', from: 'Mail', at: '19:42', pin: 0, tag: '' },
    { t: 'invoice-october.pdf', k: 'file', from: 'Finder', at: '19:40', pin: 0, tag: '', dim: '212 KB' },
  ];
  const CKI = { text: 'text', image: 'image', colour: 'pipette', link: 'link', file: 'file', email: 'at' };
  const hexRgb = (h) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const rgbHsl = ([r, g, b]) => { r /= 255; g /= 255; b /= 255; const mx = Math.max(r, g, b), mn = Math.min(r, g, b); let h = 0, s = 0; const l = (mx + mn) / 2; if (mx !== mn) { const d = mx - mn; s = l > .5 ? d / (2 - mx - mn) : d / (mx + mn); h = mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4; h *= 60; } return [Math.round(h), Math.round(s * 100), Math.round(l * 100)]; };
  P.clipboard = { app: 'Pilot', try: '↑ ↓ to move, <b>↵</b> to paste, <b>⌘K</b> for actions (try Format: Uppercase), click a kind or a tag', render(el) {
    const KINDS = [['all', 'All'], ['text', 'Text'], ['image', 'Image'], ['file', 'File'], ['link', 'Link'], ['colour', 'Colour'], ['email', 'Email'], ['pinned', 'Pinned']];
    const items = CLIP.map(c => ({ ...c }));
    let kind = 'all', sel = 0, shown = [], actions = false, aSel = 0;
    el.innerHTML = `<div class="p-clip"><div class="cb pn"><label class="q">${IC('clip')}<input type="text" placeholder="Search clipboard…" aria-label="Search clipboard"><small class="cc"></small></label><div class="fl" role="group" aria-label="Kind">${KINDS.map(([k, l], i) => `<button type="button" data-k="${k}" aria-pressed="${i === 0}">${l}</button>`).join('')}<span class="sep"></span><button type="button" data-k="#pilot" aria-pressed="false">#pilot</button><span class="sort">Last copy ↓ <span class="k2 s">⌘</span><span class="k2 s">S</span></span></div><div class="bd"><div class="ls"></div><div class="pvw"></div></div><div class="ft"><span class="crumb">${IC('apps')}Clipboard › <span class="ck">All</span></span><span class="fk"></span></div></div></div>`;
    const ls = $('.ls', el), pw = $('.pvw', el), q = $('input', el), fk = $('.fk', el);
    const ACTS = (c) => c.k === 'colour' ? [['Paste as HEX', '↵'], ['Paste as rgb()', ''], ['Paste as hsl()', ''], [c.pin ? 'Unpin' : 'Pin', '⌘ P'], ['Delete', '⌘ ⌫']] : c.k === 'text' ? [['Paste and delete', '⌥ ↵'], ['Rename…', ''], ['Edit text…', ''], [c.pin ? 'Unpin' : 'Pin', '⌘ P'], ['Format: Lowercase', ''], ['Format: Uppercase', ''], ['Format: Capitalise words', ''], ['Format: Remove empty lines', ''], ['Delete', '⌘ ⌫']] : [['Paste', '↵'], ['Open', '⌘ O'], [c.pin ? 'Unpin' : 'Pin', '⌘ P'], ['Delete', '⌘ ⌫']];
    const detail = () => {
      $$('.it', ls).forEach(b => b.classList.toggle('sel', +b.dataset.i === sel));
      const c = shown[sel];
      fk.innerHTML = actions ? `<span>Run <span class="k2 s">↵</span></span><span>Choose <span class="k2 s">↑</span><span class="k2 s">↓</span></span><span>Back to the list <span class="k2 s">esc</span></span>` : `<span><b>Paste</b> <span class="k2 s">↵</span></span><span>Pick a run <span class="k2 s">⇧</span><span class="k2 s">↑</span><span class="k2 s">↓</span></span><span>Actions <span class="k2 s">⌘</span><span class="k2 s">K</span></span><span class="opt">All keys <span class="k2 s">⌘</span><span class="k2 s">/</span></span>`;
      if (!c) { pw.innerHTML = ''; return; }
      if (actions) { const A = ACTS(c); aSel = Math.min(aSel, A.length - 1); pw.innerHTML = `<div class="ph">1 item</div><div class="acl">${A.map(([n, k], i) => `<button type="button" class="ac${i === aSel ? ' sel' : ''}" data-a="${i}"><span>${n}</span>${k ? `<span class="k2 s">${k}</span>` : ''}</button>`).join('')}</div>`; return; }
      let box = `<div class="box">${esc(c.t)}</div><span class="chars">${c.t.length} characters</span>`;
      if (c.k === 'colour') { const rgb = hexRgb(c.t), hsl = rgbHsl(rgb); box = `<div class="cswatch" style="background:${c.t}"><b>${c.t}</b><span>rgb(${rgb.join(', ')})</span></div><div class="tints">${[90, 70, 50, 0, -25, -45, -65].map(p => `<i style="background:color-mix(in srgb, ${c.t} ${100 - Math.abs(p)}%, ${p > 0 ? '#fff' : '#000'})"></i>`).join('')}</div><dl class="cvals"><dt>HEX</dt><dd>${c.t}</dd><dt>RGB</dt><dd>rgb(${rgb.join(', ')})</dd><dt>HSL</dt><dd>hsl(${hsl[0]}, ${hsl[1]}%, ${hsl[2]}%)</dd></dl>`; }
      else if (c.k === 'image') box = `<div class="box img"><span>${c.dim}</span></div><span class="chars">${c.dim} · PNG</span>`;
      else if (c.k === 'link') box = `<div class="box lnk"><b>${esc(c.title)}</b><span>${esc(c.t)}</span></div><span class="chars">github.com</span>`;
      pw.innerHTML = `<b>${esc(c.k === 'image' ? 'Image' : c.t)}</b><dl class="meta"><dt>From</dt><dd>${c.from}</dd><dt>Kind</dt><dd>${c.k[0].toUpperCase() + c.k.slice(1)}</dd><dt>Copied</dt><dd class="mono">${c.at}</dd></dl>${box}`;
    };
    const render = () => {
      const t = q.value.trim().toLowerCase();
      shown = items.filter(c => (kind === 'all' || (kind === 'pinned' ? c.pin : kind[0] === '#' ? c.tag === kind : c.k === kind)) && (!t || c.t.toLowerCase().includes(t)));
      if (sel >= shown.length) sel = 0;
      const r = (c) => { const i = shown.indexOf(c); const th = c.k === 'colour' ? `<span class="ico" style="background:${c.t};border-color:transparent"></span>` : `<span class="ico">${IC(CKI[c.k])}</span>`; return `<button type="button" class="it" data-i="${i}">${th}<span>${esc(c.k === 'image' ? 'Image' : c.t)}</span><span class="tg">${c.tag}</span><span class="kd">${c.k[0].toUpperCase() + c.k.slice(1)}</span><span class="tm">${c.at}</span></button>`; };
      const pinned = shown.filter(c => c.pin), rest = shown.filter(c => !c.pin);
      ls.innerHTML = (pinned.length ? `<div class="ph">Pinned</div>${pinned.map(r).join('')}` : '') + (rest.length ? `<div class="ph">Recent</div>${rest.map(r).join('')}` : '') || `<div class="ph">Nothing copied by that name</div>`;
      $('.cc', el).textContent = `${items.length} copies`; $('.ck', el).textContent = KINDS.find(k => k[0] === kind)?.[1] || kind; detail();
    };
    const runAction = () => {
      const c = shown[sel], A = ACTS(c), [n] = A[aSel];
      if (n.startsWith('Format: ')) { const f = n.slice(8); c.t = f === 'Lowercase' ? c.t.toLowerCase() : f === 'Uppercase' ? c.t.toUpperCase() : f === 'Capitalise words' ? c.t.replace(/\b\w/g, m => m.toUpperCase()) : c.t.replace(/\n\s*\n/g, '\n'); toast(n.replace('Format: ', '') + ' done'); }
      else if (n === 'Pin' || n === 'Unpin') { c.pin = !c.pin; toast(n === 'Pin' ? 'Pinned' : 'Unpinned'); }
      else if (n.startsWith('Delete') || n.startsWith('Paste and delete')) { items.splice(items.indexOf(c), 1); toast(n.startsWith('Paste') ? 'Pasted into Notes and deleted' : 'Deleted'); sel = 0; }
      else toast(n.startsWith('Paste') ? `Pasted into Notes` : n.replace('…', '') + '…');
      actions = false; render(); q.focus();
    };
    ls.addEventListener('click', (e) => { const b = e.target.closest('.it'); if (b) { if (+b.dataset.i === sel && !actions) toast('Pasted into Notes'); sel = +b.dataset.i; actions = false; detail(); } });
    pw.addEventListener('click', (e) => { const a = e.target.closest('.ac'); if (a) { aSel = +a.dataset.a; runAction(); } });
    $$('.fl [data-k]', el).forEach(b => b.addEventListener('click', () => { kind = b.dataset.k; sel = 0; actions = false; $$('.fl [data-k]', el).forEach(x => x.setAttribute('aria-pressed', x === b)); render(); }));
    q.addEventListener('input', () => { sel = 0; actions = false; render(); });
    q.addEventListener('keydown', (e) => {
      const n = actions ? ACTS(shown[sel] || {}).length : shown.length;
      if (e.key === 'ArrowDown') { e.preventDefault(); actions ? aSel = Math.min(n - 1, aSel + 1) : sel = Math.min(n - 1, sel + 1); detail(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); actions ? aSel = Math.max(0, aSel - 1) : sel = Math.max(0, sel - 1); detail(); }
      else if (e.key === 'Enter') { e.preventDefault(); if (actions) runAction(); else if (shown[sel]) toast('Pasted into Notes'); }
      else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); if (shown[sel]) { actions = !actions; aSel = 0; detail(); } }
      else if (e.key === 'Escape') { e.preventDefault(); if (actions) { actions = false; detail(); } else { q.value = ''; render(); } }
    });
    $('.fk', el).addEventListener('click', (e) => { if (e.target.closest('span') && /Actions/.test(e.target.closest('span').textContent) && shown[sel]) { actions = true; aSel = 0; detail(); } });
    render(); setTimeout(() => q.focus({ preventScroll: true }), 0);
  } };

  /* ---------------------------------------------------------------- Top bar: the strip's items, the Pilot dropdown, the clock, the terminal */
  P.menubar = { app: 'Pilot', try: 'Click any item in the top bar: workspaces, the timer, CPU, sound, Wi-Fi, the clock, the Pilot icon; switch items on and off below', render(el) {
    BARON.timer = 1; BARON.weather = 1; tmr.run = true; applyBar();
    const groups = [['left', 'Left'], ['centre', 'Centre'], ['right', 'Right']];
    const body = `<p class="lead">Pilot’s own bar in place of the macOS menu bar, like Omarchy’s Waybar; the real menu bar comes back on a held key. Every item above is live.</p><div class="stbar"><span>Bar</span>${seg('barmode', ['Pilot’s top bar', 'macOS menu bar'], 0)}</div>${groups.map(([g, n]) => `<div class="card2"><div class="chd">${IC('menubar')}${n}<small>drag to arrange in Pilot</small></div>${BARITEMS.filter(b => b[3] === g).map(([k, name, ic]) => `<button type="button" class="trow bi2" data-bi2="${k}" aria-pressed="${!!BARON[k]}" style="grid-template-columns:22px minmax(0,1fr) auto"><span class="ico">${IC(ic)}</span><span>${name}</span><i class="tgl"></i></button>`).join('')}</div>`).join('')}`;
    el.innerHTML = win('Desktop', [['Tiling', 'Running'], ['Menu bar', 'Top bar on'], ['Look', 'Void']], 1, 'Menu bar', '', body) + `<div class="term"><div class="tl"><span>Ghostty</span><span>~/code/site</span></div><div class="tt"><span class="p">❯</span> brew upgrade<br><span class="d">==&gt; Upgrading 3 outdated packages</span><br><span class="p">❯</span> <span class="cur"></span></div></div>`;
    el.classList.add('p-bar');
    $$('[data-bi2]', el).forEach(b => b.addEventListener('click', () => { const k = b.dataset.bi2; BARON[k] = BARON[k] ? 0 : 1; b.setAttribute('aria-pressed', !!BARON[k]); applyBar(); if (k === 'timer') tmr.run = !!BARON.timer; }));
    wireSeg(el, 'barmode', (i) => { $('#desk .tb2').classList.toggle('macos', i === 1); toast(i ? 'The macOS menu bar is back while you hold its key' : 'Pilot’s top bar'); });
  } };
  const toggleTerm = () => { const pb = $('#desk .p-bar'); if (pb) { pb.classList.toggle('open'); return; } show('menubar'); setTimeout(() => $('#desk .p-bar')?.classList.add('open'), 80); };

  /* ---------------------------------------------------------------- AI: the chat under the top bar, and the selection box */
  P.ai = { app: 'Notes', try: 'Ask one of the questions; or select words in the note behind for the selection box', render(el) {
    const S = [['How do I undo the last git commit but keep the changes?', 'Use <code>git reset --soft HEAD~1</code>. It moves the branch back one commit and leaves the changes staged.', 'git reset --soft HEAD~1'], ['Tile Slack and Mail side by side.', 'Done: <b>Slack left, Mail right</b>, on workspace 2.', ''], ['Make Hyper+Y run brew upgrade.', 'ALLOW', '']];
    el.innerHTML = `<div class="p-ai2"><div class="notewin pn"><div class="hd2">${IC('note')}Notes › Design review</div><div class="selp"><p>Can we move the design review to Thursday? A few of us are out on Wednesday and I’d rather everyone sees the pricing options together.</p></div></div><div class="aichat pn"><div class="ahd">${IC('spark')}<b>Ask AI</b><span>Claude Code · Sonnet</span><span class="sp"></span><span class="hk3">esc <i>close</i></span><span class="hk3">⌘N <i>new chat</i></span></div><div class="msgs"><div class="empty">Ask anything. Pilot answers through the Claude or ChatGPT plan you already pay for, your own API key, or Ollama on the Mac.</div></div><div class="sug">${S.map(([q], i) => `<button type="button" data-s="${i}">${q}</button>`).join('')}</div><div class="ask2"><span>Ask anything</span><i>↑</i></div></div><div class="selbox pn" hidden><div class="ahd">${IC('spark')}<b>Ask AI</b><span>Claude Code · Haiku</span><span class="sp"></span><span class="hk3">esc <i>close</i></span></div><blockquote class="sq"></blockquote><small class="smeta"></small><div class="rw">${['Fix grammar', 'Make professional', 'Make concise', 'Simplify'].map(r => `<button type="button" data-r="${r}">${r}</button>`).join('')}<button type="button" aria-label="More">…</button></div><div class="ask2"><span>Ask about the selection, or pick a rewrite</span><i>↑</i></div></div></div>`;
    const msgs = $('.msgs', el), chat = $('.aichat', el), sb = $('.selbox', el), sq = $('.sq', el); let timer;
    const type = (node, html, done) => { if (reduced) { node.innerHTML = html; done && done(); return; } const tmp = document.createElement('div'); tmp.innerHTML = html; const text = tmp.textContent; let i = 0; clearInterval(timer); timer = setInterval(() => { i += 3; if (i >= text.length) { clearInterval(timer); node.innerHTML = html; done && done(); } else node.innerHTML = esc(text.slice(0, i)) + '<span class="cur"></span>'; msgs.scrollTop = msgs.scrollHeight; }, 22); };
    $$('.sug button', el).forEach(b => b.addEventListener('click', () => {
      const [qq, a, code] = S[+b.dataset.s]; $('.empty', msgs)?.remove();
      msgs.insertAdjacentHTML('beforeend', `<div class="me">${esc(qq)}</div><div class="ai"></div>`); const node = msgs.lastElementChild;
      if (a === 'ALLOW') type(node, 'It can change Pilot for you. Anything it runs waits for your Allow.', () => { node.insertAdjacentHTML('beforeend', `<div class="allow"><b>Allow pilot, from claude?</b><span class="cmd">Run shell: brew upgrade</span><div class="act"><button type="button" class="bt">Deny</button><button type="button" class="bt ink">Allow</button></div></div>`); $$('.allow .bt', node).forEach(x => x.addEventListener('click', () => { $('.act', node).innerHTML = `<span class="cmd">${x.textContent === 'Allow' ? 'Allowed.' : 'Denied.'}</span>`; })); });
      else type(node, a, () => { if (code) node.insertAdjacentHTML('beforeend', `<pre>${esc(code)}</pre>`); node.insertAdjacentHTML('beforeend', `<button type="button" class="cpy">${IC('copy')}Copy</button>`); $('.cpy', node).addEventListener('click', () => toast('Copied')); msgs.scrollTop = msgs.scrollHeight; });
    }));
    const selp = $('.selp', el);
    const onSel = () => { const s = getSelection(); const t = s && !s.isCollapsed && selp.contains(s.anchorNode) ? s.toString().trim() : ''; if (!t) return; sq.textContent = t; $('.smeta', el).textContent = `Selected in Notes · ${t.length} characters`; chat.hidden = true; sb.hidden = false; };
    selp.addEventListener('pointerup', () => setTimeout(onSel, 10)); selp.addEventListener('keyup', onSel);
    $$('.rw [data-r]', el).forEach(b => b.addEventListener('click', () => { const r = b.dataset.r, t = sq.textContent; const out = r === 'Make concise' ? 'Can we move the design review to Thursday? Several of us are out Wednesday.' : r === 'Make professional' ? 'Could we move the design review to Thursday? Several team members are unavailable on Wednesday, and it would be best to review the pricing options together.' : r === 'Simplify' ? 'Can we do the design review on Thursday? Some of us are away on Wednesday.' : t.replace("I’d rather", 'I would rather'); sq.textContent = ''; let i = 0; if (reduced) { sq.textContent = out; return; } clearInterval(timer); timer = setInterval(() => { i += 3; sq.textContent = out.slice(0, i); if (i >= out.length) clearInterval(timer); }, 20); }));
    this.focusChat = () => { sb.hidden = true; chat.hidden = false; };
  } };

  /* ---------------------------------------------------------------- Stats: the overview, as Mac › Stats draws it */
  P.stats = { app: 'Pilot', try: 'Switch <b>Show</b> between Line, Bars and Number; open <b>Activity</b> and quit an app', render(el) {
    const APPS2 = [['Safari', 'globe', 27.2, '1.9 GB', 'Heavy'], ['Zed', 'code', 8.4, '1.1 GB', ''], ['Ghostty', 'term', 1.8, '67 MB', ''], ['Pilot', 'grid', 1.2, '276 MB', 'Pilot'], ['Notes', 'note', .8, '147 MB', ''], ['Music', 'music', .1, '96 MB', '']];
    const CARDS = [['CPU', 'chip', 'Now · load 1.42', '%', 9, 40, [['User', '6 %'], ['System', '3 %'], ['Uptime', '3 d 4 h']]], ['Memory', 'stack', 'In use of 24 GB', 'GB', 9.0, 24, [['App', '6.1 GB'], ['Wired', '1.9 GB'], ['Compressed', '1.0 GB']], 'Normal · 56 %'], ['Graphics', 'display', 'Apple M4 · 10 cores', '%', 8, 40, [['Renderer', '6 %'], ['Tiler', '3 %']]], ['Disk', 'stack', 'Free of 994 GB', 'GB', 412, 994, [['Reading', '1.4 MB/s'], ['Writing', '340 KB/s']]], ['Network', 'arrows', 'Downloading · Wi-Fi', 'MB/s', 1.2, 12, [['Signal', '−52 dBm'], ['Address', '192.168.1.23']]], ['Temperature', 'gauge', 'CPU average', '°C', 52, 100, [['Hottest', '55 °C'], ['Fan', '1,020 rpm']]]];
    let showMode = 0, tick = null;
    const ser = CARDS.map(c => Array.from({ length: 40 }, (_, i) => c[4] * (1 + .25 * Math.sin(i / 3 + c[4]))));
    const chart = (i) => { const s = ser[i], mx = CARDS[i][5]; if (showMode === 2) return ''; if (showMode === 1) return `<div class="bars2">${s.slice(-20).map(v => `<i style="height:${Math.max(4, v / mx * 100)}%"></i>`).join('')}</div>`; const pts = s.map((v, j) => [j * (236 / 39), 44 - Math.min(1, v / mx) * 44]); const l = 'M' + pts.map(p => p.map(n => n.toFixed(1)).join(',')).join('L'); return `<svg class="spark" viewBox="0 0 236 44" preserveAspectRatio="none"><path class="a" d="${l}L236,44L0,44Z"/><path class="l" d="${l}"/></svg>`; };
    const card = (c, i) => { const v = ser[i][39]; return `<div class="card2 sc"><div class="sch">${IC(c[1])}<b>${c[0]}</b><span class="sp"></span>${c[7] ? `<span class="pill3">${c[7]}</span>` : ''}</div><small class="sub">${c[2]}</small><div class="sv"><b data-v="${i}">${c[3] === 'GB' && v > 99 ? Math.round(v) : v.toFixed(c[3] === '%' || c[3] === '°C' ? 0 : 1)}</b><span>${c[3]}</span></div><div class="sm">${c[6].map(([k, x]) => `<span><small>${k}</small>${x}</span>`).join('')}</div><div class="ch" data-c="${i}">${chart(i)}</div></div>`; };
    const draw = (v) => {
      clearInterval(tick);
      const body = v ? `<p class="lead">What runs on this Mac, heaviest first. Hover a row to quit it.</p><div class="card2"><div class="chd">${IC('window')}Apps<small class="nopen">${APPS2.length} open</small></div><div class="trow th" style="grid-template-columns:22px minmax(0,1fr) 70px 54px 64px 64px"><span></span><span>Name</span><span></span><span class="n">CPU</span><span class="n">Memory</span><span></span></div><div class="alist">${APPS2.map(([n, ic, c, m, tag], k) => `<div class="trow" style="grid-template-columns:22px minmax(0,1fr) 70px 54px 64px 64px"><span class="ico">${IC(ic)}</span><span>${n}${tag ? ` <span class="k2 s" style="font-family:var(--sans)">${tag}</span>` : ''}</span><span class="bar1"><i style="width:${Math.min(100, c * 3)}%"></i></span><span class="n">${c.toFixed(1)} %</span><span class="n">${m}</span>${tag === 'Pilot' ? '<span class="n">locked</span>' : `<button type="button" class="bt" style="height:24px;padding:0 8px;font-size:11.5px" data-q="${k}">Quit</button>`}</div>`).join('')}</div></div>`
        : `<p class="lead">Everything this Mac reads, over time. Apple M4 · macOS 27</p><div class="stbar"><span>Show</span>${seg('show', ['Line', 'Bars', 'Number'], showMode)}<span>Range</span>${seg('range', ['2 min', '1 hour', 'Today'], 0)}</div><div class="scards">${CARDS.map(card).join('')}</div>`;
      el.innerHTML = win('Mac', [['System'], ['Activity'], ['Update & Clean'], ['Stats']], v ? 1 : 3, v ? 'Activity' : 'Stats', v ? seg('ar', ['Now', 'Reports'], 0) : '', body);
      $$('.si', el).forEach(b => b.addEventListener('click', () => { const n = +b.dataset.side; if (n === 1) draw(1); else if (n === 3) draw(0); else if (n === 2) show('update'); }));
      if (!v) { wireSeg(el, 'show', (i) => { showMode = i; draw(0); }); wireSeg(el, 'range', () => {}); const upd = () => { if (!document.body.contains(el)) return clearInterval(tick); ser.forEach((s, i) => { const c = CARDS[i]; s.push(Math.max(c[5] * .02, Math.min(c[5] * .98, s.at(-1) + (Math.random() - .5) * c[5] * .05))); s.shift(); const b = $(`[data-v="${i}"]`, el); if (b) b.textContent = c[3] === 'GB' && s.at(-1) > 99 ? Math.round(s.at(-1)) : s.at(-1).toFixed(c[3] === '%' || c[3] === '°C' ? 0 : 1); const ch = $(`[data-c="${i}"]`, el); if (ch) ch.innerHTML = chart(i); }); }; if (!reduced) tick = setInterval(upd, 1000); }
      else el.addEventListener('click', (e) => { const b = e.target.closest('[data-q]'); if (!b) return; const r = b.closest('.trow'); r.style.opacity = '.4'; b.textContent = 'Quitting…'; setTimeout(() => { r.remove(); const n = $('.nopen', el); if (n) n.textContent = `${$$('.alist .trow', el).length} open`; }, reduced ? 0 : 500); });
    };
    draw(0);
  } };

  /* ---------------------------------------------------------------- Captures: drag an area, then the editor */
  P.captures = { app: 'Safari', try: '<b>Drag</b> across the page; in the editor pick <b>Arrow</b>, <b>Text</b> or <b>Blur</b> and draw, then <b>Done</b>', render(el) {
    const page = `<div class="page"><div class="side"><b>Northwind</b>${['General', 'Members', 'Billing', 'API keys', 'Integrations', 'Audit log'].map((x, i) => `<span class="${i === 2 ? 'on' : ''}">${x}</span>`).join('')}</div><div class="main"><small>Settings / Billing</small><div class="h5">Billing</div><small>Manage your plan, payment method and invoices.</small><div class="card"><small>PRO PLAN</small><b>$12 / month</b><small>Renews on 1 November 2026 · Visa ending 4242</small><span class="btn3">Update card</span></div><div class="card"><small>Billing email</small><b>maya.lind@northwind.studio</b></div></div></div>`;
    el.innerHTML = `<div class="p-cap">${page}<div class="mq"><b></b></div><div class="tools">${[['crop', 'Area', 1], ['window', 'Window'], ['display', 'Screen'], ['scroll', 'Scrolling'], ['video', 'Record'], ['imagetext', 'Text']].map(([i, l, on]) => `<span class="${on ? 'on' : ''}">${IC(i)}${l}</span>`).join('')}</div></div>`;
    const root = $('.p-cap', el), mq = $('.mq', el), lab = $('.mq b', el); let o = null;
    root.addEventListener('pointerdown', (e) => { if (e.target.closest('.tools, .editor')) return; const r = root.getBoundingClientRect(); o = [e.clientX - r.left, e.clientY - r.top, r]; root.setPointerCapture(e.pointerId); mq.style.display = 'block'; Object.assign(mq.style, { left: o[0] + 'px', top: o[1] + 'px', width: '0px', height: '0px' }); lab.textContent = '0 × 0'; });
    root.addEventListener('pointermove', (e) => { if (!o) return; const x = Math.max(0, Math.min(e.clientX - o[2].left, o[2].width)), y = Math.max(0, Math.min(e.clientY - o[2].top, o[2].height)); const l = Math.min(x, o[0]), t = Math.min(y, o[1]), w = Math.abs(x - o[0]), h = Math.abs(y - o[1]); Object.assign(mq.style, { left: l + 'px', top: t + 'px', width: w + 'px', height: h + 'px' }); lab.textContent = `${Math.round(w * 2)} × ${Math.round(h * 2)}`; });
    const end = () => { if (!o) return; const r = o[2]; o = null; const w = parseFloat(mq.style.width), h = parseFloat(mq.style.height); if (w > 16 && h > 16) { const box = { l: parseFloat(mq.style.left), t: parseFloat(mq.style.top), w, h, W: r.width, H: r.height }; setTimeout(() => { mq.style.display = 'none'; editor(box); }, reduced ? 0 : 250); } else mq.style.display = 'none'; };
    root.addEventListener('pointerup', end); root.addEventListener('pointercancel', end);
    const editor = (b) => {
      const ed = document.createElement('div'); ed.className = 'editor pn';
      const scale = Math.min(1, 520 / b.w, 300 / b.h);
      ed.innerHTML = `<div class="etb">${[['cursor', 'Select'], ['arrowmark', 'Arrow', 1], ['squares', 'Box'], ['text', 'Text'], ['highlight', 'Highlight'], ['eyeoff', 'Blur'], ['crop', 'Crop']].map(([i, l, on], k) => `<button type="button" class="et${on ? ' on' : ''}" data-tool="${l}" aria-label="${l}" title="${l}">${IC(i)}</button>`).join('')}<span class="sp"></span><button type="button" class="et" data-undo aria-label="Undo">${IC('arrowcirc')}</button></div><div class="ecv"><div class="eimg" style="width:${b.w * scale}px;height:${b.h * scale}px"><div class="eclip" style="width:${b.W}px;height:${b.H}px;transform:translate(${-b.l * scale}px,${-b.t * scale}px) scale(${scale});transform-origin:0 0">${page}</div><svg class="emarks" width="100%" height="100%"></svg></div></div><div class="ebot"><span>${Math.round(b.w * 2)} × ${Math.round(b.h * 2)}</span><span class="sp"></span><button type="button" class="bt" data-cancel>Cancel</button><button type="button" class="bt ink" data-done>Done</button></div>`;
      root.appendChild(ed); setApp('Pilot');
      let tool = 'Arrow', d0 = null, cur2 = null; const svg = $('.emarks', ed), marks = [];
      $$('[data-tool]', ed).forEach(t => t.addEventListener('click', () => { tool = t.dataset.tool; $$('[data-tool]', ed).forEach(x => x.classList.toggle('on', x === t)); }));
      const NS = 'http://www.w3.org/2000/svg';
      const pt = (e) => { const r = svg.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
      svg.addEventListener('pointerdown', (e) => { e.stopPropagation(); const [x, y] = pt(e); svg.setPointerCapture(e.pointerId); d0 = [x, y];
        if (tool === 'Text') { const t = document.createElementNS(NS, 'text'); t.setAttribute('x', x); t.setAttribute('y', y); t.setAttribute('class', 'mk-t'); t.textContent = 'Update the card first'; svg.appendChild(t); marks.push(t); d0 = null; return; }
        cur2 = document.createElementNS(NS, tool === 'Arrow' ? 'line' : 'rect'); cur2.setAttribute('class', tool === 'Arrow' ? 'mk-a' : tool === 'Blur' ? 'mk-b' : tool === 'Highlight' ? 'mk-h' : 'mk-r'); svg.appendChild(cur2); marks.push(cur2); });
      svg.addEventListener('pointermove', (e) => { if (!d0 || !cur2) return; const [x, y] = pt(e); if (cur2.tagName === 'line') { cur2.setAttribute('x1', d0[0]); cur2.setAttribute('y1', d0[1]); cur2.setAttribute('x2', x); cur2.setAttribute('y2', y); } else { cur2.setAttribute('x', Math.min(x, d0[0])); cur2.setAttribute('y', Math.min(y, d0[1])); cur2.setAttribute('width', Math.abs(x - d0[0])); cur2.setAttribute('height', Math.abs(y - d0[1])); } });
      svg.addEventListener('pointerup', () => { d0 = null; cur2 = null; });
      $('[data-undo]', ed).addEventListener('click', () => marks.pop()?.remove());
      $('[data-cancel]', ed).addEventListener('click', () => { ed.remove(); setApp('Safari'); });
      $('[data-done]', ed).addEventListener('click', () => { ed.remove(); setApp('Safari'); toast('Copied to the clipboard; saved to Desktop'); });
      svg.insertAdjacentHTML('beforeend', '<defs><marker id="ah" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" class="mk-ah"/></marker></defs>');
    };
  } };

  /* ------------------------------------------------ the studio: the areas as a sidebar beside one Pilot desktop they drive */
  const A = Object.fromEntries(D.areas.map(a => [a[0], a]));
  const studio = $('#studio'), areaEl = $('#area-preview');
  let cur = null;
  const stage = document.createElement('div'); stage.className = 'stage2';
  stage.innerHTML = `<div class="scr" id="desk" role="region" aria-label="A live Pilot desktop">${topBar()}<div class="pv" id="pv"></div></div><div class="capR" aria-live="polite"><div><p class="h4" id="cap-h"></p><p id="cap-p"></p></div><div class="rt"><span class="try dtag">Playing a demo. Click the desktop to take over.</span><span class="try" id="cap-try"></span><a class="more" href="#" id="cap-a"></a></div></div>`;
  const fill = (s) => {
    const a = A[s], p = P[s]; closePop(); setApp(p.app); topExt();
    const dk = $('#desk'); if (dk && s !== 'look') { dk.removeAttribute('style'); dk.classList.remove('toybox', 'solid'); }
    $('#desk .dtoast')?.classList.remove('on');
    const pv = $('#pv'); pv.innerHTML = ''; const holder = document.createElement('div'); pv.appendChild(holder); p.render(holder);
    $('#cap-h').textContent = a[1]; $('#cap-p').textContent = a[3]; $('#cap-try').innerHTML = 'Try: ' + p.try;
    const link = $('#cap-a'); if (areaEl) link.hidden = true; else { link.textContent = `All ${a[4]} on the ${a[6]} page`; link.href = s + '.html'; }
  };
  const show = (s) => { if (!P[s]) return; cur = s; $$('.ak').forEach(k => { const on = k.dataset.s === s; k.setAttribute('aria-selected', on); k.tabIndex = on ? 0 : -1; }); fill(s); };
  if (studio) {
    studio.innerHTML = `<nav class="arail" role="tablist" aria-label="Pilot's areas" aria-orientation="vertical">${D.groups.map(([h, ks]) => `<div class="rg"><p class="rgh">${h}</p>${ks.map(s => { const a = A[s]; return `<button type="button" class="ak" role="tab" id="k-${s}" data-s="${s}" aria-selected="false" tabindex="-1" aria-controls="desk"><span class="aki">${IC(a[2])}</span><span class="akn">${a[6]}</span>${a[5] ? `<span class="akk"><kbd>⇪</kbd><kbd>${a[5]}</kbd></span>` : ''}</button>`; }).join('')}</div>`).join('')}</nav>`;
    studio.appendChild(stage);
    const rail = $('.arail', studio);
    rail.addEventListener('click', (e) => { const k = e.target.closest('.ak'); if (k) { show(k.dataset.s); if (matchMedia('(max-width: 820px)').matches) k.scrollIntoView({ inline: 'center', block: 'nearest', behavior: reduced ? 'auto' : 'smooth' }); } });
    rail.addEventListener('keydown', (e) => { const ks = $$('.ak', rail), i = ks.findIndex(k => k.dataset.s === cur), d = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key]; if (!d) return; e.preventDefault(); const n = ks[(i + d + ks.length) % ks.length]; show(n.dataset.s); n.focus(); });
    show(D.groups[0][1][0]);
  } else if (areaEl && P[areaEl.dataset.area]) { stage.classList.add('solo'); areaEl.appendChild(stage); show(areaEl.dataset.area); }
  applyBar();
  stage.addEventListener('click', (e) => {
    const ws = e.target.closest('.tbws button'); if (ws) { const n = +ws.dataset.ws; if (cur === 'windows' && P.windows.ws) P.windows.ws(n); else $$('#desk .tbws button').forEach(x => x.classList.toggle('on', x === ws)); return; }
    const it = e.target.closest('[data-tb]');
    if (it) {
      const k = it.dataset.tb;
      if (k === 'pilot') { if ($('#desk .pop2.pd')) { closePop(); return; } const p = popAt(it, dropHTML(), 'pd'); $$('[data-sw]', p).forEach(b => b.addEventListener('click', () => { const s = b.dataset.sw; switches[s] = !switches[s]; b.setAttribute('aria-pressed', switches[s]); $('small', b).textContent = switches[s] ? ({ hyper: 'binds on', tiling: "Pilot's tiler", topbar: 'shown', awake: 'kept awake', clip: 'recording' })[s] : 'off'; toast(`${$('b', b).textContent} ${switches[s] ? 'on' : 'off'}`); })); $$('[data-go]', p).forEach(b => b.addEventListener('click', () => { closePop(); if (b.dataset.go) show(b.dataset.go); else toast(b.textContent.trim()); })); }
      else if (k === 'clock') { if ($('#desk .pop2.pc')) { closePop(); return; } const p = popAt(it, calHTML(0), 'pc'); p.addEventListener('click', (ev) => { const c = ev.target.closest('[data-cal]'); if (c) { ev.stopPropagation(); const off = +$('.calp', p).dataset.off + +c.dataset.cal; p.innerHTML = calHTML(off); } }); }
      else if (k === 'term') { closePop(); toggleTerm(); }
      else if (POPS[k]) openPop(it, k);
      else if (k === 'ask') { closePop(); if (cur === 'ai' && P.ai.focusChat) P.ai.focusChat(); else show('ai'); }
      return;
    }
    if (!e.target.closest('.pop2')) closePop();
  });
  if (!reduced) setInterval(() => { const t = $('#tb-time'); if (t) t.textContent = hhmm(); cpuNow = Math.max(3, Math.min(31, cpuNow + Math.round((Math.random() - .5) * 6))); const c = $('#tb-cpu'); if (c) c.textContent = cpuNow + '%'; }, 2000);

  /* ------------------------------------------------ the demo (P88, 2026-11-03): a Mac pointer uses each preview as a person
     would. It glides on a hand's speed curve (a curved reach that lands a little short, then settles), presses with a ring, types at
     human speed and shows the keys it holds, Hyper lit. It plays only while the desktop is on screen and the tab is visible, never
     under reduced motion, and stops for good the moment the visitor clicks, taps, types or tabs into it; scrolled away and back, it plays
     again. Its events are the previews' own handlers; while it plays, focus and scrollIntoView inside it are held so the page
     never jumps. On the home page it tours the areas through the sidebar; on an area page it repeats that area. */
  const DEMO = {
    launcher: async (d) => {
      await d.caps(['Hyper', 'Space'], 900);
      await d.type('.lm input', 'ghost'); await d.wait(650);
      await d.key('.lm input', 'Enter'); await d.wait(900);
      await d.erase('.lm input'); await d.type('.lm input', '12*7'); await d.wait(1300);
      await d.erase('.lm input'); await d.type('.lm input', '5 km in mi'); await d.wait(1400);
      await d.erase('.lm input'); await d.type('.lm input', '#C6F432'); await d.wait(1400);
      await d.erase('.lm input');
    },
    files: async (d) => {
      await d.wait(700); await d.erase('.lm input'); await d.type('.lm input', 'delivery'); await d.wait(900);
      await d.key('.lm input', 'ArrowDown'); await d.wait(1200);
      await d.erase('.lm input'); await d.type('.lm input', 'invoce'); await d.wait(1200);
    },
    windows: async (d) => {
      await d.click(['.win[data-a="zed"]', .5, .4]);
      await d.key('.p-win', 'ArrowLeft', { hyper: true });
      await d.key('.p-win', 'ArrowRight', { hyper: true });
      await d.key('.p-win', 'ArrowLeft', { hyper: true, shift: true });
      await d.click('[data-act="float"]', { dwell: 1000 }); await d.click('[data-act="float"]');
      await d.click('[data-sg="lay"] button[data-v="1"]', { dwell: 900 });
      await d.key('.p-win', 'ArrowRight', { hyper: true });
      await d.click('[data-sg="lay"] button[data-v="0"]');
      await d.click('#desk .tbws [data-ws="3"]', { dwell: 1000 }); await d.click('#desk .tbws [data-ws="2"]');
    },
    desktop: async (d) => {
      await d.click(['.dk', .86, .8]);
      await d.click('.cmenu2 [data-m="gal"]', { dwell: 700 });
      await d.click('.gal [data-wall="3"]', { dwell: 1000 }); await d.click('.gal [data-wall="1"]', { dwell: 1000 });
      await d.key('#desk', 'Escape');
      await d.drag(['.wg[data-w="notes"]', .5, .12], ['.dk', .66, .62], { caps: ['Hyper'] });
      await d.click('[data-sg="dv"] button[data-v="1"]', { dwell: 700 });
      await d.click('[data-edit]', { dwell: 700 });
      await d.drag('[data-grip="0"]', ['[data-grip="0"]', 4, .5]);
      await d.click('[data-edit]', { dwell: 600 });
      await d.click('[data-sg="dv"] button[data-v="0"]');
    },
    dictation: async (d) => {
      await d.hold('.hold', 4300); await d.wait(1100);
      await d.click('[data-read]', { dwell: 3200 });
    },
    captures: async (d) => {
      await d.caps(['Hyper', 'S'], 800);
      await d.drag(['.p-cap .main .h5', -.04, -.5], ['.p-cap .main .card:last-of-type', 1.02, 1.3]);
      await d.wait(700);
      await d.drag(['.editor .emarks', .82, .82], ['.editor .emarks', .6, .5]);
      await d.click('.editor [data-tool="Blur"]');
      await d.drag(['.editor .emarks', .05, .72], ['.editor .emarks', .55, .9]);
      await d.click('.editor [data-done]', { dwell: 1200 });
    },
    ai: async (d) => {
      await d.caps(['Hyper', 'Q'], 800);
      await d.click('.sug button[data-s="0"]', { dwell: 3200 });
      await d.select('.selp p', 0, 42); await d.wait(900);
      await d.click('.rw [data-r="Make concise"]', { dwell: 2600 });
    },
    clipboard: async (d) => {
      await d.caps(['Hyper', 'V'], 800);
      await d.key('.p-clip input', 'ArrowDown'); await d.key('.p-clip input', 'ArrowDown');
      await d.click('.p-clip .fl [data-k="colour"]', { dwell: 900 });
      await d.click('.p-clip .fl [data-k="all"]');
      await d.type('.p-clip input', 'git'); await d.wait(700);
      await d.key('.p-clip input', 'Enter', { dwell: 1200 }); await d.erase('.p-clip input');
    },
    keys: async (d) => {
      await d.hold('[data-hold]', 2600, ['Hyper']); await d.wait(600);
      await d.click('.si[data-side="1"]', { dwell: 900 });
      await d.click('.bboard [data-k="v"]', { dwell: 1400 });
    },
    convert: async (d) => {
      await d.click('.fi2[data-i="0"]', { dwell: 800 });
      await d.click('.cmenu2 [data-t="PNG"]', { dwell: 1600 });
    },
    menubar: async (d) => {
      await d.click('#desk [data-tb="clock"]', { dwell: 1400 });
      await d.click('#desk [data-tb="vol"]', { dwell: 1200 });
      await d.click('#desk [data-tb="pilot"]', { dwell: 1600 }); await d.click('#desk [data-tb="pilot"]');
    },
  };
  const TOUR = ['launcher', 'windows', 'desktop', 'dictation', 'captures', 'ai', 'clipboard', 'keys', 'files', 'convert', 'menubar'];
  const layer = studio || (areaEl && stage.isConnected ? stage : null), deskEl = $('#desk');
  if (layer && deskEl && !reduced && (studio || DEMO[cur])) {
    layer.classList.add('dlayer');
    const ptr = document.createElement('div'); ptr.className = 'ptr'; ptr.setAttribute('aria-hidden', 'true');
    ptr.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5.5 2.8v16.4l4.2-4 2.7 6.2 2.9-1.2-2.7-6.1h5.9z"/></svg><i></i>';
    layer.appendChild(ptr);
    const kc = document.createElement('div'); kc.className = 'kcast'; kc.setAttribute('aria-hidden', 'true'); deskEl.appendChild(kc);
    const capR = $('.capR', stage);
    let pos = null, tok = null, touched = false, seen = false, wake = 0, downEl = null, kcT = 0;
    const STOP = new Error('demo stopped');
    const sleep = (t, ms) => new Promise((ok, no) => setTimeout(() => (t.dead ? no(STOP) : ok()), ms));
    const rnd = (a, b) => a + Math.random() * (b - a);
    const lr = () => layer.getBoundingClientRect();
    const draw = () => { ptr.style.transform = `translate(${pos[0].toFixed(1)}px, ${pos[1].toFixed(1)}px)`; };
    const client = () => { const L = lr(); return [L.left + pos[0], L.top + pos[1]]; };
    /* held while the demo plays: no focus, page scroll or pointer-capture error from the previews' own handlers */
    const F0 = HTMLElement.prototype.focus, S0 = Element.prototype.scrollIntoView, C0 = Element.prototype.setPointerCapture, R0 = Element.prototype.releasePointerCapture;
    const inner = (el) => { for (let p = el.parentElement; p && p !== layer; p = p.parentElement) { const cs = getComputedStyle(p); if (/auto|scroll/.test(cs.overflowY + cs.overflowX) && (p.scrollHeight > p.clientHeight || p.scrollWidth > p.clientWidth)) { const r = el.getBoundingClientRect(), q = p.getBoundingClientRect(); if (r.top < q.top) p.scrollTop -= q.top - r.top; else if (r.bottom > q.bottom) p.scrollTop += r.bottom - q.bottom; if (r.left < q.left) p.scrollLeft -= q.left - r.left + 16; else if (r.right > q.right) p.scrollLeft += r.right - q.right + 16; return; } } };
    HTMLElement.prototype.focus = function (o) { if (tok && layer.contains(this)) return; return F0.call(this, o); };
    Element.prototype.scrollIntoView = function (o) { if (tok && layer.contains(this)) return inner(this); return S0.call(this, o); };
    Element.prototype.setPointerCapture = function (id) { try { return C0.call(this, id); } catch (_) { /* a demo's pointer is not a live one */ } };
    Element.prototype.releasePointerCapture = function (id) { try { return R0.call(this, id); } catch (_) { /* as above */ } };
    const fire = (el, type, o = {}) => {
      const [x, y] = client(), P = type.startsWith('pointer'), down = /down|move/.test(type) && downEl;
      const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: type.endsWith('move') ? -1 : 0, buttons: down ? 1 : 0, ...o };
      if (P) Object.assign(init, { pointerId: 1, pointerType: 'mouse', isPrimary: true, width: 1, height: 1, pressure: down ? .5 : 0 });
      (el.isConnected ? el : document).dispatchEvent(P ? new PointerEvent(type, init) : new MouseEvent(type, init));
    };
    const hit = (el) => { const [x, y] = client(), h = document.elementFromPoint(x, y); return h && el.contains(h) ? h : el; };
    const press = (on) => { ptr.classList.toggle('down', on); if (on) { const i = $('i', ptr); i.classList.remove('go'); void i.offsetWidth; i.classList.add('go'); } };
    const LABEL = { ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓', Enter: '↵', Escape: 'esc', Backspace: '⌫', Shift: '⇧' };
    const caps = (ks, ms) => { clearTimeout(kcT); kc.innerHTML = ks.map(k => k === 'Hyper' ? '<kbd class="hy">⇪ Hyper</kbd>' : `<kbd>${esc(LABEL[k] || k)}</kbd>`).join('<span>+</span>'); kc.classList.add('on'); if (ms) kcT = setTimeout(() => kc.classList.remove('on'), ms); };
    const bez = (a, b, c, e, s) => { const u = 1 - s; return [0, 1].map(i => u * u * u * a[i] + 3 * u * u * s * b[i] + 3 * u * s * s * c[i] + s * s * s * e[i]); };
    const ease = (s) => s * s * s * (10 - 15 * s + 6 * s * s);   // minimum jerk: a hand's reach, still at both ends
    const leg = (t, from, to, ms, bend, onMove) => new Promise((ok, no) => {
      const dx = to[0] - from[0], dy = to[1] - from[1], n = [-dy, dx], L = Math.hypot(dx, dy) || 1, k = bend / L;
      const c1 = [from[0] + dx * .3 + n[0] * k, from[1] + dy * .3 + n[1] * k], c2 = [from[0] + dx * .72 + n[0] * k * .55, from[1] + dy * .72 + n[1] * k * .55];
      const t0 = performance.now();
      const step = (now) => { if (t.dead) return no(STOP); const s = Math.min(1, (now - t0) / ms); pos = bez(from, c1, c2, to, ease(s)); draw(); onMove && onMove(); if (s < 1) requestAnimationFrame(step); else ok(); };
      requestAnimationFrame(step);
    });
    const glide = async (t, to, onMove) => {
      const from = pos || [to[0] + 90, to[1] + 70]; if (!pos) { pos = from; draw(); }
      const dist = Math.hypot(to[0] - from[0], to[1] - from[1]); if (dist < 2) return;
      const ms = Math.min(1150, 260 + 150 * Math.log2(1 + dist / 40)), bend = dist * rnd(.06, .16) * (Math.random() < .5 ? -1 : 1);
      if (dist < 90) return leg(t, from, to, ms, bend * .4, onMove);
      const ux = (to[0] - from[0]) / dist, uy = (to[1] - from[1]) / dist, short = Math.min(9, dist * .045);
      await leg(t, from, [to[0] - ux * short + rnd(-2, 2), to[1] - uy * short + rnd(-2, 2)], ms * .84, bend, onMove);   // lands a touch short…
      await leg(t, pos, to, Math.max(110, ms * .2), 0, onMove);                                                          // …then settles
    };
    const api = (t) => {
      const at = (spec) => {
        let s = spec, fx = .5, fy = .5; if (Array.isArray(spec)) [s, fx = .5, fy = .5] = spec;
        const el = typeof s === 'string' ? $(s, layer) : s; if (!el || !el.isConnected) return null;
        const r = el.getBoundingClientRect(); if (!r.width && !r.height) return null;
        const L = lr(), j = (w) => rnd(-1, 1) * Math.min(5, w * .12);
        return { el, x: r.left - L.left + r.width * fx + j(r.width), y: r.top - L.top + r.height * fy + j(r.height) };
      };
      const d = {
        wait: (ms) => sleep(t, ms),
        caps: (ks, ms) => { caps(ks, ms); return sleep(t, ms * .75); },
        move: async (spec) => { const p = at(spec); if (p) await glide(t, [p.x, p.y]); return p; },
        click: async (spec, o = {}) => {
          const p = await d.move(spec); if (!p) return;
          await sleep(t, rnd(90, 210)); const h = hit(p.el);
          press(true); fire(h, 'pointerdown'); fire(h, 'mousedown'); await sleep(t, rnd(70, 120));
          fire(h, 'pointerup'); fire(h, 'mouseup'); press(false); fire(h, 'click');
          await sleep(t, o.dwell ?? rnd(380, 560));
        },
        type: async (spec, text) => {
          const el = typeof spec === 'string' ? $(spec, layer) : spec; if (!el) return;
          const r = el.getBoundingClientRect(), L = lr(); if (!pos || Math.hypot(pos[0] - (r.left - L.left + 30), pos[1] - (r.top - L.top + r.height / 2)) > 40) await d.click([el, .12, .5], { dwell: 200 });
          for (const ch of text) { el.value += ch; el.dispatchEvent(new InputEvent('input', { bubbles: true, data: ch, inputType: 'insertText' })); await sleep(t, ch === ' ' ? rnd(120, 200) : rnd(65, 150) + (Math.random() < .08 ? 220 : 0)); }
        },
        erase: async (spec) => {
          const el = typeof spec === 'string' ? $(spec, layer) : spec; if (!el || !el.value) return;
          caps(['Backspace']); await sleep(t, 160);
          while (el.value) { el.value = el.value.slice(0, -1); el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' })); await sleep(t, rnd(32, 50)); }
          kc.classList.remove('on'); await sleep(t, 260);
        },
        key: async (spec, key, o = {}) => {
          const el = typeof spec === 'string' ? $(spec, layer) : spec; if (!el) return;
          caps([...(o.hyper ? ['Hyper'] : []), ...(o.shift ? ['Shift'] : []), key], 900); await sleep(t, 160);
          const init = { key, bubbles: true, cancelable: true, shiftKey: !!o.shift };
          el.dispatchEvent(new KeyboardEvent('keydown', init)); await sleep(t, 110); el.dispatchEvent(new KeyboardEvent('keyup', init));
          await sleep(t, o.dwell ?? rnd(520, 700));
        },
        hold: async (spec, ms, ks) => {
          const p = await d.move(spec); if (!p) return; await sleep(t, rnd(120, 200));
          downEl = hit(p.el); press(true); if (ks) caps(ks); fire(downEl, 'pointerdown'); fire(downEl, 'mousedown');
          await sleep(t, ms); fire(downEl, 'pointerup'); fire(downEl, 'mouseup'); downEl = null; press(false); kc.classList.remove('on');
        },
        drag: async (a, b, o = {}) => {
          const p = await d.move(a); if (!p) return; await sleep(t, rnd(120, 200));
          downEl = hit(p.el); press(true); if (o.caps) caps(o.caps); fire(downEl, 'pointerdown'); fire(downEl, 'mousedown'); await sleep(t, 120);
          const q = at(b); if (q) await glide(t, [q.x, q.y], () => fire(downEl, 'pointermove'));
          await sleep(t, 90); fire(downEl, 'pointerup'); fire(downEl, 'mouseup'); downEl = null; press(false); kc.classList.remove('on');
          await sleep(t, o.dwell ?? 500);
        },
        select: async (spec, from, to) => {   // drag across words: the selection follows the pointer, as it does in Pilot
          const el = $(spec, layer), node = el && el.firstChild; if (!node || node.nodeType !== 3) return;
          const rg = document.createRange(), L = lr();
          const xy = (i, end) => { rg.setStart(node, i); rg.setEnd(node, i + 1); const r = rg.getBoundingClientRect(); return [(end ? r.right : r.left) - L.left, r.top + r.height * .55 - L.top]; };
          await glide(t, xy(from)); await sleep(t, 160); press(true); fire(el, 'pointerdown'); fire(el, 'mousedown');
          const s = getSelection();
          for (let i = from; i < Math.min(to, node.length); i++) { pos = xy(i, true); draw(); rg.setStart(node, from); rg.setEnd(node, i + 1); s.removeAllRanges(); s.addRange(rg.cloneRange()); await sleep(t, rnd(16, 30)); }
          fire(el, 'pointerup'); fire(el, 'mouseup'); press(false);
        },
      };
      return d;
    };
    const stop = () => {
      if (!tok) return; tok.dead = true; tok = null;
      if (downEl) { fire(downEl, 'pointerup'); downEl = null; }
      ptr.classList.remove('on', 'down'); kc.classList.remove('on'); stage.classList.remove('demo'); capR?.setAttribute('aria-live', 'polite');
    };
    const play = async () => {
      if (tok || touched || !seen || document.hidden) return;
      const t = tok = { dead: false }, d = api(t);
      stage.classList.add('demo'); capR?.setAttribute('aria-live', 'off');
      ptr.classList.add('on');
      try {
        if (studio) {
          const order = TOUR.filter(s => DEMO[s] && P[s]); let i = 0;
          for (;;) { const s = order[i++ % order.length], k = $(`#k-${s}`); if (k) inner(k); await d.click(k, { dwell: 900 }); await DEMO[s](d); await sleep(t, 1500); }
        } else {
          for (;;) { await DEMO[cur](d); await sleep(t, 2600); show(cur); await sleep(t, 900); }
        }
      } catch (e) { if (e !== STOP) { stop(); touched = true; } }
    };
    const take = (e) => { if (!e.isTrusted) return; if (tok) stop(); touched = true; };
    layer.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'touch') take(e); }, true);
    ['click', 'keydown', 'contextmenu', 'focusin'].forEach(ty => layer.addEventListener(ty, take, true));
    let moved = 0; layer.addEventListener('pointermove', (e) => { if (!tok || !e.isTrusted || e.pointerType !== 'mouse') return; moved += Math.abs(e.movementX) + Math.abs(e.movementY); if (moved > 40) { moved = 0; take(e); } }, { passive: true });
    new IntersectionObserver(([e]) => {
      seen = e.intersectionRatio >= .55; clearTimeout(wake);
      if (seen) wake = setTimeout(play, 900); else { stop(); touched = false; moved = 0; }
    }, { threshold: [0, .55, 1] }).observe(deskEl);
    document.addEventListener('visibilitychange', () => { clearTimeout(wake); if (document.hidden) stop(); else if (seen) wake = setTimeout(play, 900); });
  }

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
    clips.forEach(v => { near.observe(v); inView.observe(v); const b = v.nextElementSibling;
      b?.addEventListener('click', () => { const off = !v.dataset.paused; if (off) { v.dataset.paused = '1'; v.pause(); } else { delete v.dataset.paused; run(v); } b.setAttribute('aria-label', b.getAttribute('aria-label').replace(off ? 'Pause' : 'Play', off ? 'Play' : 'Pause')); $('path', b).setAttribute('d', off ? 'M5 3v10l8-5z' : 'M4.5 3h2.5v10H4.5zM9 3h2.5v10H9z'); }); });
    document.addEventListener('visibilitychange', () => clips.forEach(v => { if (document.hidden) v.pause(); else if (v._in) run(v); }));
  }

  /* ------------------------------------------------ the hero: strike, film */
  const hero = $('.hero');
  if (hero) { const check = () => { const r = hero.getBoundingClientRect(); if (r.top < innerHeight * .85 && r.bottom > 0) { site.classList.add('go'); removeEventListener('scroll', check); } }; addEventListener('scroll', check, { passive: true }); requestAnimationFrame(check); setTimeout(check, 400); }
  const film = $('#film'), play = $('#play'); if (film && play) play.addEventListener('click', () => { film.controls = true; film.play().catch(() => {}); play.remove(); });

  /* ------------------------------------------------ the shader: Glow (Sven, Q571), one fixed canvas behind every page.
     A slow haze in the theme's accent, heavier toward the right, drawn at 40 % of CSS pixels and stretched (a haze needs no
     detail), at most 30 frames a second, paused in a hidden tab, one still frame with reduced motion, none under 600 px. */
  const cv = $('#shader');
  const hasShader = !!cv;
  let mode = hasShader ? 'glow' : 'off', gl = null, raf = 0, last = 0, t0 = performance.now(), uni = {}, TK = null;
  const FS = `precision mediump float;
uniform vec2 R; uniform float T; uniform float Y; uniform vec3 C; uniform float A;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3. - 2. * f); return mix(mix(h(i), h(i + vec2(1., 0.)), f.x), mix(h(i + vec2(0., 1.)), h(i + vec2(1., 1.)), f.x), f.y); }
float fbm(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 4; i++) { v += a * n(p); p = p * 2.03 + 17.; a *= .5; } return v; }
void main(){
  vec2 uv = gl_FragCoord.xy / R;
  vec2 p = vec2(uv.x * R.x / R.y, uv.y - Y) * 1.3; float t = T * .05;
  vec2 q = vec2(fbm(p + vec2(t, 0.)), fbm(p + vec2(3.1, -t)));
  float f = fbm(p + q * 1.6 + vec2(t * .7, -t * .5));
  float m = .3 + .7 * smoothstep(.2, .95, uv.x);
  float a = smoothstep(.42, .92, f) * m * A;
  gl_FragColor = vec4(C * a, a);
}`;
  const VS = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0., 1.); }';
  const tokens = () => {
    const cs = getComputedStyle(document.documentElement);
    const hex = (v) => { v = v.trim().replace('#', ''); return [0, 2, 4].map(i => parseInt(v.slice(i, i + 2), 16) / 255); };
    const lum = (c) => .2126 * c[0] + .7152 * c[1] + .0722 * c[2];
    const g = hex(cs.getPropertyValue('--g')), c = hex(cs.getPropertyValue('--lime')), dark = lum(g) < .5;
    // the haze's peak stays faint enough that the third text keeps 4.5:1 over it
    return { c, a: dark ? .12 : (lum(c) < .3 ? .06 : .2) };
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
    ['R', 'T', 'Y', 'C', 'A'].forEach(k => uni[k] = gl.getUniformLocation(prog, k));
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); return true;
  };
  const size = () => { cv.width = Math.max(1, Math.round(innerWidth * .4)); cv.height = Math.max(1, Math.round(innerHeight * .4)); if (gl) gl.viewport(0, 0, cv.width, cv.height); };
  window.__frames = 0;
  const frame = (tt) => {
    if (!gl) return; window.__frames++; const k = TK || (TK = tokens());
    gl.uniform2f(uni.R, cv.width, cv.height); gl.uniform1f(uni.T, tt); gl.uniform1f(uni.Y, reduced ? 0 : scrollY / innerHeight * .35);
    gl.uniform3fv(uni.C, k.c); gl.uniform1f(uni.A, k.a); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 3);
  };
  const loop = (now) => { raf = 0; if (mode === 'off' || document.hidden) return; if (now - last >= 33) { last = now; frame((now - t0) / 1000); } raf = requestAnimationFrame(loop); };
  const apply = () => {
    if (!hasShader) return; cancelAnimationFrame(raf); raf = 0;
    const off = mode === 'off' || innerWidth < 600;
    document.documentElement.classList.toggle('no-fx', off);
    if (off || !gl) return; size();
    if (reduced) frame(2.2); else raf = requestAnimationFrame(loop);
  };
  if (hasShader && init()) { addEventListener('resize', apply); document.addEventListener('visibilitychange', apply); }
  window.__shader = () => gl ? (gl.getParameter(gl.RENDERER) || 'webgl') : 'css-fallback';

  /* ------------------------------------------------ the theme: Refreshed by default, or one of Pilot's own themes */
  const tbtn = $('.tbtn'), tpop = $('.tpop');
  const setTheme = (t) => {
    if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
    try { t ? localStorage.setItem('pilot-theme', t) : localStorage.removeItem('pilot-theme'); } catch (_) {}
    $$('.tpop [data-t]').forEach(b => b.setAttribute('aria-checked', b.dataset.t === (t || '')));
    $$('.tryth [data-t]').forEach(b => b.setAttribute('aria-pressed', b.dataset.t === (t || '')));
    const on = $(`.tpop [data-t="${t || ''}"] .tsw`); if (on && tbtn) $('.tsw', tbtn).innerHTML = on.innerHTML;
    retoken(); if (hasShader) apply();
  };
  if (tbtn && tpop) {
    const close = () => { tpop.hidden = true; tbtn.setAttribute('aria-expanded', 'false'); };
    tbtn.addEventListener('click', (e) => { e.stopPropagation(); const o = tpop.hidden; tpop.hidden = !o; tbtn.setAttribute('aria-expanded', String(o)); if (o) $('.tpop [aria-checked=true]')?.focus(); });
    tpop.addEventListener('click', (e) => { const b = e.target.closest('[data-t]'); if (b) { setTheme(b.dataset.t); close(); tbtn.focus(); } });
    tpop.addEventListener('keydown', (e) => { const items = $$('.tpop [data-t]'), i = items.indexOf(document.activeElement); if (e.key === 'Escape') { close(); tbtn.focus(); } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); items[(i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length].focus(); } });
    document.addEventListener('click', (e) => { if (!tpop.hidden && !e.target.closest('.thm-menu')) close(); });
    let saved = ''; try { saved = localStorage.getItem('pilot-theme') || ''; } catch (_) {}
    setTheme(new URLSearchParams(location.search).get('theme') ?? saved);
  }
  $$('.tryth [data-t]').forEach(b => b.addEventListener('click', () => setTheme(b.dataset.t)));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { retoken(); if (hasShader) apply(); });
  const tabRow = $('.atabs .row'), tabOn = $('.atabs [aria-current]');
  if (tabRow && tabOn && tabRow.scrollWidth > tabRow.clientWidth) tabRow.scrollLeft = tabOn.offsetLeft - tabRow.clientWidth / 2 + tabOn.offsetWidth / 2;
  apply();
  /* external links open in a new tab, so the Pilot tab stays (Sven 2026-10-29); the generator marks its own, this catches
     the approved privacy text and any link a preview draws */
  const markOut = (root) => $$('a[href^="http"]', root).forEach(a => { if (a.host !== location.host && !/\/download\//.test(a.pathname)) { a.target = '_blank'; a.rel = 'noopener'; } });
  markOut(document); new MutationObserver(() => markOut(document)).observe(document.body, { childList: true, subtree: true });
})();
