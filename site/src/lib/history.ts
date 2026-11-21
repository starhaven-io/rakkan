import type { Snapshot } from './d1.ts';
import { percentage } from './format.ts';

export function adoptionTrend(newestFirst: readonly Snapshot[]) {
  if (newestFirst.length < 2) return null;

  const observations = newestFirst.toReversed().map((snapshot) => ({
    date: snapshot.taken_on,
    time: Date.parse(snapshot.taken_on),
    rate: percentage(snapshot.provenant_packages, snapshot.tracked_packages),
  }));
  const first = observations[0];
  const last = observations[observations.length - 1];
  const rates = observations.map((observation) => observation.rate);
  const lower = Math.min(99, Math.floor(Math.min(...rates)));
  const upper = Math.max(lower + 1, Math.ceil(Math.max(...rates)));
  const points = observations
    .map(({ time, rate }) => {
      const x = ((time - first.time) * 100) / (last.time - first.time);
      const y = ((upper - rate) * 100) / (upper - lower);
      return `${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(' ');
  const previous = observations[observations.length - 2];
  const delta = (Math.round(last.rate * 10) - Math.round(previous.rate * 10)) / 10;
  return { first, last, previous, delta, lower, upper, points };
}
