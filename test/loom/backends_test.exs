defmodule Loom.BackendsTest do
  use ExUnit.Case, async: false

  alias Loom.Backends

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-backends-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = Application.get_env(:loom, :home)
    Application.put_env(:loom, :home, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:loom, :home, old),
        else: Application.delete_env(:loom, :home)

      File.rm_rf(dir)
    end)

    :ok
  end

  test "unset: what is installed is offered, and the first of it is the default" do
    %{enabled: enabled, default: default, installed: installed} = Backends.get()
    assert enabled == if(installed == [], do: Backends.kinds(), else: installed)
    assert default == hd(enabled)
  end

  test "saved switches come back in menu order, unknown names dropped" do
    assert {:ok, %{enabled: [:kiro, :agy], default: :agy}} =
             Backends.put(%{"enabled" => ["agy", "nope", "kiro"], "default" => "agy"})

    assert %{enabled: [:kiro, :agy], default: :agy} = Backends.get()
    refute Backends.enabled?(:claude_code)
  end

  test "a default that is switched off moves to the first one on" do
    assert {:ok, %{default: :codex}} =
             Backends.put(%{"enabled" => ["codex", "kiro"], "default" => "claude_code"})
  end

  test "at least one stays on" do
    assert {:error, :invalid} = Backends.put(%{"enabled" => [], "default" => "kiro"})
    assert {:error, :invalid} = Backends.put(%{"enabled" => ["nope"]})
  end

  test "Loom's own sessions run on Claude Code while it is on, else on the default" do
    {:ok, _} = Backends.put(%{"enabled" => ["claude_code", "kiro"], "default" => "kiro"})
    assert Backends.internal() == :claude_code

    {:ok, _} = Backends.put(%{"enabled" => ["kiro", "agy"], "default" => "agy"})
    assert Backends.internal() == :agy
  end

  test "with Claude Code off, other backends are not fenced off its directory" do
    {:ok, _} = Backends.put(%{"enabled" => ["kiro"], "default" => "kiro"})
    assert {"kiro-cli", ["acp"]} = Loom.Agent.Sandbox.guard_claude("kiro-cli", ["acp"])
  end
end
