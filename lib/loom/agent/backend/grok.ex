defmodule Loom.Agent.Backend.Grok do
  @moduledoc """
  xAI's Grok Build, `grok agent stdio`: a flavour of `Loom.Agent.Backend.Acp`.
  Handshake measured on 1.0.89, 2026-11-20; a turn has not been measured yet
  (no login).

  It resumes a conversation by id. The model (`-m`) and the session's
  instructions (`--rules`, appended to its system prompt) are named when the
  process is spawned, so a change of model lets the process go.
  `--always-approve` runs tools unasked. Its own notifications
  (`_x.ai/session/setup`, …) are not a turn's and are dropped.

  It signs in with a Grok account (`grok login --device-auth` on a machine
  with no browser). `LOOM_GROK_CLI` pins the binary.
  """
  use Loom.Agent.Backend.Acp

  @impl Acp
  def name, do: "grok"
  @impl Acp
  def key, do: "grok"
  @impl Acp
  def executables, do: [Application.get_env(:loom, Loom.Agent, [])[:grok_cli] || "grok"]

  @impl Acp
  def spawn_args(handle) do
    option("--rules", handle.instructions) ++
      ["agent", "--always-approve"] ++ option("-m", handle.model) ++ ["stdio"]
  end

  @impl Acp
  def state_dirs, do: ["~/.grok"]

  defp option(flag, value) when is_binary(value) and value != "", do: [flag, value]
  defp option(_flag, _value), do: []
end
