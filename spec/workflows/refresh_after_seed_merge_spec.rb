# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "post-merge seed refresh dispatch" do
  %w[cratesio rubygems].each do |registry|
    context "for #{registry}" do
      let(:registry) { registry }

      it "waits for a completed run's refresh job to report its conclusion" do
        run_dispatch([completed_run(job("in_progress")), completed_run(job("completed", "success"))]) do |result|
          expect(result.fetch(:status)).to be_success, result.fetch(:output)
          expect(result.fetch(:views)).to eq(2)
          expect(result.fetch(:summary)).to include("refresh completed for exact main SHA")
        end
      end

      it "fails when the refresh job fails" do
        run_dispatch([completed_run(job("completed", "failure"), "failure")]) do |result|
          expect(result.fetch(:status)).not_to be_success
          expect(result.fetch(:output)).to include("refresh run 101 concluded failure")
        end
      end

      it "dispatches again after a skipped refresh" do
        views = [completed_run(job("completed", "skipped")), completed_run(job("completed", "success"))]
        run_dispatch(views) do |result|
          expect(result.fetch(:status)).to be_success, result.fetch(:output)
          expect(result.fetch(:dispatches)).to eq(2)
          expect(result.fetch(:summary)).to include("Protected refresh run: 102")
        end
      end

      %w[success failure].each do |run_conclusion|
        it "fails when a completed #{run_conclusion} run's refresh job never settles" do
          run_dispatch([completed_run(job("in_progress"), run_conclusion)]) do |result|
            expect(result.fetch(:status)).not_to be_success
            expect(result.fetch(:views)).to eq(12)
            expect(result.fetch(:output)).to include("could not resolve the refresh result of completed run 101")
          end
        end
      end

      it "defers to the protected run while it is still in progress" do
        run_dispatch([{ "status" => "in_progress", "conclusion" => "", "jobs" => [job("in_progress")] }]) do |result|
          expect(result.fetch(:status)).to be_success, result.fetch(:output)
          expect(result.fetch(:views)).to eq(1)
          expect(result.fetch(:summary)).to include("The protected run is still in_progress")
        end
      end
    end
  end

  def job(status, conclusion = "")
    { "name" => "Refresh registry data", "status" => status, "conclusion" => conclusion }
  end

  def completed_run(refresh_job, conclusion = "success")
    { "status" => "completed", "conclusion" => conclusion, "jobs" => [refresh_job] }
  end

  def run_dispatch(views)
    workflow = YAML.safe_load_file(
      Hanami.app.root.join(".github", "workflows", "refresh-#{registry}-after-seed-merge.yml")
    )
    step = workflow.fetch("jobs").fetch("dispatch").fetch("steps").first
    Dir.mktmpdir("rakkan-dispatch") do |directory|
      calls = File.join(directory, "calls")
      summary = File.join(directory, "summary")
      File.write(calls, "")
      File.write(File.join(directory, "views.json"), JSON.generate(views))
      write_stubs(directory)
      runs = (1..3).map do |attempt|
        { databaseId: 100 + attempt, displayTitle: "Refresh Data (#{registry}) [7-1-#{attempt}]" }
      end
      env = {
        "CALLS" => calls,
        "GITHUB_RUN_ATTEMPT" => "1",
        "GITHUB_RUN_ID" => "7",
        "GITHUB_STEP_SUMMARY" => summary,
        "MERGE_SHA" => "a" * 40,
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
        "PR_NUMBER" => "12",
        "PR_URL" => "https://github.com/starhaven-io/rakkan/pull/12",
        "REGISTRY" => registry,
        "REPOSITORY" => "starhaven-io/rakkan",
        "RUNS_JSON" => JSON.generate(runs),
        "VIEWS" => File.join(directory, "views.json")
      }
      output, status = Open3.capture2e(env, "bash", "-euo", "pipefail", "-c", step.fetch("run"))
      logged = File.readlines(calls, chomp: true)
      yield(
        status:, output:,
        views: logged.count { |call| call.start_with?("run view ") },
        dispatches: logged.count { |call| call.start_with?("workflow run ") },
        summary: File.exist?(summary) ? File.read(summary) : ""
      )
    end
  end

  def write_stubs(directory)
    write_executable(directory, "gh", <<~'BASH')
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "${CALLS}"
      case "$*" in
        "api --paginate --slurp "*) printf '[[{"filename":"seed/%s/manifest.json","status":"modified"}]]\n' "${REGISTRY}" ;;
        "api "*"/git/ref/heads/main "*) printf '%s\n' "${MERGE_SHA}" ;;
        "api "*"/compare/"*) printf 'identical\n' ;;
        "workflow run "* | "run watch "*) ;;
        "run list "*) printf '%s\n' "${RUNS_JSON}" ;;
        "run view "*)
          index=$(( $(grep -c '^run view ' "${CALLS}") - 1 ))
          jq -c --argjson index "${index}" '.[[$index, length - 1] | min]' "${VIEWS}"
          ;;
        *) echo "unexpected gh $*" >&2; exit 1 ;;
      esac
    BASH
    write_executable(directory, "timeout", <<~BASH)
      #!/usr/bin/env bash
      shift
      exec "$@"
    BASH
    write_executable(directory, "sleep", "#!/usr/bin/env bash\n")
  end

  def write_executable(directory, name, source)
    path = File.join(directory, name)
    File.write(path, source)
    FileUtils.chmod(0o755, path)
  end
end
