require "./spec_helper"

# Helper: creates a temporary directory with an arbitrary `shard.yml` content
# and yields its path to the block.
private def with_shard(content : String, &)
  tmp = File.tempname("cbi-spec")
  Dir.mkdir_p(tmp)
  shard = File.join(tmp, "shard.yml")
  File.write(shard, content)
  begin
    yield shard, tmp
  ensure
    FileUtils.rm_rf(tmp)
  end
end

describe BinInstaller::Installer do
  describe "#extract_targets" do
    it "returns target names when `targets:` is present" do
      yaml = <<-YAML
        name: demo
        version: 0.1.0
        targets:
          demo:
            main: src/demo.cr
          helper:
            main: src/helper.cr
        YAML

      with_shard(yaml) do |shard, _|
        installer = BinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should eq(%w[demo helper])
      end
    end

    it "returns an empty array when `targets:` is missing" do
      yaml = <<-YAML
        name: pure-lib
        version: 0.1.0
        YAML

      with_shard(yaml) do |shard, _|
        installer = BinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should be_empty
      end
    end

    it "returns an empty array on malformed YAML" do
      with_shard("not: valid: yaml: here:", &->(shard : String, _ignore : String) {
        installer = BinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should be_empty
      })
    end
  end

  describe "#git_sync_issue" do
    it "detects a non-git directory" do
      tmp = File.tempname("cbi-nonrepo")
      Dir.mkdir_p(tmp)
      begin
        installer = BinInstaller::Installer.new("/tmp", "/tmp", fetch: false)
        installer.git_sync_issue(tmp).should eq("pas un dépôt git")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe BinInstaller::Config do
  describe ".load" do
    it "returns an empty config when the file does not exist" do
      config = BinInstaller::Config.load("/nonexistent/path.yml")
      config.dir.should be_nil
      config.dest.should be_nil
      config.release.should be_nil
      config.skip.should be_empty
    end

    it "parses all supported keys" do
      yaml = <<-YAML
        dir: /tmp/src
        dest: /tmp/bin
        release: false
        fetch: false
        force: true
        link: true
        skip:
          - alpha
          - beta
        YAML

      tmp = File.tempname("cbi-config", ".yml")
      File.write(tmp, yaml)
      begin
        config = BinInstaller::Config.load(tmp)
        config.dir.should eq("/tmp/src")
        config.dest.should eq("/tmp/bin")
        config.release.should eq(false)
        config.fetch.should eq(false)
        config.force.should eq(true)
        config.link.should eq(true)
        config.skip.should eq(%w[alpha beta])
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    it "leaves link unset when the YAML key is absent" do
      yaml = "dir: /tmp/src\n"
      tmp = File.tempname("cbi-config-nolink", ".yml")
      File.write(tmp, yaml)
      begin
        config = BinInstaller::Config.load(tmp)
        config.link.should be_nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    it "returns an empty config on malformed YAML" do
      tmp = File.tempname("cbi-config-bad", ".yml")
      File.write(tmp, "not: valid: yaml: at: all:")
      begin
        config = BinInstaller::Config.load(tmp)
        config.skip.should be_empty
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end
end

# Behavioural specs for the link mode. The unit specs above cover the
# Config + extract_targets + git_sync_issue surface; here we drive the
# private install_binary path indirectly by stubbing a fake source
# tree (no real `shards build` run) and checking the on-disk shape of
# the destination.
describe "Installer · link mode" do
  it "creates a symlink instead of a copy when link: true" do
    src_root = File.tempname("cbi-src")
    dst_root = File.tempname("cbi-dst")
    Dir.mkdir_p(src_root)
    Dir.mkdir_p(dst_root)
    binary = File.join(src_root, "fake-bin")
    File.write(binary, "#!/bin/sh\necho fake\n")
    File.chmod(binary, 0o755)
    dest_file = File.join(dst_root, "fake-bin")

    begin
      installer = BinInstaller::Installer.new(
        source_dir: src_root,
        dest_dir: dst_root,
        link: true,
      )
      # Drive the private helper through `Object#__send__`-equivalent
      # direct call: in Crystal, calling a private method from a spec
      # is allowed when both live in the same compilation unit.
      installer.send_install(binary, dest_file)

      File.symlink?(dest_file).should be_true
      File.exists?(dest_file).should be_true # the link resolves
      # Compare resolved paths on both sides — on macOS `/var` is itself
      # a symlink to `/private/var`, so `File.expand_path(binary)` and
      # `File.realpath(dest_file)` only line up after a real-path
      # normalisation of both ends.
      File.realpath(dest_file).should eq(File.realpath(binary))
    ensure
      File.delete(dest_file) if File.symlink?(dest_file) || File.exists?(dest_file)
      File.delete(binary) if File.exists?(binary)
      Dir.delete(src_root) if Dir.exists?(src_root)
      Dir.delete(dst_root) if Dir.exists?(dst_root)
    end
  end

  it "copies the file (no symlink) when link: false" do
    src_root = File.tempname("cbi-src-cp")
    dst_root = File.tempname("cbi-dst-cp")
    Dir.mkdir_p(src_root)
    Dir.mkdir_p(dst_root)
    binary = File.join(src_root, "fake-bin")
    File.write(binary, "#!/bin/sh\necho fake\n")
    File.chmod(binary, 0o755)
    dest_file = File.join(dst_root, "fake-bin")

    begin
      installer = BinInstaller::Installer.new(
        source_dir: src_root,
        dest_dir: dst_root,
        link: false,
      )
      installer.send_install(binary, dest_file)

      File.symlink?(dest_file).should be_false
      File.exists?(dest_file).should be_true
      # File mode preserved at 0o755
      (File.info(dest_file).permissions.to_i & 0o777).should eq(0o755)
    ensure
      File.delete(dest_file) if File.exists?(dest_file)
      File.delete(binary) if File.exists?(binary)
      Dir.delete(src_root) if Dir.exists?(src_root)
      Dir.delete(dst_root) if Dir.exists?(dst_root)
    end
  end

  it "replaces an existing file/symlink at the destination idempotently" do
    src_root = File.tempname("cbi-src-rep")
    dst_root = File.tempname("cbi-dst-rep")
    Dir.mkdir_p(src_root)
    Dir.mkdir_p(dst_root)
    binary = File.join(src_root, "fake-bin")
    File.write(binary, "v2")
    File.chmod(binary, 0o755)
    dest_file = File.join(dst_root, "fake-bin")
    # Pre-existing regular file at the destination, e.g. from a
    # previous copy-mode run.
    File.write(dest_file, "v1")

    begin
      installer = BinInstaller::Installer.new(
        source_dir: src_root,
        dest_dir: dst_root,
        link: true,
      )
      installer.send_install(binary, dest_file)

      File.symlink?(dest_file).should be_true
      File.read(dest_file).should eq("v2") # the link resolves to v2
    ensure
      File.delete(dest_file) if File.symlink?(dest_file) || File.exists?(dest_file)
      File.delete(binary) if File.exists?(binary)
      Dir.delete(src_root) if Dir.exists?(src_root)
      Dir.delete(dst_root) if Dir.exists?(dst_root)
    end
  end
end
