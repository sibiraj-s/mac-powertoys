import { links } from '../links';
import type { Release } from '../useLatestRelease';
import { DownloadIcon } from './Icons';
import { Screen } from './Screen';

export function Hero({ release }: { release: Release }) {
  return (
    <section id="top" className="hero">
      <div className="container hero__grid">
        <div className="hero__text">
          <h1>twenty mac tools in one app</h1>
          <p className="lead">Turn on the tools you need; each asks for access only then.</p>
          <div className="hero__actions">
            <a href={release.downloadURL} className="btn btn--primary">
              <DownloadIcon className="icon" />
              download for mac
            </a>
            <a href={links.repo} className="btn btn--secondary">
              view source
            </a>
          </div>
          <p className="hero__meta">
            Version {release.version}, free and open source.
            <br />
            macOS 15 or later on Apple silicon.
          </p>
        </div>
        <Screen
          slot="hero"
          src="overview.png"
          alt="The PowerToys window: a sidebar of modules grouped by kind, and the Overview page with a switch for each module"
          priority
          className="hero__screen"
        />
      </div>
    </section>
  );
}
