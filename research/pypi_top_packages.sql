-- Reproducible PyPI tracked set: 30 complete UTC days ending at @as_of.
--
-- Example:
--   bq query --use_legacy_sql=false --format=csv --max_rows=1000 \
--     --parameter=as_of:DATE:2026-08-20 \
--     < research/pypi_top_packages.sql > top_pypi.csv

WITH download_totals AS (
  SELECT
    REGEXP_REPLACE(LOWER(file.project), r'[-_.]+', '-') AS name,
    COUNT(*) AS downloads
  FROM `bigquery-public-data.pypi.file_downloads`
  WHERE DATE(timestamp) >= DATE_SUB(@as_of, INTERVAL 30 DAY)
    AND DATE(timestamp) < @as_of
    AND file.project IS NOT NULL
    AND details.installer.name = 'pip'
  GROUP BY name
),
ranked AS (
  SELECT
    ROW_NUMBER() OVER (ORDER BY downloads DESC, name) AS rank,
    name,
    downloads
  FROM download_totals
)
SELECT rank, name, downloads
FROM ranked
WHERE rank <= 1000
ORDER BY rank;
