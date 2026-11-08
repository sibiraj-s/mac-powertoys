import { useEffect, useState } from 'react';
import { version as builtVersion } from '../../package.json';
import { links } from './links';

export type Release = { version: string; downloadURL: string };

type GitHubRelease = {
  tag_name?: string;
  assets?: { name: string; browser_download_url: string }[];
};

/// The version comes from package.json at build time. The GitHub API then supplies the
/// latest DMG's direct link; until it answers, or if it's unreachable or rate limited,
/// the button points at the Releases page.
export function useLatestRelease(): Release {
  const [release, setRelease] = useState<Release>({
    version: builtVersion,
    downloadURL: links.latestRelease,
  });

  useEffect(() => {
    const controller = new AbortController();
    fetch(links.latestReleaseApi, { signal: controller.signal })
      .then((res) => (res.ok ? (res.json() as Promise<GitHubRelease>) : null))
      .then((data) => {
        const dmg = data?.assets?.find((a) => /\.dmg$/i.test(a.name));
        if (!data || !dmg) return;
        setRelease({
          version: data.tag_name?.replace(/^v/, '') ?? builtVersion,
          downloadURL: dmg.browser_download_url,
        });
      })
      .catch(() => {});
    return () => controller.abort();
  }, []);

  return release;
}
