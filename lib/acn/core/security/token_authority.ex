defmodule ACN.Core.Security.TokenAuthority do
  use Joken.Config

  @doc "Defines default token configuration"
  def token_config do
    default_claims(iss: "ACN_Controller", aud: "ACN_Actuator")
  end

  @valid_scopes [:fs_write, :fs_read, :exec_cmd, :net_request, :validator, :actuator]

  @doc "Generates a tuple {private_pem_binary, public_pem_binary}"
  def generate_keypair do
    # 1. Generate RSA Key
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    # 2. Extract Public Key from Private Key
    {:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _} = private_key
    public_key = {:RSAPublicKey, modulus, public_exponent}

    # 3. Encode both to PEM format
    private_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    public_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public_key)])

    {private_pem, public_pem}
  end

  @doc "Mints a new token with the given scope, resource, and role"
  def mint_token(private_pem, scope, resource, role \\ "agent", ttl \\ 300) do
    if scope not in @valid_scopes, do: raise "Invalid Scope: #{scope}"

    signer = Joken.Signer.create("RS256", %{"pem" => private_pem})

    claims = %{
      "scope" => to_string(scope),
      "resource" => resource,
      "role" => to_string(role),
      "jti" => UUID.uuid4(),
      "exp" => Joken.current_time() + ttl
    }

    generate_and_sign(claims, signer)
  end

  @doc "Verifies a token against the public key, required scope, and resource"
  def verify(token, public_pem, required_scope, requested_resource_args \\ nil) do
    signer = Joken.Signer.create("RS256", %{"pem" => public_pem})

    with {:ok, claims} <- verify_and_validate(token, signer),
         :ok <- validate_scope(claims["scope"], required_scope),
         :ok <- validate_resource(claims["resource"], requested_resource_args) do
      {:ok, claims}
    else
      err -> err
    end
  end

  defp validate_scope(token_scope, required_scope) do
    if token_scope == to_string(required_scope) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_resource(_token_resource, nil), do: :ok
  defp validate_resource(token_resource, requested_args) do
    # Simple check: Does the token resource match the requested operation's target?
    # For filesystem, args is usually path. For exec, command.
    # The actual matching logic depends on how 'args' are structured.
    # Assuming 'requested_resource' is passed in as the string to check against.

    # If requested_args is a map (tool args), we try to extract common resource keys
    resource_key =
      cond do
        is_binary(requested_args) -> requested_args
        is_map(requested_args) && Map.has_key?(requested_args, :path) -> requested_args[:path]
        is_map(requested_args) && Map.has_key?(requested_args, "path") -> requested_args["path"]
        is_map(requested_args) && Map.has_key?(requested_args, :command) -> requested_args[:command]
        is_map(requested_args) && Map.has_key?(requested_args, "command") -> requested_args["command"]
        is_map(requested_args) && Map.has_key?(requested_args, :dest) -> requested_args[:dest]
        is_map(requested_args) && Map.has_key?(requested_args, "dest") -> requested_args["dest"]
        true -> nil
      end

    cond do
      token_resource == "*" -> :ok # Superuser/Root token (use carefully)
      resource_key == token_resource -> :ok # Exact match
      String.starts_with?(token_resource, "/") and String.starts_with?(resource_key || "", "/") -> 
         # Directory Scope Check: Is resource_key inside token_resource?
         rel = Path.relative_to(resource_key, token_resource)
         if rel != resource_key and not String.starts_with?(rel, "..") do
           :ok
         else
           {:error, :resource_mismatch}
         end
      true -> {:error, :resource_mismatch}
    end
  end
end
