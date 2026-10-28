defmodule Loom.OneShotTest do
  # Not async: CLAUDE_CONFIG_DIR is global.
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-oneshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("CLAUDE_CONFIG_DIR")
    System.put_env("CLAUDE_CONFIG_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("CLAUDE_CONFIG_DIR", previous),
        else: System.delete_env("CLAUDE_CONFIG_DIR")

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "the login in Claude Code's settings goes along, though the settings do not", %{dir: dir} do
    File.write!(
      Path.join(dir, "settings.json"),
      ~s({"env": {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": "us-west-2"}, "theme": "dark"})
    )

    env = Map.new(Loom.OneShot.env())
    assert env["CLAUDE_CODE_USE_BEDROCK"] == "1"
    assert env["AWS_REGION"] == "us-west-2"
  end

  test "no settings file, or a bad one, is no extra environment", %{dir: dir} do
    assert is_list(Loom.OneShot.env())
    File.write!(Path.join(dir, "settings.json"), "not json")
    assert is_list(Loom.OneShot.env())
  end
end
