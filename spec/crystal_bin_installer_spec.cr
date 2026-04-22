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
