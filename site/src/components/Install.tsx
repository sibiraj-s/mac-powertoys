import type { Release } from '../useLatestRelease';
import { DownloadIcon } from './Icons';

export function Install({ release }: { release: Release }) {
  return (
    <section id="install" className="install">
      <div className="container install__band">
        <div className="install__text">
          <h2>free and open source</h2>
          <p className="lead">macOS 15 or later on Apple silicon, under the MIT license.</p>
        </div>
        <a href={release.downloadURL} className="btn btn--on-accent">
          <DownloadIcon className="icon" />
          download for mac
        </a>
      </div>
    </section>
  );
}
