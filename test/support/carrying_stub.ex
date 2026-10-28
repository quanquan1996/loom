defmodule Loom.CarryingStub do
  @moduledoc """
  `Loom.BackendStub`, as a backend whose process carries on through a restart
  (`Loom.Agent.Backend.detach/1`). Whether `adopt/1` finds it is up to the
  test: `Application.put_env(:loom, :carrying_adopts, false)`.
  """
  alias Loom.BackendStub

  defdelegate start(id, meta), to: BackendStub
  defdelegate resume(id, meta), to: BackendStub
  defdelegate run_turn(handle, text), to: BackendStub
  defdelegate steer(handle, text), to: BackendStub
  defdelegate interrupt(handle), to: BackendStub
  defdelegate decode(handle, message), to: BackendStub
  defdelegate persist(handle), to: BackendStub
  defdelegate release(handle), to: BackendStub
  defdelegate relocate(handle, cwd, instructions), to: BackendStub
  defdelegate stop(handle), to: BackendStub

  def detach(_handle), do: :ok
  def checkpoint(handle), do: handle

  def adopt(handle) do
    if Application.get_env(:loom, :carrying_adopts, true), do: {:ok, handle}, else: :error
  end
end
