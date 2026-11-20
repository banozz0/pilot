// A form made by `pilot ext new --mode form`: fields by id, and a submit action handed their values. Replace the fields
// and `submit` with what the command should ask and do.
import { Action, ActionPanel, Clipboard, Form, showHUD } from "@raycast/api";

type Values = { name: string; note: string };

async function submit(values: Values) {
  await Clipboard.copy(`${values.name}: ${values.note}`);
  await showHUD(`Copied the note for ${values.name}`);
}

export default function Command() {
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Copy Note" onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="name" title="Name" placeholder="Who it is for" />
      <Form.TextArea id="note" title="Note" placeholder="What to say" />
    </Form>
  );
}
