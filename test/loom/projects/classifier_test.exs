defmodule Loom.Projects.ClassifierTest do
  use ExUnit.Case, async: true

  alias Loom.Projects.Classifier

  @projects [%{id: "p_blog", name: "Blog"}, %{id: "p_app-1", name: "App"}]

  test "only an id it was given counts" do
    assert Classifier.pick("p_blog", @projects) == "p_blog"
    assert Classifier.pick("  p_app-1\n", @projects) == "p_app-1"
    assert Classifier.pick("It belongs to p_blog (p_blog).", @projects) == "p_blog"
    assert Classifier.pick("NONE", @projects) == nil
    assert Classifier.pick("p_other", @projects) == nil
    # Two answers are no answer.
    assert Classifier.pick("p_blog or p_app-1", @projects) == nil
    assert Classifier.pick(nil, @projects) == nil
  end

  test "no projects, no call" do
    assert Classifier.classify("anything", []) == nil
  end
end
