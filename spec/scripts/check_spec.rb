# frozen_string_literal: true

require_relative "../../scripts/check"

RSpec.describe RepositoryCheck do
  subject(:check) { described_class.new }

  before do
    allow(check).to receive(:puts)
    allow(check).to receive(:system).and_return(true)
    allow(CheckTools).to receive(:available?).and_return(true)
    allow(File).to receive(:directory?).with("site/node_modules").and_return(true)
  end

  it "retains failed checks while running the remaining gate" do
    allow(check).to receive(:system).with("bundle", "exec", "rubocop", "--cache-root", "var/cache/rubocop")
                                    .and_return(false)

    expect(check.call).to be(false)
    expect(check).to have_received(:system).with("typos")
    expect(check).to have_received(:system).with("npm", "run", "--silent", "test:coverage", chdir: "site")
  end

  it "fails the gate if required external tools or site dependencies are missing" do
    allow(CheckTools).to receive(:available?).with("zizmor").and_return(false)
    allow(File).to receive(:directory?).with("site/node_modules").and_return(false)

    expect(check.call).to be(false)
    expect(check).to have_received(:puts).with("  - zizmor (brew install zizmor)")
    expect(check).to have_received(:puts).with("  - node_modules (brew install just install-site)")
    expect(check).to have_received(:system).with("typos")
  end

  it "succeeds only when every required check is available and passes" do
    expect(check.call).to be(true)
  end
end
