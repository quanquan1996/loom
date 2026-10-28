defmodule Loom.Agent.ProcTest do
  # A real process behind a FIFO and a file: what a restart leaves running,
  # and what the next node takes back.
  use ExUnit.Case, async: false

  alias Loom.Agent.Proc

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(previous, :data_dir, dir))
    on_exit(fn -> Application.put_env(:loom, Loom.Agent, previous) end)
    :ok
  end

  # Echoes each line, then a second time a moment later — while nobody may be
  # reading.
  @echo ~s(while read l; do echo "got $l"; sleep 0.3; echo "later $l"; done)

  defp spawn_sh(script, cwd), do: Proc.spawn("a_proc", "/bin/sh", ["-c", script], cwd)

  # Poll until the output so far contains `text`.
  defp read_until(proc, text, acc \\ "", tries \\ 100)
  defp read_until(_proc, text, acc, 0), do: flunk("never saw #{inspect(text)} in #{inspect(acc)}")

  defp read_until(proc, text, acc, tries) do
    {data, proc, _} = Proc.poll(proc)
    acc = acc <> data

    if String.contains?(acc, text) do
      {proc, acc}
    else
      Process.sleep(30)
      read_until(proc, text, acc, tries - 1)
    end
  end

  test "a process let go of keeps running, and is taken back where it was", %{tmp_dir: dir} do
    {:ok, proc} = spawn_sh(@echo, dir)
    :ok = Proc.write(proc, "a\n")
    {proc, seen} = read_until(proc, "got a")
    refute seen =~ "later a"
    Proc.checkpoint(proc, %{note: "after got a"})

    # The node goes away: every descriptor closed, nothing killed.
    Proc.close(proc)
    Process.sleep(500)

    {:ok, proc, state} = Proc.adopt("a_proc")
    assert state == %{note: "after got a"}
    assert Proc.alive?(proc)

    # What it said meanwhile is there, and nothing from before it again.
    {proc, seen} = read_until(proc, "later a")
    refute seen =~ "got a"

    # It never saw EOF on stdin: the same process takes the next line.
    :ok = Proc.write(proc, "b\n")
    {proc, _} = read_until(proc, "got b")

    Proc.kill(proc)
    refute Proc.alive?(proc)
    assert Proc.adopt("a_proc") == :error
  end

  test "one that died while nobody watched still says what it said, then that it exited",
       %{tmp_dir: dir} do
    {:ok, proc} = spawn_sh(~s(read l; sleep 0.2; echo "bye $l"; exit 3), dir)
    :ok = Proc.write(proc, "x\n")
    Proc.checkpoint(proc, %{})
    Proc.close(proc)
    Process.sleep(500)

    {:ok, proc, %{}} = Proc.adopt("a_proc")
    {data, proc, :alive} = Proc.poll(proc)
    assert data =~ "bye x"
    assert {"", _proc, {:exited, 3}} = Proc.poll(proc)
    # Exited is the end: nothing left to adopt.
    assert Proc.adopt("a_proc") == :error
  end

  test "without a checkpoint there is nothing to adopt", %{tmp_dir: dir} do
    {:ok, proc} = spawn_sh(@echo, dir)
    Proc.close(proc)
    assert Proc.adopt("a_proc") == :error
    Proc.kill(proc)
  end
end
