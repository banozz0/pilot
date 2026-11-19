"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. Its first commit is a loading list with one row; 300 ms later its data arrives as a second
// commit, so `pilot ext run` showing the planets proves the later answer reached Pilot.
const { useEffect, useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

const planets = [
  { id: "mercury", title: "Mercury", subtitle: "0.39 AU", section: "Inner", moons: 0 },
  { id: "venus", title: "Venus", subtitle: "0.72 AU", section: "Inner", moons: 0 },
  { id: "jupiter", title: "Jupiter", subtitle: "5.2 AU", section: "Outer", moons: 95 },
  { id: "saturn", title: "Saturn", subtitle: "9.5 AU", section: "Outer", moons: 274 },
];

function Command() {
  const [data, setData] = useState(null);
  useEffect(() => {
    const timer = setTimeout(() => setData(planets), 300);
    return () => clearTimeout(timer);
  }, []);
  if (!data) return jsx(List, { isLoading: true, children: jsx(List.Item, { title: "Waiting for the planets" }) });
  const section = (name) => jsx(List.Section, {
    title: name,
    children: data.filter((p) => p.section === name).map((p) => jsx(List.Item, {
      id: p.id, title: p.title, subtitle: p.subtitle, keywords: [p.section.toLowerCase()],
      accessories: [{ text: `${p.moons} moons` }],
    }, p.id)),
  });
  return jsxs(List, { children: [section("Inner"), section("Outer")] });
}

module.exports = { default: Command };
