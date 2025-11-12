defmodule Fate.Hash do
  @moduledoc """
  Behaviour and helper functions for pluggable hashing within Fate data structures.

  The module decides at runtime which hashing backend to use. Supported backends:

    * `Fate.Hash.XXH3` – requires the optional `:xxh3` dependency.
    * `Fate.Hash.XXHash` – requires the optional `:xxhash` dependency.
    * `Fate.Hash.Murmur3` – requires the optional `:murmur` dependency.
    * `Fate.Hash.FNV1a` – pure Elixir fallback following the FNV-1a 64-bit variant.
    * `Fate.Hash.Default` – deterministic fallback based on `:erlang.phash2/2`.

  Custom hash providers can implement this behaviour and be passed through the
  `:hash_module` option where applicable.
  """

  @typedoc "Module implementing the `Fate.Hash` behaviour."
  @type provider :: module()

  @callback hash(term(), non_neg_integer()) :: non_neg_integer()
  @callback available?() :: boolean()

  @doc """
  Returns the best available hashing module.

  The selection order is XXH3, xxHash, Murmur3, FNV-1a, then the default fallback.
  """
  @spec module(keyword()) :: module()
  def module(opts \\ []) do
    preferred = Keyword.get(opts, :preferred, [])

    preferred
    |> List.wrap()
    |> Enum.find(&available?/1)
    |> case do
      nil -> default_chain() |> Enum.find(&available?/1)
      module -> module
    end
  end

  @doc """
  Executes the hashing operation via the given provider.
  """
  @spec hash(module() | nil, term(), non_neg_integer()) :: non_neg_integer()
  def hash(nil, term, seed), do: hash(module(), term, seed)

  def hash(provider, term, seed) when is_atom(provider) do
    ensure_behaviour!(provider)
    provider.hash(term, seed)
  end

  @doc """
  Returns `true` when the provider is available for use.
  """
  @spec available?(module()) :: boolean()
  def available?(provider) when is_atom(provider) do
    ensure_behaviour!(provider)
    provider.available?()
  end

  defp ensure_behaviour!(provider) do
    case Code.ensure_compiled(provider) do
      {:module, ^provider} ->
        unless function_exported?(provider, :hash, 2) and
                 function_exported?(provider, :available?, 0) do
          raise ArgumentError,
                "hash provider #{inspect(provider)} does not implement required callbacks"
        end

      _ ->
        raise ArgumentError, "hash provider #{inspect(provider)} could not be compiled"
    end
  end

  defp default_chain do
    [
      Fate.Hash.XXH3,
      Fate.Hash.XXHash,
      Fate.Hash.Murmur3,
      Fate.Hash.FNV1a,
      Fate.Hash.Default
    ]
  end

  defmodule XXH3 do
    @moduledoc false
    @behaviour Fate.Hash

    @impl Fate.Hash
    def available? do
      Code.ensure_loaded?(XXH3) and function_exported?(XXH3, :hash64, 2)
    end

    @impl Fate.Hash
    def hash(term, seed) do
      unless available?() do
        raise RuntimeError,
              "xxh3 backend not available – add {:xxh3, optional: false} to mix deps"
      end

      data = :erlang.term_to_binary(term)
      apply(XXH3, :hash64, [data, seed])
    end
  end

  defmodule XXHash do
    @moduledoc false
    @behaviour Fate.Hash

    @impl Fate.Hash
    def available? do
      Code.ensure_loaded?(:xxhash) and function_exported?(:xxhash, :xxh3_64, 2)
    end

    @impl Fate.Hash
    def hash(term, seed) do
      unless available?() do
        raise RuntimeError,
              "xxhash backend not available – add {:xxhash, optional: false} to mix deps"
      end

      data = :erlang.term_to_binary(term)
      apply(:xxhash, :xxh3_64, [data, seed])
    end
  end

  defmodule FNV1a do
    @moduledoc false
    @behaviour Fate.Hash

    import Bitwise

    @offset_basis 14_695_981_039_346_656_037
    @prime 1_099_511_628_211
    @mask 18_446_744_073_709_551_615

    @impl Fate.Hash
    def available?, do: true

    @impl Fate.Hash
    def hash(term, seed) do
      data = :erlang.term_to_binary({seed, term})

      data
      |> :erlang.binary_to_list()
      |> Enum.reduce(@offset_basis, fn byte, acc ->
        acc
        |> bxor(byte)
        |> Kernel.*(@prime)
        |> band(@mask)
      end)
    end
  end

  defmodule Murmur3 do
    @moduledoc false
    @behaviour Fate.Hash
    import Bitwise

    @impl Fate.Hash
    def available? do
      murmur_module() != nil
    end

    @impl Fate.Hash
    def hash(term, seed) do
      data = :erlang.term_to_binary({seed, term})

      case murmur_module() do
        :murmur ->
          <<result::unsigned-little-integer-size(64), _::binary>> =
            apply(:murmur, :hash_x64_128, [data, 0])

          result

        Murmur ->
          Murmur.hash_x64_128(data, 0) |> band((1 <<< 64) - 1)

        nil ->
          raise RuntimeError,
                "murmur backend not available – add {:murmur, optional: false} to mix deps"
      end
    end

    defp murmur_module do
      cond do
        Code.ensure_loaded?(Murmur) and function_exported?(Murmur, :hash_x64_128, 2) -> Murmur
        Code.ensure_loaded?(:murmur) and function_exported?(:murmur, :hash_x64_128, 2) -> :murmur
        true -> nil
      end
    end
  end

  defmodule Default do
    @moduledoc false
    @behaviour Fate.Hash

    @impl Fate.Hash
    def available?, do: true

    @impl Fate.Hash
    def hash(term, seed), do: :erlang.phash2({term, seed})
  end
end
