export const REGISTRY_SLUGS = ['rubygems', 'cratesio'] as const;

export type RegistrySlug = (typeof REGISTRY_SLUGS)[number];

export interface RegistrySite {
  slug: RegistrySlug;
  overviewPath: string;
  packagesPath: string;
  searchPath: string;
  packagePath(name: string): string;
  packageUrl(name: string): string;
  adoptionDescription(noun: string): string;
  historyDescription: string;
  releaseDescription: string;
}

const sites: Record<RegistrySlug, RegistrySite> = {
  rubygems: {
    slug: 'rubygems',
    overviewPath: '/',
    packagesPath: '/packages',
    searchPath: '/search',
    packagePath: (name) => `/packages/${encodeURIComponent(name)}`,
    packageUrl: (name) => `https://rubygems.org/gems/${encodeURIComponent(name)}`,
    adoptionDescription: (noun) =>
      `Attestation presence is a lower bound: a ${noun} can be pushed by a trusted publisher without attestations.`,
    historyDescription: 'One observation per weekly dump.',
    releaseDescription: 'Certificate-derived build identity per recorded version.',
  },
  cratesio: {
    slug: 'cratesio',
    overviewPath: '/cratesio',
    packagesPath: '/cratesio/packages',
    searchPath: '/cratesio/search',
    packagePath: (name) => `/cratesio/packages/${encodeURIComponent(name)}`,
    packageUrl: (name) => `https://crates.io/crates/${encodeURIComponent(name)}`,
    adoptionDescription: (noun) =>
      `A ${noun} counts as adopted when at least one tracked release reports trusted-publisher metadata from crates.io.`,
    historyDescription: 'Observations are dated to the crates.io dump behind each tracked-set refresh.',
    releaseDescription: 'Trusted-publisher metadata per recorded version.',
  },
};

export function registrySite(slug: RegistrySlug): RegistrySite {
  return sites[slug];
}

export function registrySlugForPath(pathname: string): RegistrySlug {
  return pathname === '/cratesio' || pathname.startsWith('/cratesio/') ? 'cratesio' : 'rubygems';
}
