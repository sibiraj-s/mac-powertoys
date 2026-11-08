import { useRef, useState, type KeyboardEvent } from 'react';
import { moduleGroups } from '../modules';

const modules = moduleGroups.flatMap((group) => group.modules);

/// The page works like the app: a sidebar of every module in its group, and what the
/// selected module does beside it. Arrow keys move through the list, as in the app's sidebar.
export function ModuleBrowser() {
  const [selectedID, setSelectedID] = useState('window-switcher');
  const tabs = useRef(new Map<string, HTMLButtonElement>());
  const selected = modules.find((m) => m.id === selectedID) ?? modules[0];

  const onKeyDown = (event: KeyboardEvent) => {
    const step = { ArrowDown: 1, ArrowUp: -1 }[event.key];
    const index = modules.findIndex((m) => m.id === selectedID);
    let next: number | undefined;
    if (step) next = (index + step + modules.length) % modules.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = modules.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    const id = modules[next].id;
    setSelectedID(id);
    tabs.current.get(id)?.focus();
  };

  return (
    <section id="modules" className="browser">
      <div className="container">
        <div className="browser__head">
          <h2>twenty tools, one sidebar</h2>
          <p className="lead">Pick one to see what it does.</p>
        </div>
        <div className="browser__grid">
          <div
            role="tablist"
            aria-orientation="vertical"
            aria-label="Modules"
            className="browser__list"
            onKeyDown={onKeyDown}
          >
            {moduleGroups.map((group) => (
              <div key={group.name} role="presentation" className="browser__group">
                <span role="presentation" className="browser__group-name">
                  {group.name}
                </span>
                {group.modules.map((module) => {
                  const isSelected = module.id === selected.id;
                  return (
                    <button
                      key={module.id}
                      ref={(el) => {
                        if (el) tabs.current.set(module.id, el);
                        else tabs.current.delete(module.id);
                      }}
                      type="button"
                      role="tab"
                      id={`tab-${module.id}`}
                      aria-selected={isSelected}
                      aria-controls="module-panel"
                      tabIndex={isSelected ? 0 : -1}
                      className="browser__tab"
                      onClick={() => setSelectedID(module.id)}
                    >
                      {module.name.toLowerCase()}
                    </button>
                  );
                })}
              </div>
            ))}
          </div>
          <div
            role="tabpanel"
            id="module-panel"
            aria-labelledby={`tab-${selected.id}`}
            className="browser__panel"
          >
            <h3>{selected.name.toLowerCase()}</h3>
            <p className="lead">{selected.summary}</p>
          </div>
        </div>
      </div>
    </section>
  );
}
