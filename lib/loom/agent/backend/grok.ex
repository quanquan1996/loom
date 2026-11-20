defmodule Loom.Agent.Backend.Grok do
  @moduledoc """
  xAI's Grok Build, `grok agent stdio`: a flavour of `Loom.Agent.Backend.Acp`.
  Measured on 1.0.89, 2026-11-20, signed in.

  It resumes a conversation by id. The model (`-m`) is named when the process
  is spawned, so a change of model lets the process go. `--rules` does not
  reach `agent stdio` (measured), and ACP offers it no system prompt: the
  session's instructions go ahead of a new conversation's first message.
  `--always-approve` runs tools unasked. It sends no `usage_update`: the
  prompt's reply carries the turn's tokens and how full the context is, and
  the model's window comes with the session. Its own notifications
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
    ["agent", "--always-approve"] ++ option("-m", handle.model) ++ ["stdio"]
  end

  @impl Acp
  def instructions_in_prompt?, do: true

  @impl Acp
  def state_dirs, do: ["~/.grok"]

  defp option(flag, value) when is_binary(value) and value != "", do: [flag, value]
  defp option(_flag, _value), do: []
end
