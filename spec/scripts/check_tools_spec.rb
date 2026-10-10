# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "check-tools.rb" do
  it "reports every missing gate executable in one preflight" do
    Dir.mktmpdir("rakkan-empty-path") do |empty_path|
      script = Hanami.app.root.join("scripts", "check-tools.rb").to_s
      _stdout, stderr, status = Open3.capture3({ "PATH" => empty_path }, RbConfig.ruby, script, unsetenv_others: true)

      expect(status).not_to be_success
      expect(stderr).to include(
        "Missing tools required by just check",
        "zizmor (Homebrew package: zizmor)",
        "pinprick (Homebrew package: pinprick)",
        "typos (Homebrew package: typos-cli)"
      )
    end
  end
end
