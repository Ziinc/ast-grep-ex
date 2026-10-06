defmodule AstGrep.Native.BuildTest do
  use ExUnit.Case, async: true

  alias AstGrep.Native.Build

  describe "force_build_opts/2" do
    test "forces a build when AST_GREP_BUILD is 1 or true" do
      assert Build.force_build_opts("1", :prod) == [force_build: true]
      assert Build.force_build_opts("true", :prod) == [force_build: true]
    end

    test "forces a build in the :dev and :test environments" do
      assert Build.force_build_opts(nil, :dev) == [force_build: true]
      assert Build.force_build_opts(nil, :test) == [force_build: true]
      assert Build.force_build_opts("0", :test) == [force_build: true]
    end

    test "otherwise leaves :force_build unset, so that RustlerPrecompiled reads the app config" do
      # `config :rustler_precompiled, :force_build, ast_grep: true` only
      # applies when the option is not given to `use RustlerPrecompiled`.
      assert Build.force_build_opts(nil, :prod) == []
      assert Build.force_build_opts("", :prod) == []
      assert Build.force_build_opts("0", :prod) == []
      assert Build.force_build_opts("false", :bench) == []
    end
  end
end
