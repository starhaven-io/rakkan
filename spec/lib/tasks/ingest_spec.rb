# frozen_string_literal: true

require "rake"

RSpec.describe "ingestion rake tasks" do
  before(:all) do
    Rake.application.rake_require("tasks/ingest", [Hanami.app.root.join("lib").to_s])
  end

  before do
    %w[ingest:seed ingest:discover ingest:refresh snapshot:take].each do |name|
      Rake::Task[name].reenable
    end
    allow(Ingestion::Slice).to receive(:[]).and_call_original
  end

  def invoke_task(name, *)
    Rake::Task[name].invoke(*)
  end

  it "defaults seed to RubyGems" do
    operation = instance_double(Ingestion::Operations::SeedFromDump)
    allow(Ingestion::Slice).to receive(:[]).with("operations.seed_from_dump").and_return(operation)
    expect(operation).to receive(:call)
      .with(adapter: an_instance_of(Ingestion::Adapters::Rubygems))
      .and_return(:seeded)

    expect { invoke_task("ingest:seed") }.to output(":seeded\n").to_stdout
  end

  it "defaults discovery to RubyGems" do
    operation = instance_double(Ingestion::Operations::DiscoverNewVersions)
    allow(Ingestion::Slice).to receive(:[]).with("operations.discover_new_versions").and_return(operation)
    expect(operation).to receive(:call)
      .with(adapter: an_instance_of(Ingestion::Adapters::Rubygems))
      .and_return(:discovered)

    expect { invoke_task("ingest:discover") }.to output(":discovered\n").to_stdout
  end

  it "fails discovery when the page budget is exhausted" do
    operation = instance_double(Ingestion::Operations::DiscoverNewVersions)
    result = Dry::Monads::Result::Success.new(
      drained: false, synced_through: Time.utc(2026, 8, 17)
    )
    allow(Ingestion::Slice).to receive(:[]).with("operations.discover_new_versions").and_return(operation)
    expect(operation).to receive(:call)
      .with(adapter: an_instance_of(Ingestion::Adapters::Rubygems))
      .and_return(result)

    expect { invoke_task("ingest:discover") }
      .to raise_error(
        IngestionTaskSupport::IncompleteDiscovery,
        "ingest:discover exhausted its page budget at 2026-08-17 00:00:00 UTC; " \
        "rerun to resume from the persisted cursor"
      )
  end

  it "keeps the refresh limit first and defaults its registry to RubyGems" do
    operation = instance_double(Ingestion::Operations::RefreshProvenance)
    payload = { checked: 3, provenant: 1, settled: 0, remaining: 4 }
    result = Dry::Monads::Result::Success.new(payload)
    allow(Ingestion::Slice).to receive(:[]).with("operations.refresh_provenance").and_return(operation)
    expect(operation).to receive(:call)
      .with(limit: 73, adapter: an_instance_of(Ingestion::Adapters::Rubygems))
      .and_return(result)

    expect { invoke_task("ingest:refresh", "73") }.to output("#{JSON.generate(payload)}\n").to_stdout
  end

  it "defaults snapshots to RubyGems" do
    operation = instance_double(Ingestion::Operations::TakeSnapshot)
    allow(Ingestion::Slice).to receive(:[]).with("operations.take_snapshot").and_return(operation)
    expect(operation).to receive(:call).with(registry_name: "rubygems").and_return(:recorded)

    expect { invoke_task("snapshot:take") }.to output(":recorded\n").to_stdout
  end

  it "passes an explicit registry adapter to seed" do
    operation = instance_double(Ingestion::Operations::SeedFromDump)
    allow(Ingestion::Slice).to receive(:[]).with("operations.seed_from_dump").and_return(operation)
    expect(operation).to receive(:call)
      .with(adapter: an_instance_of(Ingestion::Adapters::Cratesio))
      .and_return(:seeded)

    expect { invoke_task("ingest:seed", "cratesio") }.to output(":seeded\n").to_stdout
  end

  it "passes an explicit registry after the refresh limit" do
    operation = instance_double(Ingestion::Operations::RefreshProvenance)
    payload = { checked: 12, provenant: 2, settled: 30, remaining: 9 }
    result = Dry::Monads::Result::Success.new(payload)
    allow(Ingestion::Slice).to receive(:[]).with("operations.refresh_provenance").and_return(operation)
    expect(operation).to receive(:call)
      .with(limit: 12, adapter: an_instance_of(Ingestion::Adapters::Cratesio))
      .and_return(result)

    expect { invoke_task("ingest:refresh", "12", "cratesio") }.to output("#{JSON.generate(payload)}\n").to_stdout
  end

  it "resolves an explicit snapshot registry through its adapter" do
    operation = instance_double(Ingestion::Operations::TakeSnapshot)
    allow(Ingestion::Slice).to receive(:[]).with("operations.take_snapshot").and_return(operation)
    expect(operation).to receive(:call).with(registry_name: "pypi").and_return(:recorded)

    expect { invoke_task("snapshot:take", "pypi") }.to output(":recorded\n").to_stdout
  end

  {
    "ingest:seed" => ["krates"],
    "ingest:discover" => ["krates"],
    "ingest:refresh" => %w[50 krates],
    "snapshot:take" => ["krates"]
  }.each do |task_name, args|
    it "rejects an unknown registry for #{task_name}" do
      expect { invoke_task(task_name, *args) }
        .to raise_error(
          ArgumentError,
          'unknown registry "krates"; valid options: cratesio, pypi, rubygems'
        )
    end
  end

  it "rejects PyPI seeding before creating a registry", :db do
    expect { invoke_task("ingest:seed", "pypi") }
      .to raise_error(
        IngestionTaskSupport::UnsupportedOperation,
        "ingest:seed is unavailable for registry pypi; add a tracked seed before selecting it"
      )
    expect(Hanami.app["relations.registries"].count).to eq(0)
  end

  it "explains the crates.io discovery path" do
    expect { invoke_task("ingest:discover", "cratesio") }
      .to raise_error(
        IngestionTaskSupport::UnsupportedOperation,
        "ingest:discover is unavailable for registry cratesio; " \
        "rebuild the daily-dump seed, then run ingest:seed[cratesio]"
      )
  end

  it "allows discovery when a listed adapter implements it" do
    capable_adapter_class = Class.new(Ingestion::Adapters::Cratesio) do
      def new_versions(**)
        { entries: [], drained: true, pages: 0 }
      end
    end
    adapter = capable_adapter_class.new(http_client: FixtureHelpers::FakeHTTPClient.new)
    operation = instance_double(Ingestion::Operations::DiscoverNewVersions)
    allow(Ingestion::Slice).to receive(:[]).with("adapters.cratesio").and_return(adapter)
    allow(Ingestion::Slice).to receive(:[]).with("operations.discover_new_versions").and_return(operation)
    expect(operation).to receive(:call).with(adapter:).and_return(:discovered)

    expect { invoke_task("ingest:discover", "cratesio") }.to output(":discovered\n").to_stdout
  end

  it "explains the PyPI discovery boundary" do
    expect { invoke_task("ingest:discover", "pypi") }
      .to raise_error(
        IngestionTaskSupport::UnsupportedOperation,
        "ingest:discover is unavailable for registry pypi; " \
        "implement a durable discovery cursor before selecting it"
      )
  end
end
