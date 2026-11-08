import { useEffect } from 'react';
import { Footer } from './components/Footer';
import { Hero } from './components/Hero';
import { Install } from './components/Install';
import { ModuleBrowser } from './components/ModuleBrowser';
import { Nav } from './components/Nav';
import { Principles } from './components/Principles';
import { useLatestRelease } from './useLatestRelease';

export default function App() {
  const release = useLatestRelease();

  // The page renders after load, so the browser can't scroll to a #fragment by itself.
  useEffect(() => {
    const target = location.hash
      ? document.getElementById(decodeURIComponent(location.hash.slice(1)))
      : null;
    target?.scrollIntoView();
  }, []);

  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <Nav />
      <main id="main">
        <Hero release={release} />
        <ModuleBrowser />
        <Principles />
        <Install release={release} />
      </main>
      <Footer />
    </>
  );
}
