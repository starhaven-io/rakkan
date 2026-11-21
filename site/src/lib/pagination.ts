export const MAX_PAGE = 1_000;
export const PACKAGE_PAGE_SIZE = 100;
export const VERSION_PAGE_SIZE = 100;
export const SEARCH_PAGE_SIZE = 50;

export function parsePage(value: string | null): number {
  if (!value || !/^\d+$/.test(value)) return 1;
  const page = Number(value);
  if (!Number.isSafeInteger(page) || page < 1) return 1;
  return Math.min(page, MAX_PAGE);
}

export function clampPage(requested: number, total: number, pageSize: number): { page: number; pageCount: number } {
  const pageCount = Math.max(1, Math.ceil(total / pageSize));
  return { page: Math.min(Math.max(1, requested), pageCount), pageCount };
}

export function pageHref(path: string, page: number, query?: URLSearchParams): string {
  const params = new URLSearchParams(query);
  if (page > 1) params.set('page', String(page));
  else params.delete('page');
  const search = params.toString();
  return search ? `${path}?${search}` : path;
}

export function canonicalPageRedirect(path: string, requestedPage: number, actualPage: number): string | null {
  return requestedPage === actualPage ? null : pageHref(path, actualPage);
}
