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

      # Live: yield each version and its provenance. Registries may override
      # this to answer several versions with one request while retaining the
      # per-version write boundary in RefreshProvenance.
      def each_provenance(name:, versions:)
        return enum_for(__method__, name:, versions:) unless block_given?

        versions.each do |version|
          provenance = fetch_provenance(
            name:, number: version[:number], platform: version[:platform]
          )
          yield(version, provenance)
        end
      end

      # When the seed's package/version data was authoritative (nil when
      # unknown). Discovery can advance its cursor to this time.
      def seed_as_of = nil

      # When the seed's provenance data was authoritative (nil when the seed
      # did not observe provenance). Versions seeded without provenance are
      # considered checked only when this timestamp is present.
      def provenance_seed_as_of = nil

      # Registries whose tracked set comes from a dated dump return that
      # dump's day, so rerunning the same seed replaces one observation
      # instead of adding one per dispatch.
      def snapshot_taken_on = nil

      # Earliest publish time at which this registry could record provenance
      # (nil when it always could, or when the date is unknown). Versions
      # published earlier are settled without a live request: the mechanism
      # did not exist, so "none" is an observation rather than an assumption.
      def provenance_available_since = nil

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
