# frozen_string_literal: true

module Ingestion
  module Operations
    # Ask the registry for provenance on versions we have not checked yet
    # (or not recently). Resumable by construction: each version's row is
    # updated as soon as it is checked, so an interrupted run just continues
    # where it stopped. `limit` caps the versions put to the live API per run.
    # Adapters may batch versions when one response can answer several of them;
    # registries with per-file provenance may instead make several requests per
    # version. Exact reviewed waiver candidates are probed outside that cap so
    # they cannot starve ordinary work; the waiver file bounds those probes.
    # Versions published before the registry could record provenance are
    # settled in bulk outside the cap, since they cost no requests.
    # Convergent with registry state: checks bypass the response cache, and
    # a negative answer clears any previously stored provenance.
    class RefreshProvenance < Ingestion::Operation
      include Deps[
        "adapters.rubygems",
        "repos.registry_repo",
        "relations.packages",
        "relations.package_versions"
      ]

      NO_PROVENANCE = {
        provenance_kind: nil, provenance_provider: nil, source_repository: nil,
        workflow_ref: nil, commit_sha: nil, run_url: nil, attestation_count: 0
      }.freeze

      def call(limit: 50, stale_after: nil, adapter: rubygems,
               waiver_date: Time.now.utc.to_date, waivers: nil)
        registry = registry_repo.by_name(adapter.registry_slug)
        return { error: "unknown registry #{adapter.registry_slug}" } unless registry

        waivers ||= Ingestion::ProvenanceWaivers.load(today: waiver_date)
        now = Time.now.utc
        available_since = adapter.provenance_available_since
        settled = settle_predating(registry.id, available_since, now)
        checked = 0
        found = 0
        waived = 0
        errors = 0
        waived_ids = []

        candidate_batches(
          registry.id, stale_after, limit, available_since, now, waivers, adapter.registry_slug
        ).each do |name, rows|
          adapter.each_provenance(name:, versions: rows) do |row, provenance, error|
            if error
              waiver = waiver_for(waivers, adapter.registry_slug, name, row, error)
              if waiver
                waived += 1
                waived_ids << row[:id]
                package_versions.by_pk(row[:id]).command(:update).call(
                  NO_PROVENANCE.merge(provenance_checked_at: nil, updated_at: now)
                )
                warn_waived_not_found(name, row, waiver)
                next
              end

              errors += 1
              warn_provenance_error(name, row, error)
              next
            end

            attrs = (provenance || NO_PROVENANCE.dup)
                    .merge(provenance_checked_at: now, updated_at: now)
            package_versions.by_pk(row[:id]).command(:update).call(attrs)
            checked += 1
            found += 1 if provenance
          end
        end

        recompute_first_provenant_at(registry.id)
        remaining_scope = candidate_scope(registry.id, stale_after, available_since, now)
        remaining_scope = remaining_scope.exclude(Sequel[:package_versions][:id] => waived_ids) unless waived_ids.empty?
        remaining = remaining_scope.count
        { checked:, provenant: found, settled:, waived:, errors:, remaining: }
      end

      private

      # Versions published before the registry could record provenance at all
      # are settled in one statement rather than one request each. Spending a
      # run's live budget on them would be waste: the mechanism did not exist,
      # so the answer is already known. A null published_at is left alone --
      # an unknown publish time cannot rule provenance out.
      def settle_predating(registry_id, available_since, now)
        return 0 unless available_since

        tracked_ids = packages.dataset.where(registry_id:, tracked: true).select(:id)
        package_versions.dataset
                        .where(package_id: tracked_ids, provenance_checked_at: nil)
                        .where(yanked: false)
                        .where(Sequel[:published_at] < available_since)
                        .update(**NO_PROVENANCE, provenance_checked_at: now, updated_at: now)
      end

      # Unchecked (or stale) versions of this registry's tracked packages,
      # newest first so fresh releases get provenance quickly. Sequel join
      # because the package name lives on packages.
      def candidates(registry_id, stale_after, limit, available_since, now, waivers, registry_slug)
        scope = candidate_scope(registry_id, stale_after, available_since, now)
        registry_waivers = waivers.for_registry(registry_slug)
        return ordered_candidates(scope).limit(limit).to_a if registry_waivers.empty?

        waiver_match = waiver_match_expression(registry_waivers)
        ordinary = ordered_candidates(scope.exclude(waiver_match)).limit(limit).to_a
        waiver_probes = ordered_candidates(scope.where(waiver_match)).to_a
        ordinary + waiver_probes
      end

      def candidate_batches(registry_id, stale_after, limit, available_since, now, waivers, registry_slug)
        candidates(
          registry_id, stale_after, limit, available_since, now, waivers, registry_slug
        ).group_by do |row|
          row[:name]
        end
      end

      def ordered_candidates(scope)
        scope
          .select(
            Sequel[:package_versions][:id],
            Sequel[:packages][:name],
            Sequel[:package_versions][:number],
            Sequel[:package_versions][:platform]
          )
          .order(
            Sequel.desc(Sequel[:package_versions][:published_at]),
            Sequel.desc(Sequel[:package_versions][:id])
          )
      end

      def waiver_match_expression(entries)
        Sequel.|(*entries.map do |entry|
          {
            Sequel[:packages][:name] => entry.package,
            Sequel[:package_versions][:number] => entry.number,
            Sequel[:package_versions][:platform] => entry.platform
          }
        end)
      end

      # The workflow consumes this count from the operation result instead of
      # maintaining a second copy of the eligibility rules in shell SQL.
      def candidate_scope(registry_id, stale_after, available_since, now)
        ds = package_versions.dataset
                             .join(:packages, id: :package_id)
                             .where(Sequel[:packages][:registry_id] => registry_id)
                             .where(Sequel[:packages][:tracked] => true)
                             .where(Sequel[:package_versions][:yanked] => false)
        if available_since
          ds = ds.where(
            Sequel.|(
              Sequel[:package_versions][:published_at] >= available_since,
              { Sequel[:package_versions][:published_at] => nil }
            )
          )
        end
        if stale_after
          ds.where do
            (Sequel[:package_versions][:provenance_checked_at] =~ nil) |
              (Sequel[:package_versions][:provenance_checked_at] < now - stale_after)
          end
        else
          ds.where(Sequel[:package_versions][:provenance_checked_at] => nil)
        end
      end

      def recompute_first_provenant_at(registry_id)
        package_versions.dataset.db.run(<<~SQL)
          UPDATE packages
          SET first_provenant_at = (
            SELECT MIN(pv.published_at) FROM package_versions pv
            WHERE pv.package_id = packages.id AND pv.provenance_kind IS NOT NULL
          )
          WHERE registry_id = #{Integer(registry_id)}
        SQL
      end

      def warn_provenance_error(name, row, error)
        identifier = "#{name}-#{row[:number]}-#{row[:platform]}"
        detail = "#{error.class}: #{error.message}"
        warn "provenance check left unchecked: #{log_value(identifier)} (#{log_value(detail)})"
      end

      def waiver_for(waivers, registry, name, row, error)
        return unless error.is_a?(Ingestion::HTTPClient::NotFoundError)

        waivers.find(
          registry:, package: name, number: row[:number], platform: row[:platform]
        )
      end

      def warn_waived_not_found(name, row, waiver)
        identifier = "#{name}-#{row[:number]}-#{row[:platform]}"
        warn "provenance 404 waived: #{log_value(identifier)} " \
             "(expires #{waiver.expires_on.iso8601}; #{log_value(waiver.reason)})"
      end

      def log_value(value)
        value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
             .gsub(/[[:cntrl:]]+/, " ").squeeze(" ").strip[0, 300]
      end
    end
  end
end
