defmodule Fate.Filter.Bloom do
  @moduledoc """
  Concurrent Bloom filter implementation backed by `:atomics`.

  The filter uses double hashing to derive `k` indices per element. Hashing can be
  customised via the `:hash_module` option (see `Fate.Hash`). By default, the module
  selects the first available high-performance backend (`xxhash`, `murmur3`) and
  falls back to a pure Erlang hash.
  """

  import Bitwise

  alias Fate.Hash

  @type t :: %__MODULE__{
          atomics: :atomics.atomics_ref(),
          bit_length: pos_integer(),
          bucket_count: pos_integer(),
          hash_count: pos_integer(),
          hash_module: module(),
          false_positive_probability: float(),
          capacity: pos_integer()
        }

  defstruct [
    :atomics,
    :bit_length,
    :bucket_count,
    :hash_count,
    :hash_module,
    :false_positive_probability,
    :capacity
  ]

  @word_size 64

  @doc """
  Creates a new Bloom filter sized for the desired `capacity`.

  ## Options

    * `:false_positive_probability` – target probability (defaults to `0.01`).
    * `:hash_module` – module implementing `Fate.Hash` (auto-selected when omitted).
    * `:hash_count` – override number of hash functions.
    * `:bit_length` – override total number of bits in the filter.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(capacity, opts \\ []) when capacity > 0 do
    false_positive_probability =
      opts
      |> Keyword.get(:false_positive_probability, 0.01)
      |> validate_fpp!()

    bit_length =
      opts[:bit_length] ||
        required_filter_length(capacity, false_positive_probability)

    hash_count =
      opts[:hash_count] ||
        required_hash_function_count(bit_length, capacity)

    hash_module = Keyword.get(opts, :hash_module, Hash.module())

    unless Hash.available?(hash_module) do
      raise ArgumentError, "hash module #{inspect(hash_module)} is not available"
    end

    bucket_count = word_count(bit_length)
    atomics = :atomics.new(bucket_count, signed: false)

    %__MODULE__{
      atomics: atomics,
      bit_length: bit_length,
      bucket_count: bucket_count,
      hash_count: hash_count,
      hash_module: hash_module,
      false_positive_probability: false_positive_probability,
      capacity: capacity
    }
  end

  @doc """
  Inserts `item` into the filter.
  """
  @spec put(t(), term()) :: :ok
  def put(%__MODULE__{} = bloom, item) do
    bloom
    |> indices(item)
    |> Enum.each(&set_bit(bloom.atomics, &1))

    :ok
  end

  @doc """
  Checks whether `item` might be a member of the filter.
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = bloom, item) do
    bloom
    |> indices(item)
    |> Enum.all?(&bit_set?(bloom.atomics, &1))
  end

  @doc """
  Returns statistics about the current bitset.
  """
  @spec bits_info(t()) :: %{
          total_bits: pos_integer(),
          set_bits_count: non_neg_integer(),
          set_ratio: float()
        }
  def bits_info(%__MODULE__{} = bloom) do
    set_bits_count = count_bits(bloom)
    total_bits = bloom.bit_length
    set_ratio = if total_bits == 0, do: 0.0, else: set_bits_count / total_bits

    %{
      total_bits: total_bits,
      set_bits_count: set_bits_count,
      set_ratio: set_ratio
    }
  end

  @doc """
  Estimates the number of unique elements inserted into the filter.
  """
  @spec cardinality(t()) :: non_neg_integer()
  def cardinality(%__MODULE__{} = bloom) do
    %{total_bits: m, set_bits_count: x} = bits_info(bloom)
    estimate = if x == 0, do: 0.0, else: -m / bloom.hash_count * :math.log(1 - x / m)
    max(round(estimate), 0)
  end

  @doc """
  Estimates the current false-positive probability.
  """
  @spec false_positive_probability(t()) :: float()
  def false_positive_probability(%__MODULE__{} = bloom) do
    n = max(cardinality(bloom), 1)
    m = bloom.bit_length
    k = bloom.hash_count

    :math.pow(1 - :math.exp(-k * n / m), k)
  end

  @doc """
  Serialises the filter into a binary for storage/transmission.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = bloom) do
    data = %{
      bit_length: bloom.bit_length,
      bucket_count: bloom.bucket_count,
      hash_count: bloom.hash_count,
      hash_module: bloom.hash_module,
      false_positive_probability: bloom.false_positive_probability,
      capacity: bloom.capacity,
      words: Enum.map(1..bloom.bucket_count, &:atomics.get(bloom.atomics, &1))
    }

    :erlang.term_to_binary({:fate_bloom, 1, data})
  end

  @doc """
  Deserialises a filter that was previously `serialize/1`d.
  """
  @spec deserialize(binary()) :: t()
  def deserialize(binary) when is_binary(binary) do
    {:fate_bloom, 1, data} = :erlang.binary_to_term(binary)
    atomics = :atomics.new(data.bucket_count, signed: false)

    Enum.with_index(data.words, 1)
    |> Enum.each(fn {word, idx} -> :atomics.put(atomics, idx, word) end)

    %__MODULE__{
      atomics: atomics,
      bit_length: data.bit_length,
      bucket_count: data.bucket_count,
      hash_count: data.hash_count,
      hash_module: data.hash_module,
      false_positive_probability: data.false_positive_probability,
      capacity: data.capacity
    }
  end

  @doc """
  Merges multiple filters with identical configuration using bitwise OR.
  """
  @spec merge([t(), ...]) :: t()
  def merge([first | rest]) do
    ensure_compatible!(rest, first)

    merged = empty_like(first)

    1..first.bucket_count
    |> Enum.each(fn idx ->
      value =
        Enum.reduce(rest, :atomics.get(first.atomics, idx), fn bloom, acc ->
          acc ||| :atomics.get(bloom.atomics, idx)
        end)

      :atomics.put(merged.atomics, idx, value)
    end)

    merged
  end

  @doc """
  Intersects multiple filters with identical configuration using bitwise AND.
  """
  @spec intersection([t(), ...]) :: t()
  def intersection([first | rest]) do
    ensure_compatible!(rest, first)

    intersected = empty_like(first)

    1..first.bucket_count
    |> Enum.each(fn idx ->
      value =
        Enum.reduce(rest, :atomics.get(first.atomics, idx), fn bloom, acc ->
          acc &&& :atomics.get(bloom.atomics, idx)
        end)

      :atomics.put(intersected.atomics, idx, value)
    end)

    intersected
  end

  @doc """
  Computes the optimal filter length (`m`) in bits for the given `capacity` (`n`)
  and target false-positive probability (`p`).
  """
  @spec required_filter_length(pos_integer(), float()) :: pos_integer()
  def required_filter_length(capacity, probability) when capacity > 0 do
    probability = validate_fpp!(probability)
    m = -(capacity * :math.log(probability) / :math.pow(:math.log(2), 2))
    max(trunc(:math.ceil(m)), @word_size)
  end

  @doc """
  Computes the optimal hash count (`k`) for the given bit length `m` and capacity `n`.
  """
  @spec required_hash_function_count(pos_integer(), pos_integer()) :: pos_integer()
  def required_hash_function_count(bit_length, capacity) when bit_length > 0 and capacity > 0 do
    k = bit_length / capacity * :math.log(2)
    max(round(k), 1)
  end

  defp empty_like(%__MODULE__{} = bloom) do
    new(bloom.capacity,
      false_positive_probability: bloom.false_positive_probability,
      hash_count: bloom.hash_count,
      bit_length: bloom.bit_length,
      hash_module: bloom.hash_module
    )
  end

  defp ensure_compatible!(blooms, reference) do
    Enum.each(blooms, fn bloom ->
      unless compatible?(bloom, reference) do
        raise ArgumentError, "filters must share bit length, hash count, and hash module"
      end
    end)
  end

  defp compatible?(a, b) do
    a.bit_length == b.bit_length and a.hash_count == b.hash_count and
      a.hash_module == b.hash_module
  end

  defp count_bits(%__MODULE__{} = bloom) do
    1..bloom.bucket_count
    |> Enum.reduce(0, fn idx, acc ->
      word = :atomics.get(bloom.atomics, idx)
      acc + bit_popcount(word)
    end)
  end

  defp bit_popcount(value), do: bit_popcount(value, 0)
  defp bit_popcount(0, acc), do: acc
  defp bit_popcount(value, acc), do: bit_popcount(value &&& value - 1, acc + 1)

  defp bit_set?(ref, bit_index) do
    {bucket_idx, mask} = bucket_and_mask(bit_index)
    (:atomics.get(ref, bucket_idx) &&& mask) == mask
  end

  defp set_bit(ref, bit_index) do
    {bucket_idx, mask} = bucket_and_mask(bit_index)
    do_set_bit(ref, bucket_idx, mask)
  end

  defp do_set_bit(ref, bucket_idx, mask) do
    current = :atomics.get(ref, bucket_idx)
    new_value = current ||| mask

    if current == new_value do
      :ok
    else
      case :atomics.compare_exchange(ref, bucket_idx, current, new_value) do
        ^current -> :ok
        _ -> do_set_bit(ref, bucket_idx, mask)
      end
    end
  end

  defp bucket_and_mask(bit_index) do
    bucket_idx = div(bit_index, @word_size) + 1
    mask = 1 <<< rem(bit_index, @word_size)
    {bucket_idx, mask}
  end

  defp indices(%__MODULE__{} = bloom, item) do
    h1 = bloom.hash_module.hash(item, 0)
    h2 = bloom.hash_module.hash(item, 1) ||| 1

    for i <- 0..(bloom.hash_count - 1) do
      Integer.mod(h1 + i * h2, bloom.bit_length)
    end
  end

  defp word_count(bit_length), do: div(bit_length + (@word_size - 1), @word_size)

  defp validate_fpp!(probability)
       when is_number(probability) and probability > 0 and probability < 1,
       do: probability

  defp validate_fpp!(_),
    do: raise(ArgumentError, "false positive probability must be between 0 and 1")
end
