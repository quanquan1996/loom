defmodule Loom.Backends do
  @moduledoc """
  Which agent CLIs this Loom offers, and the one a new session starts on.

  One small file, `backends.json` in Loom's directory, for the whole instance
  (not per device): `{"enabled": [...], "default": "..."}`. Until it is
  written, the CLIs found on this machine are the ones offered, so a Loom with
  only Kiro installed shows only Kiro.

  A switch only tidies the interface: it takes a CLI out of the menus. Nothing
  refuses a session on a CLI that is switched off, and sessions already on it
  carry on.

  The one thing that does follow it is Claude Code's place as the owner of
  shared configuration. With Claude Code on, the other CLIs read `~/.claude`
  (rules, memory, skills) and cannot write it (`Loom.Agent.Sandbox`), and
  Loom's own sessions (the bell, a notice, hiring an employee) run on it. With
  Claude Code off there is no such owner: nothing is bound read-only, and
  those sessions run on the default CLI (`internal/0`).
  """

  alias Loom.Agent.Backend

  @kinds [:claude_code, :codex, :kiro, :agy]

  @type t :: %{enabled: [Backend.kind()], default: Backend.kind(), installed: [Backend.kind()]}

  @doc "Every CLI Loom knows, in menu order."
  def kinds, do: @kinds

  @doc "What is offered, the default among it, and what is installed here."
  @spec get() :: t()
  def get do
    installed = Enum.filter(@kinds, &installed?/1)
    saved = read()

    enabled =
      case parse_list(saved["enabled"]) do
        [] -> if(installed == [], do: @kinds, else: installed)
        list -> list
      end

    default =
      case Backend.parse(saved["default"]) do
        {:ok, kind} -> if(kind in enabled, do: kind, else: hd(enabled))
        :error -> hd(enabled)
      end

    %{enabled: enabled, default: default, installed: installed}
  end

  @doc """
  Save the switches and the default. At least one CLI stays on; a default that
  is switched off moves to the first one that is on.
  """
  @spec put(map()) :: {:ok, t()} | {:error, :invalid}
  def put(params) when is_map(params) do
    with [_ | _] = enabled <- parse_list(params["enabled"]) do
      default =
        case Backend.parse(params["default"]) do
          {:ok, kind} -> if(kind in enabled, do: kind, else: hd(enabled))
          :error -> hd(enabled)
        end

      body = Jason.encode!(%{enabled: enabled, default: default})
      tmp = path() <> ".tmp"
      File.mkdir_p!(Path.dirname(path()))
      File.write!(tmp, body)
      File.rename!(tmp, path())
      {:ok, get()}
    else
      _ -> {:error, :invalid}
    end
  end

  def put(_), do: {:error, :invalid}

  @doc "Whether `kind` is switched on."
  def enabled?(kind), do: kind in get().enabled

  @doc "The CLI Loom's own sessions run on: Claude Code while it is on, else the default."
  @spec internal() :: Backend.kind()
  def internal do
    %{enabled: enabled, default: default} = get()
    if :claude_code in enabled, do: :claude_code, else: default
  end

  defp installed?(kind) do
    Enum.any?(executables(kind), fn name ->
      System.find_executable(name) || System.find_executable(Path.expand("~/.local/bin/" <> name))
    end)
  end

  defp executables(kind) do
    config = Application.get_env(:loom, Loom.Agent, [])

    case kind do
      :claude_code -> [config[:claude_cli] || "claude"]
      :codex -> [config[:codex_cli] || "codex"]
      :agy -> [config[:agy_cli] || "agy"]
      :kiro -> if(config[:kiro_cli], do: [config[:kiro_cli]], else: ["kiro-cli-chat", "kiro-cli"])
    end
  end

  # In menu order, whatever order they were sent in; unknown names dropped.
  defp parse_list(list) when is_list(list) do
    given = for name <- list, {:ok, kind} <- [Backend.parse(name)], do: kind
    Enum.filter(@kinds, &(&1 in given))
  end

  defp parse_list(_), do: []

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = map} <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp path, do: Path.join(Loom.Agent.Store.home(), "backends.json")
end
