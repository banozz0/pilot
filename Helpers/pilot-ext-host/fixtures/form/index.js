"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. Title is controlled and echoes each change at once; its onBlur sets an error while it is
// empty, and its onChange clears it, the docs' own validation pattern. Slow is controlled too but echoes each change
// 40 ms later, so a change Pilot sends before the echo of the one before arrives must not be lost. Notes, Urgent,
// Priority, Due and Files are uncontrolled. Submit pushes a Detail naming each value's type and value.
const { useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { Action, ActionPanel, Detail, Form, useNavigation } = require("@raycast/api");

function shown(value) {
  if (value instanceof Date) return `Date ${value.toISOString()}`;
  if (Array.isArray(value)) return `array ${JSON.stringify(value)}`;
  if (value === null) return "null";
  return `${typeof value} ${JSON.stringify(value)}`;
}

function Submitted({ values }) {
  const lines = Object.keys(values).sort().map((key) => `- ${key}: ${shown(values[key])}`);
  return jsx(Detail, { markdown: `# Submitted\n${lines.join("\n")}` });
}

function Command() {
  const { push } = useNavigation();
  const [title, setTitle] = useState("");
  const [titleError, setTitleError] = useState(undefined);
  const [slow, setSlow] = useState("");
  return jsxs(Form, {
    actions: jsx(ActionPanel, {
      children: jsx(Action.SubmitForm, { title: "Save entry", onSubmit: (values) => push(jsx(Submitted, { values })) }),
    }),
    children: [
      jsx(Form.Description, { title: "About", text: "One of each field." }, "about"),
      jsx(Form.TextField, {
        id: "title", title: "Title", placeholder: "Name it", value: title, error: titleError,
        onChange: (v) => { setTitle(v); if (v) setTitleError(undefined); },
        onBlur: (event) => { if (!event.target.value) setTitleError("Title is required"); },
      }, "title"),
      jsx(Form.TextField, {
        id: "slow", title: "Slow", info: "Echoes each change 40 ms later", value: slow,
        onChange: (v) => { setTimeout(() => setSlow(v), 40); },
      }, "slow"),
      jsx(Form.TextArea, { id: "notes", title: "Notes", defaultValue: "first line" }, "notes"),
      jsx(Form.Separator, {}, "sep"),
      jsx(Form.Checkbox, { id: "urgent", title: "Flags", label: "Urgent" }, "urgent"),
      jsxs(Form.Dropdown, {
        id: "priority", title: "Priority", defaultValue: "low",
        children: [
          jsxs(Form.Dropdown.Section, { title: "Levels", children: [
            jsx(Form.Dropdown.Item, { value: "low", title: "Low" }, "low"),
            jsx(Form.Dropdown.Item, { value: "high", title: "High" }, "high"),
          ] }, "levels"),
        ],
      }, "priority"),
      jsx(Form.DatePicker, { id: "due", title: "Due", type: Form.DatePicker.Type.Date }, "due"),
      jsx(Form.FilePicker, { id: "files", title: "Files", allowMultipleSelection: true }, "files"),
    ],
  });
}

module.exports = { default: Command };
