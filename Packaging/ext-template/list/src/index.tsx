// A list made by `pilot ext new --mode list`: each row a title and a subtitle, filtered as you type; Return runs the
// row's first action. Replace `rows` with what the command should list.
import { Action, ActionPanel, Icon, List } from "@raycast/api";

type Row = { title: string; subtitle: string };

const rows: Row[] = [
  { title: "Alpha", subtitle: "the first row" },
  { title: "Beta", subtitle: "the second row" },
  { title: "Gamma", subtitle: "the third row" },
];

export default function Command() {
  return (
    <List searchBarPlaceholder="Filter the rows">
      {rows.map((row) => (
        <List.Item
          key={row.title}
          icon={Icon.Dot}
          title={row.title}
          subtitle={row.subtitle}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard title="Copy Title" content={row.title} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
