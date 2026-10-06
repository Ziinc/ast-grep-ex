defmodule AstGrep.ConfigTest do
  use ExUnit.Case, async: true

  alias AstGrep.{Config, Error}

  @project Path.expand("../fixtures/project", __DIR__)

  describe "load/1" do
    test "resolves rule and util dirs relative to the config file" do
      path = Path.join(@project, "sgconfig.yml")

      assert {:ok, %Config{} = config} = Config.load(path)
      assert config.path == path
      assert config.root == @project
      assert config.rule_dirs == [Path.join(@project, "rules")]
      assert config.util_dirs == [Path.join(@project, "utils")]
    end

    test "expands relative config paths against the current directory" do
      relative = Path.relative_to_cwd(Path.join(@project, "sgconfig.yml"))
      assert {:ok, %Config{root: @project}} = Config.load(relative)
    end

    @tag :tmp_dir
    test "accepts missing keys, single strings and .yaml files", %{tmp_dir: dir} do
      path = Path.join(dir, "sgconfig.yaml")

      File.write!(path, "ruleDirs: my_rules\n")
      assert {:ok, %Config{rule_dirs: [rule_dir], util_dirs: []}} = Config.load(path)
      assert rule_dir == Path.join(dir, "my_rules")

      File.write!(path, "")
      assert {:ok, %Config{rule_dirs: [], util_dirs: []}} = Config.load(path)

      File.write!(path, "ruleDirs: [a, ../b]\nutilDirs: [c]\ntestConfigs: []\n")
      assert {:ok, config} = Config.load(path)
      assert config.rule_dirs == [Path.join(dir, "a"), Path.expand("../b", dir)]
      assert config.util_dirs == [Path.join(dir, "c")]
    end

    @tag :tmp_dir
    test "returns errors with the config path", %{tmp_dir: dir} do
      path = Path.join(dir, "sgconfig.yml")

      assert {:error, %Error{path: ^path, message: message}} = Config.load(path)
      assert message =~ "cannot read config"

      File.write!(path, "ruleDirs: [\n")
      assert {:error, %Error{path: ^path, message: message}} = Config.load(path)
      assert message =~ "invalid config YAML"

      File.write!(path, "- a\n- b\n")
      assert {:error, %Error{message: message}} = Config.load(path)
      assert message =~ "must be a YAML mapping"

      File.write!(path, "ruleDirs:\n  a: b\n")
      assert {:error, %Error{message: message}} = Config.load(path)
      assert message =~ "`ruleDirs` must be a list of strings"

      File.write!(path, "utilDirs: [1]\n")
      assert {:error, %Error{message: message}} = Config.load(path)
      assert message =~ "`utilDirs` must be a list of strings"

      assert_raise Error, fn -> Config.load!(path) end
    end
  end

  describe "find/1" do
    test "finds the config in the start directory" do
      assert Config.find(@project) == {:ok, Path.join(@project, "sgconfig.yml")}
    end

    test "searches parent directories" do
      assert Config.find(Path.join(@project, "lib/generated")) ==
               {:ok, Path.join(@project, "sgconfig.yml")}
    end

    @tag :tmp_dir
    test "finds sgconfig.yaml and returns :error when there is none", %{tmp_dir: dir} do
      nested = Path.join(dir, "a/b")
      File.mkdir_p!(nested)

      # The ExUnit tmp dir lives inside this repository, which has no config.
      assert Config.find(nested) == :error

      File.write!(Path.join(dir, "sgconfig.yaml"), "ruleDirs: []\n")
      assert Config.find(nested) == {:ok, Path.join(dir, "sgconfig.yaml")}
    end
  end
end
