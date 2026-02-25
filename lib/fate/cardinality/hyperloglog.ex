defmodule Fate.Cardinality.HyperLogLog do
  @moduledoc """
  High-performance HyperLogLog implementation for cardinality estimation.

  HyperLogLog is a probabilistic data structure for estimating the number of distinct
  elements (cardinality) in a multiset. It uses a small, fixed amount of memory and
  provides estimates with a typical relative error of about 1.04 / sqrt(m) where m
  is the number of registers.

  ## Features

  - Lock-free concurrent operations via `:atomics`
  - Configurable precision (4-18, default 14)
  - Serialization/deserialization
  - Merge operations for combining sketches
  - Pluggable hash functions
  - Optimized 64-bit hash to avoid large range correction

  ## Algorithm

  This implementation follows the HyperLogLog algorithm from:
  - Flajolet et al. (2007): "HyperLogLog: the analysis of a near-optimal cardinality estimation algorithm"
  - Uses 64-bit hash to avoid large range correction (as suggested in "HyperLogLog in Practice")
  - Improved raw estimation algorithm for better accuracy

  It supports two modes:

  - `:hll` (default) — standard HyperLogLog from Flajolet et al. (2007)
  - `:hll_plus` — HyperLogLog++ from Heule et al. (2013) with empirical bias correction
    for improved accuracy at small-to-medium cardinalities

  Both modes use 64-bit hashes to avoid large range correction.

  ## Examples

      # Create a HyperLogLog with default precision (14)
      hll = HyperLogLog.new()

      # Create a HyperLogLog++ with bias correction
      hll_plus = HyperLogLog.new(mode: :hll_plus)

      # Add elements
      HyperLogLog.add(hll, "user:123")
      HyperLogLog.add(hll, "user:456")

      # Estimate cardinality
      HyperLogLog.cardinality(hll)  # => ~2

      # Merge multiple sketches
      merged = HyperLogLog.merge([hll1, hll2, hll3])

      # Serialize for storage
      binary = HyperLogLog.serialize(hll)
      restored = HyperLogLog.deserialize(binary)

  ## Precision

  Precision determines the number of registers (2^precision) and affects both
  accuracy and memory usage:

  - Precision 4: 16 registers, ~2.6% error, 16 bytes
  - Precision 8: 256 registers, ~0.65% error, 256 bytes
  - Precision 12: 4096 registers, ~0.16% error, 4 KB
  - Precision 14: 16384 registers, ~0.08% error, 16 KB (default)
  - Precision 16: 65536 registers, ~0.04% error, 64 KB

  Higher precision = better accuracy but more memory.
  """

  import Bitwise

  alias Fate.Hash
  alias Fate.Cardinality.HyperLogLog.BiasData

  @type mode :: :hll | :hll_plus

  @type t :: %__MODULE__{
          atomics: :atomics.atomics_ref(),
          precision: pos_integer(),
          register_count: pos_integer(),
          hash_module: module(),
          mode: mode()
        }

  defstruct [
    :atomics,
    :precision,
    :register_count,
    :hash_module,
    mode: :hll
  ]

  @default_precision 14
  @min_precision 4
  @max_precision 18

  # Constants for cardinality estimation
  @alpha_m_4 0.673
  @alpha_m_5 0.697
  @alpha_m_6 0.709
  @alpha_m_default 0.7213 / (1.0 + 1.079 / 16384.0)

  @doc """
  Creates a new HyperLogLog sketch.

  ## Options

    * `:precision` – number of bits for register addressing (4-18, default #{@default_precision}).
      Higher precision = better accuracy but more memory.
    * `:hash_module` – module implementing `Fate.Hash` (auto-selected when omitted).
    * `:mode` – `:hll` (default) or `:hll_plus` for HyperLogLog++ with bias correction.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    precision =
      opts
      |> Keyword.get(:precision, @default_precision)
      |> validate_precision!()

    register_count = 1 <<< precision
    hash_module = Keyword.get(opts, :hash_module, Hash.module())
    mode = opts |> Keyword.get(:mode, :hll) |> validate_mode!()

    unless Hash.available?(hash_module) do
      raise ArgumentError, "hash module #{inspect(hash_module)} is not available"
    end

    # Each register stores an 8-bit value (0-255), packed into 64-bit words
    # 64 bits / 8 bits = 8 registers per word
    words_needed = div(register_count + 7, 8)
    atomics = :atomics.new(words_needed, signed: false)

    %__MODULE__{
      atomics: atomics,
      precision: precision,
      register_count: register_count,
      hash_module: hash_module,
      mode: mode
    }
  end

  @doc """
  Adds an element to the HyperLogLog sketch.
  """
  @spec add(t(), term()) :: :ok
  def add(%__MODULE__{} = hll, item) do
    # Hash the item to 64 bits
    hash = Hash.hash(hll.hash_module, item, 0)

    add_hashed(hll, hash)
  end

  @doc false
  @spec add_hashed(t(), non_neg_integer()) :: :ok
  def add_hashed(%__MODULE__{} = hll, hash) when is_integer(hash) and hash >= 0 do
    # Extract index and count leading zeros using a fast log-based approximation
    # This keeps the critical path lightweight while maintaining accuracy
    p = hll.precision
    {index, register_value} = hash_to_register(hash, p)

    # Update register using CAS if new value is larger
    set_register(hll, index, register_value)
  end

  # Extract register index and count leading zeros with a log-based estimator
  # Inspired by the approach in HLL but optimized for our concurrent structure
  defp hash_to_register(hash, p) do
    # Extract index from lowest p bits (maintains our existing distribution)
    index = band(hash, (1 <<< p) - 1)

    # Count leading zeros in remaining upper bits + 1 (HLL standard)
    # Use logarithmic estimation for fast leading-zero count
    remaining = hash >>> p
    register_value = min(clz_fast(remaining, 64 - p) + 1, 63)

    {index, register_value}
  end

  @byte_leading_zeros :erlang.list_to_tuple(
                        for byte <- 0..255 do
                          cond do
                            byte == 0 -> 8
                            byte >= 128 -> 0
                            byte >= 64 -> 1
                            byte >= 32 -> 2
                            byte >= 16 -> 3
                            byte >= 8 -> 4
                            byte >= 4 -> 5
                            byte >= 2 -> 6
                            true -> 7
                          end
                        end
                      )

  @compile {:inline, clz_fast: 2}
  defp clz_fast(0, bits), do: bits

  defp clz_fast(value, bits) do
    mask = if bits >= 63, do: -1, else: (1 <<< bits) - 1
    clz_fast(value &&& mask, bits, 0)
  end

  defp clz_fast(_value, bits, acc) when bits <= 0, do: acc

  defp clz_fast(value, bits, acc) when bits >= 16 do
    shift = bits - 16
    top16 = value >>> shift

    if top16 == 0 do
      clz_fast(value, bits - 16, acc + 16)
    else
      high_byte = top16 >>> 8

      if high_byte != 0 do
        acc + byte_lz(high_byte)
      else
        acc + 8 + byte_lz(top16 &&& 0xFF)
      end
    end
  end

  defp clz_fast(value, bits, acc) when bits > 8 do
    shift = bits - 8
    top8 = value >>> shift

    if top8 == 0 do
      clz_fast(value, bits - 8, acc + 8)
    else
      acc + byte_lz(top8)
    end
  end

  defp clz_fast(value, bits, acc) do
    top = value &&& (1 <<< bits) - 1

    if top == 0 do
      acc + bits
    else
      aligned = top <<< (8 - bits)
      acc + byte_lz(aligned)
    end
  end

  @compile {:inline, byte_lz: 1}
  defp byte_lz(byte), do: elem(@byte_leading_zeros, byte)

  @doc """
  Estimates the cardinality (number of distinct elements) in the sketch.
  """
  @spec cardinality(t()) :: non_neg_integer()
  def cardinality(%__MODULE__{} = hll) do
    # Calculate raw estimate using harmonic mean
    raw_estimate = raw_estimate(hll)

    # Apply bias correction based on mode
    corrected =
      case hll.mode do
        :hll -> apply_bias_correction(hll, raw_estimate)
        :hll_plus -> apply_bias_correction_plus(hll, raw_estimate)
      end

    max(round(corrected), 0)
  end

  @doc """
  Merges multiple HyperLogLog sketches with the same precision.

  Merging takes the maximum value for each register across all sketches.
  """
  @spec merge([t(), ...]) :: t()
  def merge([first | rest]) do
    ensure_compatible!(rest, first)

    merged = empty_like(first)

    # Merge registers by taking maximum
    0..(first.register_count - 1)
    |> Enum.each(fn idx ->
      max_value =
        Enum.reduce(rest, get_register(first, idx), fn hll, acc ->
          max(acc, get_register(hll, idx))
        end)

      set_register(merged, idx, max_value)
    end)

    merged
  end

  @doc """
  Serialises the HyperLogLog sketch into a binary for storage/transmission.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = hll) do
    # Read all registers
    registers = Enum.map(0..(hll.register_count - 1), &get_register(hll, &1))

    data = %{
      precision: hll.precision,
      register_count: hll.register_count,
      hash_module: hll.hash_module,
      registers: registers,
      mode: hll.mode
    }

    :erlang.term_to_binary({:fate_hll, 1, data})
  end

  @doc """
  Deserialises a HyperLogLog sketch that was previously `serialize/1`d.
  """
  @spec deserialize(binary()) :: t()
  def deserialize(binary) when is_binary(binary) do
    {:fate_hll, 1, data} = :erlang.binary_to_term(binary)

    # Backwards compat: default to :hll if mode key is missing from older serialized data
    mode = Map.get(data, :mode, :hll)
    hll = new(precision: data.precision, hash_module: data.hash_module, mode: mode)

    Enum.with_index(data.registers)
    |> Enum.each(fn {value, idx} ->
      set_register(hll, idx, value)
    end)

    hll
  end

  # Get register value (6-bit, 0-63, standard for HyperLogLog)
  defp get_register(%__MODULE__{} = hll, index) do
    # Each register is 6 bits, packed into 64-bit words
    # We can fit 10 registers per word (64/6 = 10.67), but let's use 8 bits per register for simplicity
    # 8 registers per word
    word_index = div(index, 8)
    bit_offset = rem(index, 8) * 8

    word = :atomics.get(hll.atomics, word_index + 1)
    band(word >>> bit_offset, 0xFF)
  end

  # Set register value using CAS
  defp set_register(%__MODULE__{} = hll, index, value) do
    # Each register is 8 bits, packed into 64-bit words
    word_index = div(index, 8)
    bit_offset = rem(index, 8) * 8
    atomic_idx = word_index + 1

    do_set_register(hll.atomics, atomic_idx, bit_offset, value)
  end

  # Optimized CAS with early exit
  defp do_set_register(atomics, atomic_idx, bit_offset, value) do
    current = :atomics.get(atomics, atomic_idx)

    # Extract current register value
    current_register = band(current >>> bit_offset, 0xFF)

    # Early exit if value won't change
    if value <= current_register do
      :ok
    else
      # Clear the 8-bit slot and set new value
      clear_mask = bnot(0xFF <<< bit_offset)
      new_value = band(current, clear_mask) ||| value <<< bit_offset

      case :atomics.compare_exchange(atomics, atomic_idx, current, new_value) do
        :ok -> :ok
        _ -> do_set_register(atomics, atomic_idx, bit_offset, value)
      end
    end
  end

  # Calculate raw estimate using harmonic mean
  # Optimized to process registers in batches from atomic words
  defp raw_estimate(%__MODULE__{} = hll) do
    m = hll.register_count

    # Calculate number of atomic words
    word_count = div(m + 7, 8)

    # Sum of 2^(-register_value) for all registers
    # Process atomics words directly for better performance
    sum = sum_inverse_powers_fast(hll.atomics, word_count, 0, 0.0)

    # Harmonic mean
    alpha = alpha_m(hll.precision)
    estimate = alpha * m * m / sum

    estimate
  end

  # Fast path: process all 8 registers in a word at once
  defp sum_inverse_powers_fast(_atomics, word_count, word_idx, acc) when word_idx >= word_count,
    do: acc

  defp sum_inverse_powers_fast(atomics, word_count, word_idx, acc) do
    word = :atomics.get(atomics, word_idx + 1)

    # Fast path: skip if word is all zeros
    new_acc =
      if word == 0 do
        # All 8 registers are 0, so add 8.0 (2^(-0) = 1 for each)
        acc + 8.0
      else
        # Extract and process all 8 registers in this word
        acc
        |> add_inverse_power(band(word, 0xFF))
        |> add_inverse_power(band(word >>> 8, 0xFF))
        |> add_inverse_power(band(word >>> 16, 0xFF))
        |> add_inverse_power(band(word >>> 24, 0xFF))
        |> add_inverse_power(band(word >>> 32, 0xFF))
        |> add_inverse_power(band(word >>> 40, 0xFF))
        |> add_inverse_power(band(word >>> 48, 0xFF))
        |> add_inverse_power(band(word >>> 56, 0xFF))
      end

    sum_inverse_powers_fast(atomics, word_count, word_idx + 1, new_acc)
  end

  # Add inverse power for a single register value
  @compile {:inline, add_inverse_power: 2}
  defp add_inverse_power(acc, 0), do: acc + 1.0
  defp add_inverse_power(acc, register_value), do: acc + 1.0 / (1 <<< register_value)

  # Get alpha constant based on precision
  defp alpha_m(4), do: @alpha_m_4
  defp alpha_m(5), do: @alpha_m_5
  defp alpha_m(6), do: @alpha_m_6
  defp alpha_m(m) when m >= 7, do: @alpha_m_default

  # Apply bias correction for small cardinalities
  defp apply_bias_correction(%__MODULE__{} = hll, raw_estimate) do
    m = hll.register_count

    # Small range correction
    if raw_estimate <= 5.0 * m do
      # Count number of zero registers
      zero_count = count_zero_registers(hll, 0, 0)

      if zero_count > 0 do
        # Linear counting
        m * :math.log(m / zero_count)
      else
        raw_estimate
      end
    else
      # Large range correction (for very large cardinalities)
      if raw_estimate > 1.0 / 30.0 * :math.pow(2, 64) do
        -:math.pow(2, 64) * :math.log(1.0 - raw_estimate / :math.pow(2, 64))
      else
        raw_estimate
      end
    end
  end

  # Count zero registers - optimized to process words directly
  defp count_zero_registers(%__MODULE__{} = hll, index, acc) when index >= hll.register_count,
    do: acc

  defp count_zero_registers(%__MODULE__{} = hll, word_idx, acc) do
    word_count = div(hll.register_count + 7, 8)

    if word_idx >= word_count do
      acc
    else
      word = :atomics.get(hll.atomics, word_idx + 1)

      # Count zeros in this word
      zeros_in_word =
        count_if_zero(band(word, 0xFF)) +
          count_if_zero(band(word >>> 8, 0xFF)) +
          count_if_zero(band(word >>> 16, 0xFF)) +
          count_if_zero(band(word >>> 24, 0xFF)) +
          count_if_zero(band(word >>> 32, 0xFF)) +
          count_if_zero(band(word >>> 40, 0xFF)) +
          count_if_zero(band(word >>> 48, 0xFF)) +
          count_if_zero(band(word >>> 56, 0xFF))

      count_zero_registers(hll, word_idx + 1, acc + zeros_in_word)
    end
  end

  @compile {:inline, count_if_zero: 1}
  defp count_if_zero(0), do: 1
  defp count_if_zero(_), do: 0

  defp empty_like(%__MODULE__{} = hll) do
    new(precision: hll.precision, hash_module: hll.hash_module, mode: hll.mode)
  end

  defp ensure_compatible!(hlls, reference) do
    Enum.each(hlls, fn hll ->
      unless compatible?(hll, reference) do
        raise ArgumentError,
              "HyperLogLog sketches must share precision and hash_module for merging"
      end
    end)
  end

  defp compatible?(a, b) do
    a.precision == b.precision and a.hash_module == b.hash_module and a.mode == b.mode
  end

  defp validate_precision!(precision)
       when is_integer(precision) and precision >= @min_precision and
              precision <= @max_precision do
    precision
  end

  defp validate_precision!(_) do
    raise ArgumentError,
          "precision must be an integer between #{@min_precision} and #{@max_precision}"
  end

  defp validate_mode!(:hll), do: :hll
  defp validate_mode!(:hll_plus), do: :hll_plus

  defp validate_mode!(_) do
    raise ArgumentError, "mode must be :hll or :hll_plus"
  end

  # HLL++ bias correction (Heule et al. 2013)
  defp apply_bias_correction_plus(%__MODULE__{} = hll, raw_estimate) do
    m = hll.register_count
    p = hll.precision

    # Step 1: Bias-corrected estimate for small cardinalities
    e_prime =
      if raw_estimate <= 5.0 * m do
        raw_estimate - estimate_bias(raw_estimate, p)
      else
        raw_estimate
      end

    # Step 2: Check zero registers for linear counting
    zero_count = count_zero_registers(hll, 0, 0)

    if zero_count > 0 do
      h = m * :math.log(m / zero_count)

      if h <= BiasData.threshold(p) do
        h
      else
        e_prime
      end
    else
      e_prime
    end
  end

  # Estimate bias using linear interpolation over empirical tables
  defp estimate_bias(raw_estimate, precision) do
    raw_estimates = BiasData.raw_estimates(precision)
    biases = BiasData.biases(precision)
    size = BiasData.table_size(precision)

    {left, right} = binary_search_nearest(raw_estimates, raw_estimate, size)

    if left == right do
      elem(biases, left)
    else
      e1 = elem(raw_estimates, left)
      e2 = elem(raw_estimates, right)
      b1 = elem(biases, left)
      b2 = elem(biases, right)

      # Guard against duplicate table entries (avoids division by zero)
      if e2 == e1 do
        b1
      else
        c = (raw_estimate - e1) / (e2 - e1)
        b1 * (1.0 - c) + b2 * c
      end
    end
  end

  # Binary search for the two nearest bracketing indices in a sorted tuple.
  # Returns {left, right} where elem(tuple, left) <= value <= elem(tuple, right).
  # Clamps to boundaries when value is outside the range.
  defp binary_search_nearest(sorted_tuple, value, size) do
    first = elem(sorted_tuple, 0)
    last = elem(sorted_tuple, size - 1)

    cond do
      value <= first -> {0, 0}
      value >= last -> {size - 1, size - 1}
      true -> do_binary_search(sorted_tuple, value, 0, size - 1)
    end
  end

  defp do_binary_search(_tuple, _value, low, high) when high - low <= 1 do
    {low, high}
  end

  defp do_binary_search(tuple, value, low, high) do
    mid = div(low + high, 2)
    mid_val = elem(tuple, mid)

    cond do
      mid_val == value -> {mid, mid}
      mid_val < value -> do_binary_search(tuple, value, mid, high)
      true -> do_binary_search(tuple, value, low, mid)
    end
  end
end
