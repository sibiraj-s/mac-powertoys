import { useState } from 'react';

/// A screenshot of the app in a slot. Until its file exists (or if it fails to load) the slot
/// keeps its size and shows its wash, so a missing screenshot never shifts the layout.
export function Screen({
  slot,
  src,
  alt,
  priority = false,
  className = '',
}: {
  slot: string;
  src?: string;
  alt: string;
  priority?: boolean;
  className?: string;
}) {
  const [failed, setFailed] = useState<string>();
  const url = src ? `${import.meta.env.BASE_URL}screens/${src}` : undefined;

  return (
    <figure className={`screen ${className}`} data-slot={slot} data-kind="product" data-alt={alt}>
      {url && failed !== url && (
        <img
          src={url}
          width={2000}
          height={1506}
          alt={alt}
          fetchPriority={priority ? 'high' : undefined}
          loading={priority ? undefined : 'lazy'}
          onError={() => setFailed(url)}
        />
      )}
    </figure>
  );
}
