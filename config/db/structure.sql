CREATE TABLE `schema_migrations`(`filename` varchar(255) NOT NULL PRIMARY KEY);
CREATE TABLE `registries`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `name` varchar(255) NOT NULL UNIQUE,
  `display_name` varchar(255) NOT NULL,
  `url` varchar(255) NOT NULL,
  `created_at` timestamp NOT NULL,
  `updated_at` timestamp NOT NULL,
  `feed_synced_at` timestamp
);
CREATE TABLE `packages`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `registry_id` integer NOT NULL REFERENCES `registries` ON DELETE CASCADE,
  `name` varchar(255) NOT NULL,
  `registry_ref` varchar(255),
  `downloads_total` bigint,
  `rank` integer,
  `tracked` boolean DEFAULT(1) NOT NULL,
  `first_provenant_at` timestamp,
  `created_at` timestamp NOT NULL,
  `updated_at` timestamp NOT NULL
);
CREATE UNIQUE INDEX `packages_registry_id_name_index` ON `packages`(
  `registry_id`,
  `name`
);
CREATE INDEX `packages_registry_id_rank_index` ON `packages`(
  `registry_id`,
  `rank`
);
CREATE INDEX `packages_first_provenant_at_index` ON `packages`(
  `first_provenant_at`
);
CREATE TABLE `adoption_snapshots`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `registry_id` integer NOT NULL REFERENCES `registries` ON DELETE CASCADE,
  `taken_on` date NOT NULL,
  `tracked_packages` integer NOT NULL,
  `provenant_packages` integer NOT NULL,
  `tracked_versions` integer NOT NULL,
  `provenant_versions` integer NOT NULL,
  `created_at` timestamp NOT NULL
);
CREATE UNIQUE INDEX `adoption_snapshots_registry_id_taken_on_index` ON `adoption_snapshots`(
  `registry_id`,
  `taken_on`
);
CREATE TABLE `package_versions`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `package_id` integer NOT NULL REFERENCES `packages` ON DELETE CASCADE,
  `number` varchar(255) NOT NULL,
  `platform` varchar(255) DEFAULT('') NOT NULL,
  `registry_ref` varchar(255),
  `published_at` timestamp,
  `prerelease` boolean DEFAULT(0) NOT NULL,
  `latest` boolean DEFAULT(0) NOT NULL,
  `yanked` boolean DEFAULT(0) NOT NULL,
  `provenance_kind` varchar(255),
  `provenance_provider` varchar(255),
  `source_repository` varchar(255),
  `workflow_ref` varchar(255),
  `commit_sha` varchar(255),
  `run_url` varchar(255),
  `attestation_count` integer DEFAULT(0) NOT NULL,
  `provenance_checked_at` timestamp,
  `created_at` timestamp NOT NULL,
  `updated_at` timestamp NOT NULL
);
CREATE UNIQUE INDEX `package_versions_package_id_number_platform_index` ON `package_versions`(
  `package_id`,
  `number`,
  `platform`
);
CREATE INDEX `package_versions_package_id_provenance_kind_index` ON `package_versions`(
  `package_id`,
  `provenance_kind`
);
CREATE INDEX `package_versions_published_at_index` ON `package_versions`(
  `published_at`
);
INSERT INTO schema_migrations (filename) VALUES
('20260814001053_create_registries.rb'),
('20260814001054_create_packages.rb'),
('20260814001055_create_adoption_snapshots.rb'),
('20260814001056_create_package_versions.rb'),
('20260814173513_add_feed_synced_at_to_registries.rb');
