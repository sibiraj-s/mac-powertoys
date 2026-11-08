import { links } from '../links';

export function Footer() {
  return (
    <footer className="footer">
      <div className="container">
        <p className="footer__statement">built in swift, for the mac.</p>
        <nav aria-label="Footer" className="footer__links">
          {[
            ['GitHub', links.repo],
            ['Releases', links.releases],
            ['Changelog', links.changelog],
            ['Report an issue', links.issues],
          ].map(([label, href]) => (
            <a key={label} href={href}>
              {label}
            </a>
          ))}
        </nav>
        <p className="footer__legal">© {new Date().getFullYear()} Sibiraj. MIT License.</p>
      </div>
    </footer>
  );
}
