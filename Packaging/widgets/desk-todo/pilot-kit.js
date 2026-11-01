// Pilot widget look kit's helpers (pilot-kit.css says how to use the kit). Plain script, no network, no timers of its own.
// PilotKit.on(fn): fn(data) for each pilotdata event, and once for the last data on load; applies data.theme, and lifts a
// .pk-fade list's fade once it shows its end (after each fn and as it scrolls).
// PilotKit.size(): the tile's size class, "strip", "square", "wide" or "large" (Pilot keeps size-<class> on <html>); when
// it changes, PilotKit.on's fn runs again with the last data, so a draw that reads it redraws.
// PilotKit.height(): the panel's height with every .pk-grow at its content's, which Pilot sizes its ready widgets to.
// PilotKit.theme(t): sets the kit's colour tokens from PilotTheme's fields (#rrggbb).
// PilotKit.esc(s): text made safe to put in HTML. Everything a feed or a reading sends goes through it.
// PilotKit.meter(percent, {tone, mark}): a .pk-meter's HTML. PilotKit.tone(used) / toneLeft(left): its tone class.
// PilotKit.spark(values, {width, height, now}): a .pk-spark SVG. PilotKit.icon(name): a line glyph's SVG.
// PilotKit.weather(code, isDay): Open-Meteo's WMO code as {words, icon}. PilotKit.$(id): document.getElementById.
(function () {
  "use strict";
  const K = (window.PilotKit = {});
  const hex = /^#[0-9a-fA-F]{6}$/;
  const roles = ["ground", "surface", "raised", "line", "line2", "text", "text2", "text3",
                 "accent", "second", "third", "good", "amber", "problem"];

  K.$ = (id) => document.getElementById(id);

  K.esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  K.theme = (t) => {
    if (!t || typeof t !== "object") return;
    const root = document.documentElement;
    for (const role of roles) if (hex.test(t[role] || "")) root.style.setProperty("--pk-" + role, t[role]);
    (Array.isArray(t.graphs) ? t.graphs : []).slice(0, 3).forEach((c, i) => {
      if (hex.test(c || "")) root.style.setProperty("--pk-g" + (i + 1), c);
    });
    if (typeof t.dark === "boolean") root.dataset.pkTheme = t.dark ? "dark" : "light";
  };

  K.size = () => {
    const m = /(?:^|\s)size-(strip|square|wide|large)(?:\s|$)/.exec(document.documentElement.className);
    return m ? m[1] : "large";
  };

  K.on = (fn) => {
    let heard = false, last = null;
    const take = (data) => {
      if (!data || typeof data !== "object") return;
      heard = true;
      last = data;
      if (data.theme) K.theme(data.theme);
      try { fn(data); } catch (e) { console.error("widget:", e); }
      K.ends();
    };
    addEventListener("pilotdata", (e) => take(e.detail));
    addEventListener("pilotsize", () => { if (last) take(last); });
    fetch("/__pilot/data").then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (!heard && d && Object.keys(d).length) take(d); }).catch(() => {});
  };

  // A .pk-fade list fades its foot only while there is more below.
  K.ends = () => document.querySelectorAll(".pk-fade").forEach((el) =>
    el.classList.toggle("pk-end", el.scrollTop + el.clientHeight >= el.scrollHeight - 2));
  addEventListener("scroll", (e) => { if (e.target.classList && e.target.classList.contains("pk-fade")) K.ends(); }, true);

  K.height = () => {
    const pk = document.querySelector(".pk");
    if (!pk) return 0;
    const grows = [...pk.querySelectorAll(".pk-grow")];
    pk.style.height = "auto";
    grows.forEach((g) => { g.style.flex = "none"; });
    const h = pk.getBoundingClientRect().height;
    pk.style.height = "";
    grows.forEach((g) => { g.style.flex = ""; });
    return Math.ceil(h);
  };

  const num = (n) => (typeof n === "number" && isFinite(n) ? n : null);
  K.num = num;

  // Used share: quiet, amber from 75, red from 90. Left share: red to 15, amber to 40.
  K.tone = (used) => (num(used) == null ? "" : used >= 90 ? "is-alert" : used >= 75 ? "is-warn" : "");
  K.toneLeft = (left) => (num(left) == null ? "" : left <= 15 ? "is-alert" : left <= 40 ? "is-warn" : "");

  K.meter = (percent, opts) => {
    const o = opts || {};
    const v = num(percent) == null ? 0 : Math.max(0, Math.min(100, percent));
    const mark = num(o.mark) == null ? "" : `<s style="--m:${Math.max(0, Math.min(100, o.mark))}"></s>`;
    return `<div class="pk-meter ${o.tone || ""}" style="--v:${v}"><i></i>${mark}</div>`;
  };

  // A line over a soft area, scaled to its values; `now` (an index) puts a dot on that point.
  K.spark = (values, opts) => {
    const o = opts || {};
    const w = o.width || 240, h = o.height || 36, pad = 3;
    const vs = (values || []).map(num);
    const known = vs.filter((v) => v != null);
    if (known.length < 2) return `<svg class="pk-spark" viewBox="0 0 ${w} ${h}" height="${h}"></svg>`;
    const lo = o.min != null ? o.min : Math.min(...known), hi = o.max != null ? o.max : Math.max(...known);
    const span = hi - lo || 1;
    const x = (i) => (i / (vs.length - 1)) * w;
    const y = (v) => pad + (1 - (v - lo) / span) * (h - pad * 2);
    let line = "", first = null, last = null;
    vs.forEach((v, i) => {
      if (v == null) return;
      line += `${line ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`;
      if (first == null) first = i;
      last = i;
    });
    const area = `${line}L${x(last).toFixed(1)},${h}L${x(first).toFixed(1)},${h}Z`;
    const dot = o.now != null && vs[o.now] != null ? `<circle class="pk-now" cx="${x(o.now).toFixed(1)}" cy="${y(vs[o.now]).toFixed(1)}" r="2.5"/>` : "";
    return `<svg class="pk-spark" viewBox="0 0 ${w} ${h}" height="${h}" preserveAspectRatio="none"><path class="pk-area" d="${area}"/><path class="pk-line" d="${line}"/>${dot}</svg>`;
  };

  // Line glyphs on a 24 grid.
  const paths = {
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4"/>',
    moon: '<path d="M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z"/>',
    partly: '<path d="M8.5 3.8v1.4M3.6 8.7h1.4M5 5.2l1 1M12 5.2l-1 1"/><path d="M5.8 11.4a3.6 3.6 0 1 1 6.3-3.2"/><path d="M8.5 19.5h9a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2 2.9 2.9 0 0 0 .3 5.8z"/>',
    partlyNight: '<path d="M12.6 8.2a4.3 4.3 0 0 1-5.8-4.3 4.6 4.6 0 1 0 5.8 4.3z"/><path d="M8.5 19.5h9a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2 2.9 2.9 0 0 0 .3 5.8z"/>',
    cloud: '<path d="M7 18.5h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 18.5z"/>',
    fog: '<path d="M4 9h16M6 13h12M4 17h16"/>',
    drizzle: '<path d="M7 14.5h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 14.5z"/><path d="M9 18v.5M13 18v.5M17 18v.5M11 21v.5M15 21v.5"/>',
    rain: '<path d="M7 14.5h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 14.5z"/><path d="M9 17.5l-1 3M13 17.5l-1 3M17 17.5l-1 3"/>',
    snow: '<path d="M7 14.5h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 14.5z"/><path d="M9 18.5h.01M13 18.5h.01M17 18.5h.01M11 21.5h.01M15 21.5h.01" stroke-width="2.4"/>',
    storm: '<path d="M7 14.5h10.5a4 4 0 0 0 .4-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 14.5z"/><path d="M12.5 15.5l-2 3.5h3l-2 3.5"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15" rx="2.5"/><path d="M3.5 9.5h17M8 3v4M16 3v4"/>',
    check: '<circle cx="12" cy="12" r="8.5"/><path d="M8.5 12.2l2.4 2.3 4.6-4.8"/>',
    lock: '<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
    gauge: '<path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="M12 13l3.5-4"/>',
    globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.6 2.5 14.4 0 17M12 3.5c-2.5 2.6-2.5 14.4 0 17"/>',
    wind: '<path d="M3 9h11a2.5 2.5 0 1 0-2.5-2.5M3 13h15a2.5 2.5 0 1 1-2.5 2.5M3 17h7"/>',
    drop: '<path d="M12 3.5c3 4 5.5 6.8 5.5 10a5.5 5.5 0 0 1-11 0c0-3.2 2.5-6 5.5-10z"/>',
  };
  K.icon = (name, cls) => `<svg class="pk-glyph ${cls || ""}" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.cloud}</svg>`;

  // Open-Meteo's WMO weather codes.
  K.weather = (code, isDay) => {
    const day = isDay !== false;
    const c = num(code);
    if (c == null) return { words: "–", icon: "cloud" };
    if (c === 0) return { words: day ? "Clear" : "Clear night", icon: day ? "sun" : "moon" };
    if (c <= 2) return { words: c === 1 ? "Mainly clear" : "Partly cloudy", icon: day ? "partly" : "partlyNight" };
    if (c === 3) return { words: "Overcast", icon: "cloud" };
    if (c <= 48) return { words: "Fog", icon: "fog" };
    if (c <= 57) return { words: "Drizzle", icon: "drizzle" };
    if (c <= 67 || (c >= 80 && c <= 82)) return { words: c >= 80 ? "Showers" : "Rain", icon: "rain" };
    if (c <= 77 || c === 85 || c === 86) return { words: "Snow", icon: "snow" };
    if (c >= 95) return { words: "Thunderstorm", icon: "storm" };
    return { words: "Cloudy", icon: "cloud" };
  };
})();
