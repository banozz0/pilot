// Raycast's Form (T10), written from developers.raycast.com's Form and Actions pages (read 2026-11-20): each item is a
// host element, turned into a field of Pilot's `form` answer, which Pilot draws with its own controls. A field's value
// goes out as the wire has it (a date as ISO text or null, a file pick as paths, a checkbox as true or false). Every
// field carries a `change` handler, `<serial>.change`, which Pilot presses with the new value as the user edits; an
// uncontrolled field (no `value` prop) keeps it on its host element, so the form shows it and a submit hands it on, and
// a controlled one is handed it through its `onChange`, the extension deciding what it shows. A field with an `onBlur`
// also carries `<serial>.blur`, pressed as the user leaves it. `Action.SubmitForm` is `<serial>.submit`: it collects
// every field's value by its id, in Raycast's types, and calls `onSubmit` with them, unless a field shows an error,
// since Raycast's docs say then "the Action.SubmitForm onSubmit callback won't be triggered".
import { record } from "./gaps.js";

/** Each item's kind on the wire, by its host element's name. */
const kinds = {
  "Form.TextField": "text", "Form.PasswordField": "password", "Form.TextArea": "textarea", "Form.Checkbox": "checkbox",
  "Form.DatePicker": "date", "Form.Dropdown": "dropdown", "Form.FilePicker": "file",
};

/** A field's value when it has none given: Raycast's empty value of its type, a dropdown's first option. */
function empty(node) {
  switch (kinds[node.type]) {
    case "checkbox": return false;
    case "date": return null;
    case "file": return [];
    case "dropdown": return options(node.children)[0]?.value ?? "";
    default: return "";
  }
}

/** A field's value as the form shows it now: its `value` prop when controlled, else what Pilot last sent it, else its
 *  `defaultValue`, else its empty value. */
function current(node) {
  const p = node.props;
  if (p.value !== undefined) return p.value;
  if ("draft" in node) return node.draft;
  return p.defaultValue !== undefined ? p.defaultValue : empty(node);
}

/** A value from the wire in the field's Raycast type: text, a boolean, a Date or null, a list of paths. */
function typed(node, value) {
  switch (kinds[node.type]) {
    case "checkbox": return value === true;
    case "date": {
      if (value == null || value === "") return null;
      const date = new Date(value);
      return Number.isNaN(date.getTime()) ? null : date;
    }
    case "file": return Array.isArray(value) ? value.filter((v) => typeof v === "string") : [];
    default: return value == null ? "" : String(value);
  }
}

/** A Raycast value as the wire carries it. */
function wire(node, value) {
  switch (kinds[node.type]) {
    case "checkbox": return value === true;
    case "date": return value instanceof Date && !Number.isNaN(value.getTime()) ? value.toISOString() : null;
    case "file": return Array.isArray(value) ? value.map(String) : [];
    default: return value == null ? "" : String(value);
  }
}

/** A dropdown's items, sections flattened, each with its section's title. */
function options(nodes, section, out = []) {
  for (const node of nodes) {
    if (node.type === "Form.Dropdown.Item") {
      const option = { value: String(node.props.value ?? ""), title: String(node.props.title ?? node.props.value ?? "") };
      if (section) option.section = section;
      out.push(option);
    } else if (node.type === "Form.Dropdown.Section") options(node.children, node.props.title ? String(node.props.title) : section, out);
  }
  return out;
}

/** Every field of the form under `nodes`, depth first, in order (a fragment's or a component's items included). */
function fields(nodes, out = []) {
  for (const node of nodes) {
    if (kinds[node.type] || node.type === "Form.Separator" || node.type === "Form.Description") out.push(node);
    else if (node.children && !node.type?.startsWith("Form.Dropdown") && node.type !== "ActionPanel") fields(node.children, out);
  }
  return out;
}

const text = (value) => (typeof value === "string" && value ? value : undefined);

/** One field on the wire, its handlers entered in `handlers`. */
function field(node, handlers) {
  if (node.type === "Form.Separator") return { kind: "separator" };
  const p = node.props;
  if (node.type === "Form.Description") return { kind: "description", title: text(p.title), text: String(p.text ?? "") };
  const kind = kinds[node.type], out = { id: String(p.id ?? ""), kind, title: text(p.title), value: wire(node, current(node)) };
  out.change = `${node.serial}.change`;
  handlers.set(out.change, node);
  if (typeof p.onBlur === "function") {
    out.blur = `${node.serial}.blur`;
    handlers.set(out.blur, node);
  }
  for (const key of ["placeholder", "error", "info"]) if (text(p[key])) out[key] = p[key];
  if (p.autoFocus === true) out.autoFocus = true;
  if (p.storeValue === true) record("Form storeValue");
  if (kind === "checkbox" && text(p.label)) out.label = p.label;
  if (kind === "dropdown") out.options = options(node.children);
  if (kind === "date") {
    // DateTime is the docs' default.
    out.time = p.type !== "date";
    for (const key of ["min", "max"]) if (p[key] instanceof Date) out[key] = p[key].toISOString();
  }
  if (kind === "file") {
    out.multiple = p.allowMultipleSelection !== false;
    out.files = p.canChooseFiles !== false;
    out.folders = p.canChooseDirectories === true;
    if (p.showHiddenFiles === true) out.hidden = true;
  }
  return out;
}

/** The Form `root` as Pilot's form answer; its actions come from `actions` (host.js), SubmitForm's among them. */
export function formAnswer(root, handlers, actions) {
  if (root.props.enableDrafts === true) record("Form enableDrafts");
  const answer = { type: "form", fields: fields(root.children).map((node) => field(node, handlers)), actions: actions(root.children, handlers) };
  if (root.props.isLoading === true) answer.isLoading = true;
  return answer;
}

/** Why a submit did not run: the first field showing an error, as Raycast blocks it then. */
function blocked(form) {
  const shown = fields(form.children).find((node) => kinds[node.type] && text(node.props.error));
  return shown ? `${text(shown.props.title) ?? shown.props.id} shows an error: ${shown.props.error}` : undefined;
}

/** The press `word` on a form's `node` with the wire's `value`, as a callback for host.js's request: a field's change or
 *  blur, or a SubmitForm's submit with every field's value of the form `form`. Nil when `word` is not a form press. */
export function formPress(word, node, value, form) {
  const part = word.split(".").pop();
  if (kinds[node?.type] && part === "change") {
    return () => {
      const next = typed(node, value);
      // An uncontrolled field keeps it: the answer to this press (host.js's request) shows it.
      if (node.props.value === undefined) node.draft = next;
      return typeof node.props.onChange === "function" ? node.props.onChange(next) : undefined;
    };
  }
  if (kinds[node?.type] && part === "blur") {
    return () => node.props.onBlur?.({ target: { id: String(node.props.id ?? ""), value: current(node) }, type: "blur" });
  }
  if (node?.type === "Action.SubmitForm" && part === "submit") {
    return () => {
      if (!form) return console.error("a SubmitForm outside a Form: nothing to submit");
      const why = blocked(form);
      if (why) return console.error(`not submitted: ${why}`);
      if (typeof node.props.onSubmit !== "function") return undefined;
      const values = {};
      for (const item of fields(form.children)) if (kinds[item.type]) values[String(item.props.id ?? "")] = current(item);
      return node.props.onSubmit(values);
    };
  }
  return undefined;
}
