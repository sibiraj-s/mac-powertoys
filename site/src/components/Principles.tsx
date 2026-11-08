const rows: { title: string; body: string }[] = [
  {
    title: 'a switch for each tool',
    body: 'Each module turns on separately. The rest stay off.',
  },
  {
    title: 'access only when needed',
    body: 'Permissions are asked for when a tool needs them.',
  },
  {
    title: 'no shortcuts taken',
    body: 'No global shortcut is taken until you assign one.',
  },
  {
    title: 'in the menu bar',
    body: 'Closing the window keeps every tool running there.',
  },
  {
    title: 'stays on this mac',
    body: 'Clipboard history and recognized text never leave it.',
  },
];

export function Principles() {
  return (
    <section className="principles">
      <div className="container principles__grid">
        <h2>off until you turn it on</h2>
        <dl className="principles__rows">
          {rows.map(({ title, body }) => (
            <div key={title} className="principles__row">
              <dt>{title}</dt>
              <dd>{body}</dd>
            </div>
          ))}
        </dl>
      </div>
    </section>
  );
}
