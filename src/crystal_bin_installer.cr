require "yaml"
require "file_utils"
require "colorize"

# Walks a source directory of Crystal shards, checks their git sync state
# against `origin/production`, compiles every declared target, and copies
# the resulting binaries into a destination directory (default `~/bin`).
module CrystalBinInstaller
  VERSION = "0.1.2"

  # Default path of the user-level config file (loaded automatically by
  # the CLI unless `--config` is passed).
  DEFAULT_CONFIG_PATH = File.join(Path.home.to_s, ".crystal-bin-installer.yml")

  # Persistent per-user defaults read from a YAML file. Fields are
  # optional: unset entries fall back to the built-in defaults, and CLI
  # flags override everything.
  class Config
    getter dir : String?
    getter dest : String?
    getter release : Bool?
    getter skip : Array(String)
    getter fetch : Bool?
    getter force : Bool?

    def initialize(
      @dir : String? = nil,
      @dest : String? = nil,
      @release : Bool? = nil,
      @skip : Array(String) = [] of String,
      @fetch : Bool? = nil,
      @force : Bool? = nil,
    )
    end

    # Loads a `Config` from `path`. Returns an empty `Config` when the
    # file does not exist or cannot be parsed.
    def self.load(path : String) : Config
      return new unless File.exists?(path)

      yaml = YAML.parse(File.read(path))
      return new unless yaml.raw.is_a?(Hash(YAML::Any, YAML::Any))

      skip = [] of String
      if (s = yaml["skip"]?) && s.raw.is_a?(Array(YAML::Any))
        skip = s.as_a.map(&.as_s)
      end

      new(
        dir: yaml["dir"]?.try(&.as_s?),
        dest: yaml["dest"]?.try(&.as_s?),
        release: yaml["release"]?.try(&.as_bool?),
        skip: skip,
        fetch: yaml["fetch"]?.try(&.as_bool?),
        force: yaml["force"]?.try(&.as_bool?),
      )
    rescue YAML::ParseException
      new
    end
  end

  # Status of a single target processed by the installer.
  enum Status
    Installed
    Skipped
    Failed
  end

  # Outcome of a single project/target pair.
  record Result,
    project : String,
    target : String,
    status : Status,
    message : String

  class Installer
    getter source_dir : String
    getter dest_dir : String
    getter release : Bool
    getter skip : Array(String)
    getter dry_run : Bool
    getter fetch : Bool
    getter force : Bool

    def initialize(
      @source_dir : String,
      @dest_dir : String,
      @release : Bool = true,
      @skip : Array(String) = [] of String,
      @dry_run : Bool = false,
      @fetch : Bool = true,
      @force : Bool = false,
    )
    end

    # Walks the source directory, processes every eligible project, and
    # returns the list of results (one per target, zero per pure library).
    def run : Array(Result)
      FileUtils.mkdir_p(dest_dir) unless dry_run
      results = [] of Result

      Dir.children(source_dir).sort.each do |name|
        project_path = File.join(source_dir, name)
        next unless File.directory?(project_path)

        shard_path = File.join(project_path, "shard.yml")
        next unless File.exists?(shard_path)

        if skip.includes?(name)
          results << Result.new(name, "-", Status::Skipped, "exclu via --skip")
          next
        end

        targets = extract_targets(shard_path)
        next if targets.empty? # pure library, silently skipped

        sync_issue = force ? nil : git_sync_issue(project_path)
        if issue = sync_issue
          targets.each do |target|
            results << Result.new(name, target, Status::Failed, issue)
          end
          next
        end

        # When a project declares exactly one target, install the binary
        # under the project (directory) name rather than the target name.
        # This avoids generic names leaking into `~/bin` (e.g. a project
        # `crystal-deploy` whose target is `deploy` would otherwise install
        # as `deploy`, shadowing other tools on `$PATH`).
        targets.each do |target|
          installed_name = targets.size == 1 ? name : target
          results << process_target(name, project_path, target, installed_name)
        end
      end

      results
    end

    # Reads `shard.yml` and returns the list of target names.
    # Returns an empty array when no `targets:` section is present.
    def extract_targets(shard_path : String) : Array(String)
      yaml = YAML.parse(File.read(shard_path))
      return [] of String unless targets = yaml["targets"]?
      return [] of String unless targets.raw.is_a?(Hash(YAML::Any, YAML::Any))
      targets.as_h.keys.map(&.as_s)
    rescue YAML::ParseException
      [] of String
    end

    # Checks that `project_path` is a git repo on branch `production`, with a
    # clean working tree and in sync with `origin/production`.
    # Returns `nil` when everything is fine, otherwise a human-readable reason.
    def git_sync_issue(project_path : String) : String?
      return "pas un dépôt git" unless File.directory?(File.join(project_path, ".git"))

      branch = run_git(project_path, "rev-parse", "--abbrev-ref", "HEAD").strip
      return "branche courante « #{branch} » différente de « production »" if branch != "production"

      dirty = run_git(project_path, "status", "--porcelain").strip
      return "arbre de travail sale (modifications non commitées)" unless dirty.empty?

      if fetch
        status = Process.run("git", ["fetch", "--quiet", "origin", "production"],
          chdir: project_path, output: Process::Redirect::Close, error: Process::Redirect::Close)
        return "git fetch a échoué" unless status.success?
      end

      ahead = run_git(project_path, "rev-list", "--count", "origin/production..HEAD").strip.to_i? || 0
      behind = run_git(project_path, "rev-list", "--count", "HEAD..origin/production").strip.to_i? || 0

      return "#{ahead} commit(s) local(aux) non poussé(s)" if ahead > 0
      return "#{behind} commit(s) distant(s) non tirés" if behind > 0

      nil
    end

    private def run_git(project_path : String, *args : String) : String
      stdout = IO::Memory.new
      Process.run("git", args.to_a, chdir: project_path,
        output: stdout, error: Process::Redirect::Close)
      stdout.to_s
    end

    private def process_target(
      project : String,
      project_path : String,
      target : String,
      installed_name : String,
    ) : Result
      header = "▶ #{project} → #{target}"
      header += " (installé sous le nom #{installed_name})" if installed_name != target
      puts header.colorize.cyan.bold

      if dry_run
        puts "  [dry-run] shards build #{release ? "--release " : ""}#{target}"
        puts "  [dry-run] copie dans #{File.join(dest_dir, installed_name)}"
        return Result.new(project, target, Status::Installed, "dry-run")
      end

      build_args = ["build", target]
      build_args << "--release" if release

      # Always refresh deps first (idempotent, cheap when already installed).
      return build_error(project, target, "shards install") unless Process.run(
                                                                     "shards", ["install", "--production"],
                                                                     chdir: project_path, output: STDOUT, error: STDERR
                                                                   ).success?

      return build_error(project, target, "shards build") unless Process.run(
                                                                   "shards", build_args,
                                                                   chdir: project_path, output: STDOUT, error: STDERR
                                                                 ).success?

      binary_src = File.join(project_path, "bin", target)
      unless File.exists?(binary_src) && File.info(binary_src).size > 0
        return Result.new(project, target, Status::Failed, "binaire introuvable : bin/#{target}")
      end

      binary_dst = File.join(dest_dir, installed_name)
      FileUtils.cp(binary_src, binary_dst)
      File.chmod(binary_dst, 0o755)

      puts "  installé : #{binary_dst}".colorize.green
      Result.new(project, target, Status::Installed, binary_dst)
    end

    private def build_error(project : String, target : String, step : String) : Result
      puts "  échec à l'étape « #{step} »".colorize.red
      Result.new(project, target, Status::Failed, "échec à l'étape « #{step} »")
    end
  end

  # Formats and prints a colorised summary of results to `io`.
  def self.print_summary(results : Array(Result), io : IO = STDOUT) : Nil
    installed = results.select(&.status.installed?)
    failed = results.select(&.status.failed?)
    skipped = results.select(&.status.skipped?)

    io.puts
    io.puts "═══ Récapitulatif ═══".colorize.bold
    io.puts "#{installed.size} installé(s), #{failed.size} échec(s), #{skipped.size} exclu(s)"

    unless installed.empty?
      io.puts
      io.puts "Installés :".colorize.green
      installed.each { |r| io.puts "  * #{r.project} → #{r.target}" }
    end

    unless failed.empty?
      io.puts
      io.puts "Échecs :".colorize.red
      failed.each { |r| io.puts "  * #{r.project} → #{r.target} : #{r.message}" }
    end

    unless skipped.empty?
      io.puts
      io.puts "Exclus :".colorize.yellow
      skipped.each { |r| io.puts "  * #{r.project} : #{r.message}" }
    end
  end
end
