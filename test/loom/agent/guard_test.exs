defmodule Loom.Agent.GuardTest do
  # rel/loom-guard as the hook runs it: a tool call on stdin, the rules in a
  # file, exit 0 to let it through, 2 to refuse.
  use ExUnit.Case, async: true

  @script Path.expand("../../../rel/loom-guard", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-guard-#{System.unique_integer([:positive])}")
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(dir) end)

    rules = %{workstation: "Box", workspace: ws, log: Path.join(dir, "blocked.jsonl")}
    File.write!(Path.join(dir, "a_s.json"), Jason.encode!(rules))
    %{dir: dir, ws: ws}
  end

  defp run(%{dir: dir, ws: ws}, tool, input) do
    call = Jason.encode!(%{tool_name: tool, tool_input: input, cwd: ws})
    stdin = Path.join(dir, "call.json")
    File.write!(stdin, call)

    {_, code} =
      System.cmd("sh", ["-c", "python3 #{@script} #{dir} < #{stdin}"],
        env: [{"LOOM_SESSION_ID", "a_s"}],
        stderr_to_stdout: true
      )

    code
  end

  defp bash(ctx, command), do: run(ctx, "Bash", %{command: command})

  test "looking things up goes: MCP tools, web search and fetch", ctx do
    for tool <- ~w(mcp__agentcore-websearch__WebSearch mcp__aws-docs__search_documentation
                   WebSearch WebFetch web_search web_fetch @aws-docs/search_documentation) do
      assert run(ctx, tool, %{query: "x"}) == 0, tool
    end
  end

  test "on the workstation nothing is refused", ctx do
    for c <- [
          "loom-node exec Box -- 'Remove-Item -Recurse C:\\tmp\\x; python a.py | Out-File $(Get-Date).txt'",
          "loom-node read Box C:\\a.csv > #{ctx.ws}/a.csv",
          "loom-node write Box C:\\a.txt < #{ctx.ws}/a.txt",
          "echo hi | loom-node write Box C:\\a.txt",
          "printf 'a;b|c' | loom-node write Box C:\\a.txt",
          "loom-node write Box C:\\a.ps1 <<'EOF'\nrm -rf /; echo $(whoami) | tee x\nEOF",
          "loom-node exec Box -- 'dir' | head -5"
        ] do
      assert bash(ctx, c) == 0, c
    end
  end

  test "acting on this server is still refused, and logged", ctx do
    for c <- [
          "rm -rf /tmp/x",
          "python3 -c 1",
          "loom-node exec Other -- dir",
          "echo $(whoami) | loom-node write Box C:\\a",
          "loom-node write Box C:\\a <<EOF\n$(cat /etc/passwd)\nEOF",
          "echo x > /tmp/y"
        ] do
      assert bash(ctx, c) == 2, c
    end

    assert run(ctx, "Write", %{file_path: "/tmp/z", content: ""}) == 2
    assert run(ctx, "Write", %{file_path: Path.join(ctx.ws, "worklog.md"), content: ""}) == 0
    assert File.read!(Path.join(ctx.dir, "blocked.jsonl")) =~ "rm -rf /tmp/x"
  end

  test "no workstation in the rules: everything goes", ctx do
    File.write!(Path.join(ctx.dir, "a_s.json"), Jason.encode!(%{workstation: nil}))
    assert bash(ctx, "rm -rf /tmp/nothing-here") == 0
  end
end
