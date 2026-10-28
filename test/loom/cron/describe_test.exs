defmodule Loom.Cron.DescribeTest do
  use ExUnit.Case, async: true

  alias Loom.Cron.Describe

  @now ~N[2026-10-28 16:35:00]

  test "a reply becomes a task, whatever is wrapped around the object" do
    reply = """
    ```json
    {"name": "AWS 周报", "prompt": "给我一份 AWS 行业周报", "cron": "0  9 * * 1"}
    ```
    """

    assert {:ok, %{name: "AWS 周报", prompt: "给我一份 AWS 行业周报", cron: "0 9 * * 1"}} =
             Describe.describe("每周一早上九点 AWS 周报", @now, fn _, _ -> {:ok, reply} end)
  end

  test "no schedule, or a broken one, asks for when" do
    for cron <- ["null", ~s("every monday"), ~s("61 * * * *")] do
      reply = ~s({"name": "x", "prompt": "do it", "cron": #{cron}})
      assert {:error, sentence} = Describe.read(reply)
      assert sentence =~ "when"
    end
  end

  test "nothing usable, nothing said, or no model" do
    assert {:error, _} = Describe.read("I cannot help with that")
    assert {:error, _} = Describe.describe("   ", @now, fn _, _ -> flunk("asked") end)

    assert {:error, _} =
             Describe.describe("daily news", @now, fn _, _ -> {:error, :no_claude} end)
  end

  test "the model is told the user's time" do
    Describe.describe("tomorrow", @now, fn system, _ ->
      send(self(), {:system, system})
      {:ok, "{}"}
    end)

    assert_received {:system, system}
    assert system =~ "2026-10-28 16:35"
    assert system =~ "Wednesday"
  end
end
