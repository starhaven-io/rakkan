export function formatCount(value: number | null | undefined): string {
  return (value ?? 0).toLocaleString('en-US');
}

/**
 * Matches Ruby's Float#round semantics (which round the shortest decimal
 * representation, so 2.55 -> 2.6): nudge by one ULP before Math.round so
 * binary just-under-halfway values round like their decimal reading.
 */
export function percentage(part: number, whole: number, precision = 1): number {
  if (!whole) return 0.0;
  const ratio = (part * 100) / whole;
  const factor = 10 ** precision;
  return Math.round(ratio * (1 + Number.EPSILON) * factor) / factor;
}

/** Escape LIKE metacharacters so user input never acts as a wildcard. */
export function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (m) => `\\${m}`);
}

/** Exported timestamps are UTC text ("2026-08-14 17:01:13.653..."). */
function parseUtc(value: string): Date {
  return new Date(`${value.replace(' ', 'T').replace(/(\.\d+)?$/, '')}Z`);
}

/** "2026-08-15 03:19 UTC" from an exporter timestamp, for freshness notes. */
export function utcStamp(value: string | null | undefined): string | null {
  if (!value) return null;
  const date = parseUtc(value);
  if (Number.isNaN(date.getTime())) return null;
  return `${date.toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

/** "Aug 14, 2026" from a D1 timestamp or date string. */
export function shortDate(value: string | null | undefined): string {
  if (!value) return '';
  const date = value.length === 10 ? new Date(`${value}T00:00:00Z`) : parseUtc(value);
  return date.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC',
  });
}

/** Package noun per registry slug. */
export function packageNoun(registryName: string | undefined, count = 1): string {
  const singular = registryName === 'rubygems' ? 'gem' : registryName === 'cratesio' ? 'crate' : 'package';
  return count === 1 ? singular : `${singular}s`;
}

export function searchResultSummary(
  registryName: string | undefined,
  registryDisplayName: string | undefined,
  count: number,
): string {
  return `${count} tracked ${packageNoun(registryName, count)} matched in ${registryDisplayName ?? 'the active registry'}.`;
}

/** Registry-neutral display name for each stored provenance kind. */
export function provenanceLabel(kind: string | null): string {
  if (kind === 'sigstore_attestation') return 'Sigstore';
  if (kind === 'trustpub_metadata') return 'Trusted publisher';
  if (kind === 'digital_attestation') return 'Digital attestation';
  return 'Provenance';
}

/** "owner/repo" from a repository URL, for link text. */
export function repositoryLabel(url: string): string {
  try {
    return new URL(url).pathname.replace(/^\//, '').replace(/\.git$/, '');
  } catch {
    return url;
  }
}

/** Only absolute https URLs with a host and no userinfo become links. */
export function safeHttpsUrl(value: string | null | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) return null;
    return value;
  } catch {
    return null;
  }
}
