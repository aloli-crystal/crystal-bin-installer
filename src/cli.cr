require "option_parser"
require "./crystal_bin_installer"

# ---------------------------------------------------------------------------
# Defaults < config file < CLI flags.
#
# 1. Start from the built-in defaults below.
# 2. Load the per-user config file (default path: `~/.crystal-bin-installer.yml`,
#    overridable via `--config PATH`). Values set in the file override
#    the defaults.
# 3. Finally apply CLI flags. For scalar options (dir, dest, release,
#    fetch, force) they override everything; `--skip` is additive so
#    the config file and the CLI flag union their project lists.
# ---------------------------------------------------------------------------

config_path = CrystalBinInstaller::DEFAULT_CONFIG_PATH

# First pass: extract --config early so the file can be loaded before the
# main pass applies CLI overrides in the correct order.
ARGV.each_with_index do |arg, idx|
  case arg
  when "--config"
    config_path = ARGV[idx + 1] if idx + 1 < ARGV.size
  when .starts_with?("--config=")
    config_path = arg.sub("--config=", "")
  end
end

config = CrystalBinInstaller::Config.load(config_path)

source_dir = config.dir || File.join(Path.home.to_s, "prod-crystal")
dest_dir = config.dest || File.join(Path.home.to_s, "bin")
release = config.release.nil? ? true : config.release.not_nil!
skip = config.skip.dup
dry_run = false
fetch = config.fetch.nil? ? true : config.fetch.not_nil!
force = config.force.nil? ? false : config.force.not_nil!

parser = OptionParser.parse do |p|
  p.banner = <<-BANNER
    Usage: crystal-bin-installer [options]

    Walks the source directory, compiles each Crystal project whose
    `shard.yml` declares a `targets:` section, and installs the resulting
    binaries into the destination directory.

    A per-user config file is read by default from
    `~/.crystal-bin-installer.yml` (see README). Keys supported: `dir`,
    `dest`, `release`, `fetch`, `force`, `skip` (list).

    Options:
    BANNER

  p.on("--config PATH", "Path to the user config file (default: ~/.crystal-bin-installer.yml)") { |v| config_path = v }
  p.on("--dir PATH", "Source directory (default: ~/prod-crystal)") { |v| source_dir = v }
  p.on("--dest PATH", "Destination directory (default: ~/bin)") { |v| dest_dir = v }
  p.on("--dev", "Compile in development mode (faster, not optimised)") { release = false }
  p.on("--skip NAME[,NAME...]", "Projects to exclude (additive with the config file)") do |v|
    skip.concat(v.split(',').map(&.strip).reject(&.empty?))
  end
  p.on("--dry-run", "Report what would be done without touching the disk") { dry_run = true }
  p.on("--no-fetch", "Do not run `git fetch` before the sync check") { fetch = false }
  p.on("--force", "Skip git sync checks (build even if the repo is dirty)") { force = true }
  p.on("-v", "--version", "Print the installer version and exit") do
    puts CrystalBinInstaller::VERSION
    exit 0
  end
  p.on("-h", "--help", "Show this help and exit") do
    puts p
    exit 0
  end

  p.invalid_option do |flag|
    STDERR.puts "Unknown option: #{flag}"
    STDERR.puts p
    exit 1
  end
end

installer = CrystalBinInstaller::Installer.new(
  source_dir: source_dir,
  dest_dir: dest_dir,
  release: release,
  skip: skip.uniq,
  dry_run: dry_run,
  fetch: fetch,
  force: force,
)

results = installer.run
CrystalBinInstaller.print_summary(results)

# Exit non-zero if any build failed.
exit 1 if results.any?(&.status.failed?)
