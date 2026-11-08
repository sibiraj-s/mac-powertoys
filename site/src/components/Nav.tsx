import { links } from '../links';
import { GitHubIcon, appIcon } from './Icons';

export function Nav() {
  return (
    <header className="nav">
      <nav aria-label="Main" className="nav__pill">
        <a href="#top" className="nav__mark" aria-label="PowerToys, back to top">
          <img src={appIcon} alt="" width={28} height={28} />
          powertoys
        </a>
        <a href="#modules" className="nav__link">
          modules
        </a>
        <a href="#install" className="nav__link">
          install
        </a>
        <a href={links.repo} className="nav__link nav__github">
          <GitHubIcon className="icon" />
          github
        </a>
      </nav>
    </header>
  );
}
