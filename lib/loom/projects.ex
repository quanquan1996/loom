defmodule Loom.Projects do
  @moduledoc """
  Projects: a name, a working directory and standing instructions, shared by
  every session made in it. The ChatGPT idea, on a machine the agents can
  actually work in.

  - **The workspace is the sessions' cwd**, always
    `<home>/projects/<id>/workspace`: Loom makes it, owns it, and removes it
    with the project. Never a directory the user names, so where a project's
    files are is never a question. Every session in it starts there, so
    working files one session leaves are where the next one looks. Claude Code
    keys its memory by cwd, so each project gets memory of its own for free.
  - **The binding is permanent.** A session's cwd is fixed when it is made
    (`--resume` and Codex threads are tied to it), so a session never moves
    between projects.
  - **Instructions go in the system prompt**, appended to Loom's own, rather
    than into a `CLAUDE.md` in the workspace, so both backends get the same
    text and the agents cannot overwrite it. See `Loom.Agent.Session`.

  One process owns `<home>/projects.json`, the truth for what exists. Changes
  are broadcast on the lobby topic as `{:project_summary, project}` and
  `{:project_removed, id}`, so the sidebar never polls.
  """
  use GenServer

  require Logger

  @name __MODULE__
  @persisted ~w(id name instructions created_at)a
  @name_limit 80
  @instructions_limit 20_000

  # The workspace listing for the file tree. An agent can clone a repo or
  # install packages in there, so what is never a working file is skipped and
  # the rest is capped.
  @skip_dirs ~w(node_modules _build deps target dist build __pycache__ venv)
  @max_files 2000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Every project, oldest first."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "One project: `{:ok, project}` or `:error`."
  def get(id, server \\ @name)
  def get(nil, _server), do: :error
  def get(id, server), do: GenServer.call(server, {:get, id})

  @doc """
  Make a project, and its workspace, from `name` and optional `instructions`.
  String keys, as they come from JSON. `{:ok, project}` or `{:error, message}`.
  """
  def create(attrs, server \\ @name), do: GenServer.call(server, {:create, attrs})

  @doc """
  Change `name` and/or `instructions`.

  The project's live sessions are then told to rebuild their instructions.
  From the caller, not the server: a session starting up asks this server for
  its project, and must never wait on a server that is waiting on it.
  """
  def update(id, attrs, server \\ @name) do
    with {:ok, project} <- GenServer.call(server, {:update, id, attrs}) do
      for %{id: sid, project_id: ^id} <- Loom.Agent.list_sessions(),
          [{pid, _}] <- [Registry.lookup(Loom.Agent.Registry, sid)],
          do: send(pid, :refresh_instructions)

      {:ok, project}
    end
  end

  @doc """
  Forget a project and remove its workspace. Its sessions are the caller's to
  delete first; see `LoomWeb.ProjectController`.
  """
  def delete(id, server \\ @name), do: GenServer.call(server, {:delete, id})

  @doc "Where Loom keeps projects and their workspaces."
  def dir, do: Application.get_env(:loom, __MODULE__, [])[:dir] || Loom.Agent.Store.home()

  @doc "A project's working directory, which every session in it starts in."
  def workspace(%{id: id}), do: Path.join([dir(), "projects", id, "workspace"])

  @doc """
  What a session in `project` is told on top of Loom's own instructions: where
  the shared workspace is, and the user's standing instructions for it.
  """
  def instructions(project) do
    ws = workspace(project)

    base = """
    This session belongs to the Loom project "#{project.name}". Your working \
    directory, #{ws}, is the project's workspace, shared by every session in \
    the project: keep the working files of this project there — code, data, \
    drafts, notes — so that later sessions can find and continue them. Files \
    meant for the user to download still go in the output directory above.
    """

    case project.instructions do
      text when is_binary(text) and text != "" ->
        base <> "\nThe user's instructions for this project:\n\n" <> text <> "\n"

      _ ->
        base
    end
  end

  @doc "The JSON shape: the stored fields plus the workspace."
  def view(project) do
    project
    |> Map.take(@persisted)
    |> Map.put(:workspace, workspace(project))
  end

  # ── Workspace files ───────────────────────────────────────────────────────

  @doc """
  The workspace for the file tree: `{files, truncated?}`, each file
  `%{path:, size:, mtime:}` relative to it. Hidden entries, symlinks and build
  directories are left out, and at most #{@max_files} files are listed.
  """
  def list_files(project) do
    root = Path.expand(workspace(project))
    {files, left} = walk(root, "", @max_files)
    {Enum.sort_by(files, & &1.path), left < 0}
  end

  defp walk(root, rel, left) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reject(&hidden?/1)
        |> Enum.reduce({[], left}, fn name, {acc, left} ->
          if left < 0 do
            {acc, left}
          else
            path = if rel == "", do: name, else: Path.join(rel, name)

            case File.lstat(Path.join(root, path), time: :posix) do
              {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} when left > 0 ->
                {[%{path: path, size: size, mtime: mtime} | acc], left - 1}

              # One more than the cap: there is more than was listed.
              {:ok, %File.Stat{type: :regular}} ->
                {acc, -1}

              {:ok, %File.Stat{type: :directory}} ->
                if name in @skip_dirs do
                  {acc, left}
                else
                  {inner, left} = walk(root, path, left)
                  {inner ++ acc, left}
                end

              _ ->
                {acc, left}
            end
          end
        end)

      {:error, _} ->
        {[], left}
    end
  end

  @doc """
  The absolute path of one workspace file a download names, if it is one the
  listing would show. `rel` comes from a URL: expanded and checked, never
  trusted, and no component may be hidden or a symlink.
  """
  def resolve_file(project, rel) do
    root = Path.expand(workspace(project))
    path = Path.expand(to_string(rel), root)
    parts = path |> Path.relative_to(root) |> Path.split()

    cond do
      not String.starts_with?(path, root <> "/") -> :error
      Enum.any?(parts, &hidden?/1) -> :error
      not File.regular?(path) -> :error
      not no_symlinks?(root, parts) -> :error
      true -> {:ok, path}
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".") or String.starts_with?(name, "~$")

  defp no_symlinks?(root, parts) do
    parts
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: type}} when type != :symlink, File.lstat(&1)))
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Path.join(dir(), "projects.json"))
    {:ok, %{path: path, projects: path |> load() |> Map.new(&{&1.id, &1})}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.projects |> Map.values() |> Enum.sort_by(& &1.created_at), state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.projects, id), state}
  end

  def handle_call({:create, attrs}, _from, state) do
    with {:ok, name} <- valid_name(attrs["name"]),
         {:ok, instructions} <- valid_instructions(attrs["instructions"]) do
      project = %{
        id: "p_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)),
        name: name,
        instructions: instructions,
        created_at: System.system_time(:millisecond)
      }

      File.mkdir_p!(workspace(project))
      state = save(put_in(state.projects[project.id], project))
      broadcast({:project_summary, view(project)})
      {:reply, {:ok, project}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:update, id, attrs}, _from, state) do
    with {:ok, project} <- fetch(state, id),
         {:ok, name} <-
           if(Map.has_key?(attrs, "name"),
             do: valid_name(attrs["name"]),
             else: {:ok, project.name}
           ),
         {:ok, instructions} <-
           if(Map.has_key?(attrs, "instructions"),
             do: valid_instructions(attrs["instructions"]),
             else: {:ok, project.instructions}
           ) do
      project = %{project | name: name, instructions: instructions}
      state = save(put_in(state.projects[id], project))
      broadcast({:project_summary, view(project)})
      {:reply, {:ok, project}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case fetch(state, id) do
      {:ok, _project} ->
        File.rm_rf(Path.join([dir(), "projects", id]))
        state = save(%{state | projects: Map.delete(state.projects, id)})
        broadcast({:project_removed, id})
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  defp fetch(state, id) do
    case Map.fetch(state.projects, id) do
      {:ok, project} -> {:ok, project}
      :error -> {:error, :not_found}
    end
  end

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(Loom.PubSub, Loom.Agent.lobby_topic(), message)

  # ── Validation ────────────────────────────────────────────────────────────

  defp valid_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "a project needs a name"}
      name -> {:ok, String.slice(name, 0, @name_limit)}
    end
  end

  defp valid_name(_), do: {:error, "a project needs a name"}

  defp valid_instructions(nil), do: {:ok, ""}

  defp valid_instructions(text) when is_binary(text) do
    if String.length(text) > @instructions_limit,
      do: {:error, "instructions are limited to #{@instructions_limit} characters"},
      else: {:ok, String.trim(text)}
  end

  defp valid_instructions(_), do: {:error, "instructions must be text"}

  # ── Persistence ───────────────────────────────────────────────────────────

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"projects" => projects}} when is_list(projects) <- Jason.decode(body) do
      for p <- projects, is_map(p), is_binary(p["id"]) do
        Map.new(@persisted, &{&1, p[to_string(&1)]})
      end
    else
      {:error, :enoent} ->
        []

      _ ->
        # Moved aside rather than overwritten by the next save, like cron.json.
        aside = "#{path}.bad-#{System.os_time(:second)}"
        File.rename(path, aside)
        Logger.error("Loom.Projects cannot read #{path}; moved it to #{aside}")
        []
    end
  end

  defp save(state) do
    projects =
      state.projects
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&Map.take(&1, @persisted))

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(%{projects: projects}, pretty: true))
    File.rename!(tmp, state.path)
    state
  end
end
