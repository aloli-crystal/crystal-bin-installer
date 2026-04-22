require "option_parser"
require "./crystal_bin_installer"

source_dir = File.join(Path.home.to_s, "prod-crystal")
dest_dir = File.join(Path.home.to_s, "bin")
release = true
skip = [] of String
dry_run = false
fetch = true
force = false

parser = OptionParser.parse do |p|
  p.banner = <<-BANNER
    Usage: crystal-bin-installer [options]

    Walks the source directory, compiles each Crystal project whose
    `shard.yml` declares a `targets:` section, and installs the resulting
    binaries into the destination directory.

    Options:
    BANNER

  p.on("--dir PATH", "Source directory (default: ~/prod-crystal)") { |v| source_dir = v }
  p.on("--dest PATH", "Destination directory (default: ~/bin)") { |v| dest_dir = v }
  p.on("--dev", "Compile in development mode (faster, not optimised)") { release = false }
  p.on("--skip NAME[,NAME...]", "Projects to exclude (comma-separated)") { |v| skip = v.split(',').map(&.strip).reject(&.empty?) }
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
  skip: skip,
  dry_run: dry_run,
  fetch: fetch,
  force: force,
)

results = installer.run
CrystalBinInstaller.print_summary(results)

# Exit non-zero if any build failed.
exit 1 if results.any?(&.status.failed?)
