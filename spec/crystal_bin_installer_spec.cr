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

describe CrystalBinInstaller::Installer do
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
        installer = CrystalBinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should eq(%w[demo helper])
      end
    end

    it "returns an empty array when `targets:` is missing" do
      yaml = <<-YAML
        name: pure-lib
        version: 0.1.0
        YAML

      with_shard(yaml) do |shard, _|
        installer = CrystalBinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should be_empty
      end
    end

    it "returns an empty array on malformed YAML" do
      with_shard("not: valid: yaml: here:", &->(shard : String, _ignore : String) {
        installer = CrystalBinInstaller::Installer.new("/tmp", "/tmp")
        installer.extract_targets(shard).should be_empty
      })
    end
  end

  describe "#git_sync_issue" do
    it "detects a non-git directory" do
      tmp = File.tempname("cbi-nonrepo")
      Dir.mkdir_p(tmp)
      begin
        installer = CrystalBinInstaller::Installer.new("/tmp", "/tmp", fetch: false)
        installer.git_sync_issue(tmp).should eq("pas un dépôt git")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end
end

describe CrystalBinInstaller::Config do
  describe ".load" do
    it "returns an empty config when the file does not exist" do
      config = CrystalBinInstaller::Config.load("/nonexistent/path.yml")
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
        skip:
          - alpha
          - beta
        YAML

      tmp = File.tempname("cbi-config", ".yml")
      File.write(tmp, yaml)
      begin
        config = CrystalBinInstaller::Config.load(tmp)
        config.dir.should eq("/tmp/src")
        config.dest.should eq("/tmp/bin")
        config.release.should eq(false)
        config.fetch.should eq(false)
        config.force.should eq(true)
        config.skip.should eq(%w[alpha beta])
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    it "returns an empty config on malformed YAML" do
      tmp = File.tempname("cbi-config-bad", ".yml")
      File.write(tmp, "not: valid: yaml: at: all:")
      begin
        config = CrystalBinInstaller::Config.load(tmp)
        config.skip.should be_empty
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end
end
