# auto_register: false
# frozen_string_literal: true

module Ingestion
  module Adapters
    # Interface every complete registry adapter implements. Provenance readers
    # may land before a registry's bulk seed and discovery path; ingestion tasks
    # must not select that adapter until the remaining methods are implemented.
    #
    # Seed methods stream from local, dump-derived files (no network).
    # Live methods hit the registry's public API through the polite client.
    class RegistryAdapter
      # Identity used for the registries table row.
      def registry_slug = raise NotImplementedError
      def display_name = raise NotImplementedError
      def registry_url = raise NotImplementedError

      # Yields { name:, registry_ref:, rank:, downloads_total: } per tracked
      # package, in rank order.
      def each_tracked_package = raise NotImplementedError

      # Yields { registry_ref:, package_ref:, number:, platform:,
      #   published_at:, prerelease:, latest:, yanked: } per known version of
      # a tracked package. package_ref matches a package's registry_ref.
      def each_seed_version = raise NotImplementedError

      # Yields { version_ref:, provenance: {...} } per attested version in the
      # seed data. version_ref matches a version's registry_ref. The
      # provenance hash uses the shared column names (provenance_kind,
      # provenance_provider, source_repository, workflow_ref, commit_sha,
      # run_url, attestation_count).
      def each_seed_attestation = raise NotImplementedError

      # Live: fetch provenance for one version. Returns a provenance hash
      # (as above) or nil when the registry reports none.
      def fetch_provenance(name:, number:, platform:) = raise NotImplementedError

      # When the seed data was authoritative (nil when unknown). Versions
      # seeded without provenance are considered checked as of this time.
      def seed_as_of = nil

      # Live: enumerate versions published between two times. Returns
      # { entries:, drained:, pages: } where entries are hashes
      # { package_name:, number:, platform:, published_at:, prerelease:,
      #   yanked: } and drained is false when the page budget ran out before
      # the window was exhausted (callers must not advance their cursor past
      # the entries actually seen). Entries are expected in ascending
      # published order, per the registry's observed feed behavior. May
      # return versions of untracked packages; callers filter.
      def new_versions(from:, to:, max_pages:) = raise NotImplementedError
    end
  end
end
