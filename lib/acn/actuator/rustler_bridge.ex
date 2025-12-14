defmodule ACN.Actuator.RustlerBridge do
  use Rustler, otp_app: :acn, crate: "acn_sandbox"

  @moduledoc """
  NIF Bridge to the secure Rust Sandbox (Firecracker).
  """

  # NIF Interface
  def run_cmd(_socket_path, _command, _args), do: :erlang.nif_error(:nif_not_loaded)

  def count_tokens_nif(_text), do: :erlang.nif_error(:nif_not_loaded)
end
