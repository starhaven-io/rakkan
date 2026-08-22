-- RubyGems observations follow the registry's Monday weekly dump cadence.
-- Keep the latest scan in each week and label it with that Monday.
CREATE TEMP TABLE rubygems_weekly_snapshots AS
WITH ranked AS (
  SELECT
    adoption_snapshots.*,
    date(
      taken_on,
      '-' || ((CAST(strftime('%w', taken_on) AS INTEGER) + 6) % 7) || ' days'
    ) AS week_started_on,
    row_number() OVER (
      PARTITION BY
        registry_id,
        date(
          taken_on,
          '-' || ((CAST(strftime('%w', taken_on) AS INTEGER) + 6) % 7) || ' days'
        )
      ORDER BY taken_on DESC, adoption_snapshots.id DESC
    ) AS week_position
  FROM adoption_snapshots
  INNER JOIN registries ON registries.id = adoption_snapshots.registry_id
  WHERE registries.name = 'rubygems'
)
SELECT
  id,
  registry_id,
  week_started_on AS taken_on,
  tracked_packages,
  provenant_packages,
  tracked_versions,
  provenant_versions,
  created_at
FROM ranked
WHERE week_position = 1;

DELETE FROM adoption_snapshots
WHERE registry_id = (SELECT id FROM registries WHERE name = 'rubygems');

INSERT INTO adoption_snapshots (
  id,
  registry_id,
  taken_on,
  tracked_packages,
  provenant_packages,
  tracked_versions,
  provenant_versions,
  created_at
)
SELECT
  id,
  registry_id,
  taken_on,
  tracked_packages,
  provenant_packages,
  tracked_versions,
  provenant_versions,
  created_at
FROM rubygems_weekly_snapshots;

DROP TABLE rubygems_weekly_snapshots;
