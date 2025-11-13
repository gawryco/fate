defmodule Fate.Hash do
  @moduledoc """
  Behaviour and helper functions for pluggable hashing within Fate data structures.

  This module defines a behaviour for hash providers and includes implementations
  for several popular hash functions. Each provider checks availability at runtime,
  allowing optional dependencies.

  ## Available Hash Functions

  - `Fate.Hash.XXH3` - Fastest for most workloads (requires `{:xxh3, "~> 0.3"}`)
  - `Fate.Hash.XXHash` - Fast general-purpose hash (requires `{:xxhash, "~> 0.3"}`)
  - `Fate.Hash.Murmur3` - Good distribution (requires `{:murmur, "~> 2.0"}`)
  - `Fate.Hash.FNV1a` - Pure Elixir, no dependencies
  - `Fate.Hash.Default` - Erlang's `:erlang.phash2` (always available)

  ## Performance Characteristics

  For simple types (integers, atoms, small binaries):
  - `Default` (phash2) is often fastest due to being a native BIF
  - `XXH3` is competitive and better for larger inputs

  For complex types or cross-language consistency:
  - `XXH3` offers best performance
  - `Murmur3` provides excellent distribution
  - `XXHash` is a good middle ground

  ## Examples

      # Auto-select best available hash
      hash_module = Fate.Hash.module()

      # Prefer specific hash functions
      hash_module = Fate.Hash.module(preferred: [
        Fate.Hash.XXH3,
        Fate.Hash.Murmur3,
        Fate.Hash.Default
      ])

      # Check if a hash function is available
      Fate.Hash.available?(Fate.Hash.XXH3)  # => true/false

      # Use a hash function directly
      Fate.Hash.hash(Fate.Hash.Default, "hello", 0)  # => integer

  ## Implementing Custom Hash Functions

      defmodule MyHash do
        @behaviour Fate.Hash

        @impl true
        def available?, do: true

        @impl true
        def hash(term, seed) do
          # Your hash implementation
          :erlang.phash2({term, seed})
        end
      end

      # Use your custom hash
      bloom = Fate.Filter.Bloom.new(1000, hash_module: MyHash)
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
      fnv1a64(data, @offset_basis)
    end

    defp fnv1a64(<<>>, hash), do: hash

    defp fnv1a64(<<byte::unsigned-integer-size(8), rest::binary>>, hash) do
      updated = ((bxor(hash, byte)) * @prime) &&& @mask
      fnv1a64(rest, updated)
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
