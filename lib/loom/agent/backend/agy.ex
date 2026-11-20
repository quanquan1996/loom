defmodule Loom.Agent.Backend.Agy do
  @moduledoc """
  Google's Antigravity CLI, `agy acp`: a flavour of `Loom.Agent.Backend.Acp`.
  Measured on agy 1.5.13, 2026-11-20.

  `session/resume` does not replay the conversation (`session/load` does, and
  is not used). `initialize` advertises `_meta.antigravity.systemPrompt.append`:
  the session's instructions go as `_meta` on new and on resume, so there is no
  agent file to write or forget. `session/set_model` takes a `modelId` from
  `agy models` (`gemini-4-neon-high`, …); the level of thinking is part of the
  id, so there are no efforts, and a warm process changes model in place.

  agy signs in with a personal Google account, and Google turns requests from
  cloud addresses away (429 from AWS, measured 2026-11-19): it is for a Loom at
  home.
  """
  use Loom.Agent.Backend.Acp

  @impl Acp
  def name, do: "agy"
  @impl Acp
  def key, do: "agy"
  @impl Acp
  def executables, do: [Application.get_env(:loom, Loom.Agent, [])[:agy_cli] || "agy"]
  @impl Acp
  def spawn_args(_handle), do: ["acp", "--dangerously-skip-permissions"]
  # Its login, conversations and logs.
  @impl Acp
  def state_dirs, do: ["~/.gemini"]
  @impl Acp
  def model_in_place?, do: true

  @impl Acp
  def session_params(handle, params) do
    case handle.instructions do
      text when is_binary(text) and text != "" ->
        Map.put(params, :_meta, %{antigravity: %{systemPrompt: %{append: text}}})

      _ ->
        params
    end
  end
end
