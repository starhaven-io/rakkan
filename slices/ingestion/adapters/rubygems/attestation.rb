# auto_register: false
# frozen_string_literal: true

require "base64"
require "openssl"

module Ingestion
  module Adapters
    class Rubygems
      # Extracts publisher identity from a sigstore bundle's Fulcio
      # certificate. The interesting claims live in X.509 extensions under
      # the Fulcio OID arc 1.3.6.1.4.1.57264.1 (verified against live
      # registry attestations; see DATA_SOURCES.md).
      module Attestation
        OID_ISSUER = "1.3.6.1.4.1.57264.1.8"        # DER-wrapped issuer URL
        OID_ISSUER_LEGACY = "1.3.6.1.4.1.57264.1.1" # raw issuer URL
        OID_SOURCE_REPO_URI = "1.3.6.1.4.1.57264.1.12"
        OID_SOURCE_SHA = "1.3.6.1.4.1.57264.1.13"
        OID_RUN_URL = "1.3.6.1.4.1.57264.1.21"

        ISSUER_PROVIDERS = {
          "https://token.actions.githubusercontent.com" => "github",
          "https://gitlab.com" => "gitlab"
        }.freeze

        module_function

        # bundles: array of parsed sigstore bundle hashes from the
        # attestations API / dump body. Returns a provenance column hash, or
        # nil when no bundle yields a certificate. Every bundle is parsed so
        # a malformed first bundle cannot hide a valid later one; when
        # parseable bundles disagree, the lexicographically smallest identity
        # wins: arbitrary but deterministic, independent of bundle order.
        def parse(bundles)
          identities = bundles.filter_map { |bundle| parse_bundle(bundle) }
          return nil if identities.empty?

          chosen = identities.min_by do |identity|
            identity.values_at(:source_repository, :commit_sha, :workflow_ref, :run_url).map(&:to_s)
          end
          chosen.merge(attestation_count: bundles.size)
        end

        def parse_bundle(bundle)
          raw = bundle.dig("verificationMaterial", "certificate", "rawBytes")
          return nil unless raw

          cert = OpenSSL::X509::Certificate.new(Base64.decode64(raw))
          exts = cert.extensions.to_h { |e| [e.oid, e] }

          issuer = ext_value(exts[OID_ISSUER]) || ext_value(exts[OID_ISSUER_LEGACY])
          {
            provenance_kind: "sigstore_attestation",
            provenance_provider: ISSUER_PROVIDERS.fetch(issuer, issuer),
            source_repository: ext_value(exts[OID_SOURCE_REPO_URI]),
            workflow_ref: san_uri(exts["subjectAltName"]),
            commit_sha: ext_value(exts[OID_SOURCE_SHA]),
            run_url: ext_value(exts[OID_RUN_URL])
          }
        rescue OpenSSL::X509::CertificateError
          nil
        end

        # Fulcio extensions from OID .8 onward wrap their strings in DER;
        # earlier ones are raw. Try DER first, fall back to the raw value.
        def ext_value(ext)
          return nil unless ext

          OpenSSL::ASN1.decode(ext.value_der).value.to_s
        rescue OpenSSL::ASN1::ASN1Error
          ext.value.to_s
        end

        def san_uri(ext)
          return nil unless ext

          ext.value.to_s[/URI:(\S+)/, 1]
        end
      end
    end
  end
end
