defmodule Loom.Agent.Backend.CodeBuddy do
  @moduledoc """
  Tencent's CodeBuddy Code, `codebuddy --acp`: a flavour of
  `Loom.Agent.Backend.Acp`. Handshake measured on 2.185.0, 2026-11-20; a turn
  has not been measured yet (no login).

  It has `session/load` and no resume, so a conversation it already has is
  loaded and the replay dropped. The model (`--model`) and the session's
  instructions (`--append-system-prompt`) are named when the process is
  spawned, so a change of model lets the process go. `-y` skips permission
  prompts except the ones it rates high; those are allowed once.

  It signs in with WeChat (the mainland service) or Google/GitHub (the
  international one), in its own terminal UI. `LOOM_CODEBUDDY_CLI` pins the
  binary; `cbc` is its other name.
  """
  use Loom.Agent.Backend.Acp

  @impl Acp
  def name, do: "codebuddy"
  @impl Acp
  def key, do: "codebuddy"

  @impl Acp
  def executables do
    case Application.get_env(:loom, Loom.Agent, [])[:codebuddy_cli] do
      nil -> ["codebuddy", "cbc"]
      configured -> [configured]
    end
  end

  @impl Acp
  def spawn_args(handle) do
    ["--acp", "-y"] ++
      option("--model", handle.model) ++ option("--append-system-prompt", handle.instructions)
  end

  @impl Acp
  def open, do: :load
  @impl Acp
  def state_dirs, do: ["~/.codebuddy"]

  defp option(flag, value) when is_binary(value) and value != "", do: [flag, value]
  defp option(_flag, _value), do: []
end
