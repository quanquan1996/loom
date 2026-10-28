defmodule Loom.ProjectsTest do
  # Not async: the registry is the application's own named process.
  use ExUnit.Case, async: false

  alias Loom.Projects

  setup do
    on_exit(fn -> for p <- Projects.list(), do: Projects.delete(p.id) end)
    :ok
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "loom-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "a project without a directory gets a workspace of its own" do
    {:ok, p} = Projects.create(%{"name" => "  Report  "})
    assert p.name == "Report"
    assert p.dir == nil
    assert File.dir?(Projects.workspace(p))
    assert String.starts_with?(Projects.workspace(p), Path.join(Projects.dir(), "projects"))
  end

  test "a project can be bound to an existing directory, which deleting leaves alone" do
    dir = tmp_dir()
    File.write!(Path.join(dir, "keep.txt"), "mine")

    {:ok, p} = Projects.create(%{"name" => "repo", "dir" => dir})
    assert Projects.workspace(p) == dir
    assert Projects.view(p).bound

    :ok = Projects.delete(p.id)
    assert File.read!(Path.join(dir, "keep.txt")) == "mine"
  end

  test "deleting a project Loom made removes its workspace" do
    {:ok, p} = Projects.create(%{"name" => "scratch"})
    ws = Projects.workspace(p)
    File.write!(Path.join(ws, "a.txt"), "x")

    :ok = Projects.delete(p.id)
    refute File.exists?(ws)
    assert Projects.get(p.id) == :error
  end

  test "refuses what it cannot use" do
    assert {:error, _} = Projects.create(%{"name" => " "})
    assert {:error, msg} = Projects.create(%{"name" => "x", "dir" => "relative/path"})
    assert msg =~ "absolute"
    assert {:error, msg} = Projects.create(%{"name" => "x", "dir" => "/no/such/dir/here"})
    assert msg =~ "not a directory"
    assert Projects.list() == []
  end

  test "update changes name and instructions, never the directory" do
    {:ok, p} = Projects.create(%{"name" => "a"})

    {:ok, p2} =
      Projects.update(p.id, %{"name" => "b", "instructions" => "Write in Chinese.", "dir" => "/"})

    assert p2.name == "b"
    assert p2.instructions == "Write in Chinese."
    assert p2.dir == nil
    assert {:error, :not_found} = Projects.update("p_nope", %{"name" => "c"})
  end

  test "instructions name the workspace and carry the user's text" do
    {:ok, p} = Projects.create(%{"name" => "Thesis", "instructions" => "Cite sources."})
    text = Projects.instructions(p)
    assert text =~ ~s("Thesis")
    assert text =~ Projects.workspace(p)
    assert text =~ "Cite sources."
  end

  test "survives a restart of its process" do
    {:ok, p} = Projects.create(%{"name" => "kept"})
    :ok = Supervisor.terminate_child(Loom.Supervisor, Projects)
    {:ok, _} = Supervisor.restart_child(Loom.Supervisor, Projects)
    assert {:ok, %{name: "kept"}} = Projects.get(p.id)
  end

  describe "workspace files" do
    setup do
      dir = tmp_dir()
      {:ok, p} = Projects.create(%{"name" => "files", "dir" => dir})
      {:ok, dir: dir, project: p}
    end

    test "lists working files, not hidden, build or linked ones", %{dir: dir, project: p} do
      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "src/main.py"), "print()")
      File.write!(Path.join(dir, "notes.md"), "# n")
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, ".git/HEAD"), "ref")
      File.mkdir_p!(Path.join(dir, "node_modules/x"))
      File.write!(Path.join(dir, "node_modules/x/i.js"), "")
      File.ln_s!("/etc/passwd", Path.join(dir, "link"))

      {files, truncated} = Projects.list_files(p)
      assert Enum.map(files, & &1.path) == ["notes.md", "src/main.py"]
      refute truncated
    end

    test "says when there is more than it lists", %{dir: dir, project: p} do
      for i <- 1..2001, do: File.write!(Path.join(dir, "f#{i}"), "")
      {files, truncated} = Projects.list_files(p)
      assert length(files) == 2000
      assert truncated
    end

    test "resolves only what the listing would show", %{dir: dir, project: p} do
      File.write!(Path.join(dir, "ok.txt"), "")
      File.write!(Path.join(dir, ".env"), "")
      File.ln_s!("/etc/passwd", Path.join(dir, "link"))

      assert {:ok, _} = Projects.resolve_file(p, "ok.txt")
      assert :error = Projects.resolve_file(p, ".env")
      assert :error = Projects.resolve_file(p, "link")
      assert :error = Projects.resolve_file(p, "../../etc/passwd")
      assert :error = Projects.resolve_file(p, "/etc/passwd")
    end
  end
end
