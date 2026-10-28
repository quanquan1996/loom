defmodule Loom.Agent.Proc do
  @moduledoc """
  An agent CLI that outlives the node: stdin a FIFO, stdout a file, in a
  session of its own. What lets a restart leave a turn running and pick it up
  again afterwards.

  A port ties the CLI's stdio to this node's pipes, so a restart closes them.
  Measured on a two-step shell task, with both pipes closed after the first
  tool call had started:

    * Claude Code (2.1.312) finished the turn — both steps and the reply, all
      in its own transcript — and exited 0. But its output had nowhere to go.
    * Kiro (1.28.1) took EOF on stdin as "quit" and exited 0 after the first
      step, abandoning the rest.

  So neither is spawned on a port:

    * stdin is a FIFO the CLI opens read-write (`<>`), so it never sees EOF,
      whoever comes and goes on the other end;
    * stdout is appended to a file, which never breaks and keeps everything
      said while nobody was reading;
    * `setsid` puts it in a session of its own, and `sh` stays as its parent
      to record its pid and exit status.

  Measured the same way: a Kiro turn left mid-tool for 25 s finished both
  steps, and after reattaching the same process took the next prompt.

  Output is read on a timer (`@poll_ms`) from an offset kept here. After each
  batch the backend saves its decoding state beside it (`checkpoint/2`), so
  `adopt/1` hands back exactly the offset and the state that go together — no
  replay, nothing decoded twice. systemd must not kill the CLI when the node
  stops: `KillMode=process` in `rel/systemd/loom.service`.

  Everything lives in `<session>/proc/`: `in`, `out`, `err`, `pid`, `status`,
  `state`.
  """

  alias Loom.Agent.Store

  defstruct [:dir, :pid, :in, :out, :ref, offset: 0]

  @type t :: %__MODULE__{}

  # Fast enough that streamed text reads as streaming.
  @poll_ms 50

  # Recognises our own `sh` in `/proc/<pid>/cmdline` — a pid alone may have
  # been reused by the time a node comes back.
  @marker "loom-agent"

  @script """
  exec </dev/null >/dev/null 2>&1
  d=$1; shift
  echo $$ > "$d/pid"
  "$@" <>"$d/in" >>"$d/out" 2>>"$d/err"
  echo $? > "$d/status"
  """

  @doc "Where a session's process keeps its files."
  def dir(session_id), do: Path.join(Store.session_dir(session_id), "proc")

  @doc """
  Start `exe args` in `cwd`, detached. Returns once its pid is known; the
  first poll is already scheduled on the calling process.
  """
  @spec spawn(String.t(), String.t(), [String.t()], String.t()) :: {:ok, t} | {:error, term()}
  def spawn(session_id, exe, args, cwd) do
    dir = dir(session_id)
    File.mkdir_p!(dir)
    Enum.each(~w(pid status out err in state), &File.rm(Path.join(dir, &1)))

    with :ok <- run("mkfifo", [Path.join(dir, "in")], dir),
         :ok <- File.write(Path.join(dir, "out"), ""),
         :ok <- run("setsid", ["-f", "sh", "-c", @script, @marker, dir, exe | args], cwd),
         {:ok, pid} <- await_pid(dir, 200) do
      open(dir, pid, 0)
    end
  end

  @doc """
  Take back the process a previous node left behind, with the decoding state
  saved at the offset it had reached. Also when the process has since died:
  what it said before dying is still in the file, and the first polls read
  it before reporting the exit.
  """
  @spec adopt(String.t()) :: {:ok, t, map()} | :error
  def adopt(session_id) do
    dir = dir(session_id)

    with {:ok, bin} <- File.read(Path.join(dir, "state")),
         %{offset: offset, state: state} <- :erlang.binary_to_term(bin, [:safe]),
         {:ok, raw} <- File.read(Path.join(dir, "pid")),
         {pid, _} <- Integer.parse(raw),
         {:ok, proc} <- open(dir, pid, offset) do
      {:ok, proc, state}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp open(dir, pid, offset) do
    with {:ok, input} <- :file.open(Path.join(dir, "in"), [:read, :write, :raw, :binary]),
         {:ok, out} <- :file.open(Path.join(dir, "out"), [:read, :raw, :binary]),
         {:ok, _} <- :file.position(out, offset) do
      ref = make_ref()
      Process.send_after(self(), {:loom_proc, ref}, @poll_ms)
      {:ok, %__MODULE__{dir: dir, pid: pid, in: input, out: out, ref: ref, offset: offset}}
    end
  end

  @doc "Write to the process's stdin."
  def write(%__MODULE__{in: input}, data) do
    case :file.write(input, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One poll: whatever the process wrote since the last, and whether it is
  still there. An exit is reported only once its output has been drained.
  The next poll is scheduled unless it has exited.
  """
  @spec poll(t) :: {binary(), t, :alive | {:exited, integer() | nil}}
  def poll(proc) do
    # Liveness first: whatever a process wrote before it died is then
    # certain to be in this read.
    alive? = alive?(proc)
    data = read_all(proc.out, [])
    proc = %{proc | offset: proc.offset + byte_size(data)}

    if alive? or data != "" do
      schedule(proc)
      {data, proc, :alive}
    else
      # Nothing left to adopt.
      close(proc)
      File.rm(Path.join(proc.dir, "state"))
      {"", proc, {:exited, exit_status(proc)}}
    end
  end

  defp schedule(proc), do: Process.send_after(self(), {:loom_proc, proc.ref}, @poll_ms)

  defp read_all(out, acc) do
    case :file.read(out, 1_048_576) do
      {:ok, data} -> read_all(out, [acc | data])
      _ -> IO.iodata_to_binary(acc)
    end
  end

  @doc """
  Save the backend's decoding state as of `proc.offset`: what `adopt/1`
  resumes from. Written aside and renamed, so a node killed mid-write leaves
  the previous one.
  """
  def checkpoint(%__MODULE__{dir: dir, offset: offset}, state) do
    path = Path.join(dir, "state")
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(%{offset: offset, state: state})) do
      File.rename(tmp, path)
    end
  end

  @doc "Whether our process is still running."
  def alive?(%__MODULE__{dir: dir, pid: pid}) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} -> String.contains?(cmdline, @marker) and String.contains?(cmdline, dir)
      _ -> false
    end
  end

  defp exit_status(%__MODULE__{dir: dir}) do
    with {:ok, raw} <- File.read(Path.join(dir, "status")),
         {status, _} <- Integer.parse(raw) do
      status
    else
      _ -> nil
    end
  end

  @doc "Let go of the process and leave it running: the node is going away."
  def close(%__MODULE__{in: input, out: out}) do
    :file.close(input)
    :file.close(out)
    :ok
  end

  @doc "Kill the process and everything under it."
  def kill(%__MODULE__{} = proc) do
    Loom.Agent.Backend.ClaudeCode.kill_tree(proc.pid)
    close(proc)
    File.rm(Path.join(proc.dir, "state"))
    :ok
  end

  defp run(binary, args, cwd) do
    case System.cmd(binary, args, cd: cwd, env: Loom.ChildEnv.cmd_env(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, "#{binary} exited #{status}: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError -> {:error, "#{binary}: #{Exception.message(e)}"}
  end

  defp await_pid(_dir, 0), do: {:error, "the agent process did not start"}

  defp await_pid(dir, tries) do
    with {:ok, raw} <- File.read(Path.join(dir, "pid")),
         {pid, _} <- Integer.parse(raw) do
      {:ok, pid}
    else
      _ ->
        Process.sleep(10)
        await_pid(dir, tries - 1)
    end
  end
end
