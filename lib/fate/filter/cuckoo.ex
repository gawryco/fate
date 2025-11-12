defmodule Fate.Filter.Cuckoo do
  @moduledoc """
  Concurrent-friendly Cuckoo filter backed by `:atomics`.

  The filter stores compact fingerprints for items in `bucket_size` slots per bucket
  (default 4) and supports `put/2`, `member?/2`, and `delete/2`. Hashing behaviour
  is customisable via the `:hash_module` option (see `Fate.Hash`). When a bucket is
  full the filter performs bounded relocation (`max_kicks`, default 500).
  """

  import Bitwise

  alias Fate.Hash

  @type t :: %__MODULE__{
          atomics: :atomics.atomics_ref(),
          count_ref: :atomics.atomics_ref(),
          bucket_count: pos_integer(),
          bucket_mask: non_neg_integer(),
          bucket_size: pos_integer(),
          fingerprint_bits: pos_integer(),
          fingerprint_mask: non_neg_integer(),
          max_kicks: pos_integer(),
          hash_module: module(),
          capacity: pos_integer()
        }

  defstruct [
    :atomics,
    :count_ref,
    :bucket_count,
    :bucket_mask,
    :bucket_size,
    :fingerprint_bits,
    :fingerprint_mask,
    :max_kicks,
    :hash_module,
    :capacity
  ]

  @default_bucket_size 4
  @default_fingerprint_bits 12
  @default_load_factor 0.95
  @default_max_kicks 500
  @mask64 (1 <<< 64) - 1

  @doc """
  Creates a new Cuckoo filter sized for the desired `capacity`.

  ## Options

    * `:bucket_size` – slots per bucket (defaults to #{@default_bucket_size}).
    * `:fingerprint_bits` – bits per fingerprint (defaults to #{@default_fingerprint_bits}).
    * `:load_factor` – target load factor before insert failures (defaults to #{@default_load_factor}).
    * `:max_kicks` – maximum relocation attempts before reporting `{:error, :full}`.
    * `:hash_module` – module implementing `Fate.Hash`.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(capacity, opts \\ []) when capacity > 0 do
    bucket_size = Keyword.get(opts, :bucket_size, @default_bucket_size) |> validate_bucket_size!()

    fingerprint_bits =
      Keyword.get(opts, :fingerprint_bits, @default_fingerprint_bits)
      |> validate_fingerprint_bits!()

    load_factor =
      opts |> Keyword.get(:load_factor, @default_load_factor) |> validate_load_factor!()

    max_kicks = Keyword.get(opts, :max_kicks, @default_max_kicks)
    hash_module = Keyword.get(opts, :hash_module, Hash.module())

    unless Hash.available?(hash_module) do
      raise ArgumentError, "hash module #{inspect(hash_module)} is not available"
    end

    ensure_bucket_capacity!(bucket_size, fingerprint_bits)

    bucket_count =
      capacity
      |> required_bucket_count(bucket_size, load_factor)
      |> next_power_of_two()

    bucket_mask =
      if band(bucket_count, bucket_count - 1) == 0 do
        bucket_count - 1
      else
        nil
      end

    atomics = :atomics.new(bucket_count, signed: false)
    count_ref = :atomics.new(1, signed: true)

    %__MODULE__{
      atomics: atomics,
      count_ref: count_ref,
      bucket_count: bucket_count,
      bucket_mask: bucket_mask,
      bucket_size: bucket_size,
      fingerprint_bits: fingerprint_bits,
      fingerprint_mask: (1 <<< fingerprint_bits) - 1,
      max_kicks: max_kicks,
      hash_module: hash_module,
      capacity: capacity
    }
  end

  @doc """
  Inserts `item` into the filter. Returns `:ok` or `{:error, :full}`.

  Duplicate inserts are treated as no-ops and return `:ok`.
  """
  @spec put(t(), term()) :: :ok | {:error, :full}
  def put(%__MODULE__{} = filter, item) do
    {fp, i1, i2, hash_seed} = hash_indices(filter, item)

    case insert_into_bucket(filter, i1, fp) do
      :duplicate ->
        :ok

      :inserted ->
        increment_count(filter)
        :ok

      :full ->
        case insert_into_bucket(filter, i2, fp) do
          :duplicate ->
            :ok

          :inserted ->
            increment_count(filter)
            :ok

          :full ->
            case cuckoo_insert(filter, i1, fp, hash_seed, 0) do
              :inserted ->
                increment_count(filter)
                :ok

              :duplicate ->
                :ok

              {:error, :full} ->
                {:error, :full}
            end
        end
    end
  end

  @doc """
  Checks whether `item` may be present in the filter.
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = filter, item) do
    {fp, i1, i2, _hash} = hash_indices(filter, item)
    bucket_contains?(filter, i1, fp) or bucket_contains?(filter, i2, fp)
  end

  @doc """
  Deletes `item` from the filter.

  Returns `:ok` if a matching fingerprint is removed, `:not_found` otherwise.
  """
  @spec delete(t(), term()) :: :ok | :not_found
  def delete(%__MODULE__{} = filter, item) do
    {fp, i1, i2, _hash} = hash_indices(filter, item)

    cond do
      delete_from_bucket(filter, i1, fp) ->
        decrement_count(filter)
        :ok

      delete_from_bucket(filter, i2, fp) ->
        decrement_count(filter)
        :ok

      true ->
        :not_found
    end
  end

  @doc """
  Returns the approximate number of items currently stored.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = filter) do
    filter.count_ref |> :atomics.get(1) |> max(0)
  end

  @doc """
  Maximum number of (ideal) items the filter was sized for.
  """
  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{} = filter), do: filter.capacity

  @doc """
  Current load factor (0.0–1.0) of occupied slots.
  """
  @spec load_factor(t()) :: float()
  def load_factor(%__MODULE__{} = filter) do
    slots = filter.bucket_count * filter.bucket_size
    size(filter) / slots
  end

  defp ensure_fingerprint(0), do: 1
  defp ensure_fingerprint(value), do: value

  defp to_bucket(value, %{bucket_mask: mask, bucket_count: count}) do
    if mask do
      band(value, mask)
    else
      Integer.mod(value, count)
    end
  end

  defp hash_indices(filter, item) do
    hash =
      Hash.hash(filter.hash_module, item, 0)
      |> band(@mask64)

    fp = fingerprint_from_hash(hash, filter)
    i1 = index_from_hash(hash, filter)
    i2 = alt_index_from_hash(hash, i1, fp, filter)
    {fp, i1, i2, hash}
  end

  defp fingerprint_from_hash(hash, filter) do
    hash
    |> band(filter.fingerprint_mask)
    |> ensure_fingerprint()
  end

  defp index_from_hash(hash, filter) do
    value = hash >>> filter.fingerprint_bits
    to_bucket(value, filter)
  end

  defp alt_index_from_hash(hash, index, fingerprint, filter) do
    mix =
      hash
      |> bxor(hash >>> 33)
      |> bxor(fingerprint <<< 1)
      |> mix64()

    to_bucket(bxor(index, mix), filter)
  end

  defp contains_fingerprint?(word, fingerprint, filter) do
    mask = filter.fingerprint_mask
    do_contains(word, fingerprint, mask, filter.fingerprint_bits, filter.bucket_size)
  end

  defp do_contains(_word, _fingerprint, _mask, _bits, 0), do: false

  defp do_contains(word, fingerprint, mask, bits, remaining) do
    current = band(word, mask)

    if current == fingerprint do
      true
    else
      do_contains(word >>> bits, fingerprint, mask, bits, remaining - 1)
    end
  end

  defp find_slot_index(word, fingerprint, filter) do
    mask = filter.fingerprint_mask
    do_find_slot(word, fingerprint, mask, filter.fingerprint_bits, filter.bucket_size, 0)
  end

  defp do_find_slot(_word, _fingerprint, _mask, _bits, 0, _index), do: :not_found

  defp do_find_slot(word, fingerprint, mask, bits, remaining, index) do
    current = band(word, mask)

    cond do
      current == fingerprint -> index
      true -> do_find_slot(word >>> bits, fingerprint, mask, bits, remaining - 1, index + 1)
    end
  end

  defp find_empty_slot_index(word, filter) do
    mask = filter.fingerprint_mask
    do_find_empty(word, mask, filter.fingerprint_bits, filter.bucket_size, 0)
  end

  defp do_find_empty(_word, _mask, _bits, 0, _index), do: :full

  defp do_find_empty(word, mask, bits, remaining, index) do
    current = band(word, mask)

    cond do
      current == 0 -> {:ok, index}
      true -> do_find_empty(word >>> bits, mask, bits, remaining - 1, index + 1)
    end
  end

  defp bucket_contains?(filter, bucket_idx, fingerprint) do
    word = bucket_word(filter, bucket_idx)
    contains_fingerprint?(word, fingerprint, filter)
  end

  defp insert_into_bucket(filter, bucket_idx, fingerprint) do
    {:ok, result} =
      update_bucket(filter, bucket_idx, fn word ->
        case find_slot_index(word, fingerprint, filter) do
          :not_found ->
            case find_empty_slot_index(word, filter) do
              {:ok, slot} -> {:ok, put_slot(word, slot, fingerprint, filter), :inserted}
              :full -> {:keep, :full}
            end

          _slot ->
            {:keep, :duplicate}
        end
      end)

    result
  end

  defp delete_from_bucket(filter, bucket_idx, fingerprint) do
    case update_bucket(filter, bucket_idx, fn word ->
           case find_slot_index(word, fingerprint, filter) do
             :not_found -> {:keep, :not_found}
             slot -> {:ok, clear_slot(word, slot, filter), slot}
           end
         end) do
      {:ok, :not_found} -> false
      {:ok, _slot} -> true
    end
  end

  defp cuckoo_insert(filter, _bucket_idx, _fingerprint, _hash_seed, kicks)
       when kicks >= filter.max_kicks,
       do: {:error, :full}

  defp cuckoo_insert(filter, bucket_idx, fingerprint, hash_seed, kicks) do
    slot = choose_slot(filter, bucket_idx, fingerprint, hash_seed, kicks)

    case swap_slot(filter, bucket_idx, slot, fingerprint) do
      :inserted ->
        :inserted

      :duplicate ->
        :duplicate

      {:evicted, victim_fp} ->
        next_bucket = alt_index_from_fingerprint(bucket_idx, victim_fp, filter)
        cuckoo_insert(filter, next_bucket, victim_fp, hash_seed, kicks + 1)
    end
  end

  defp swap_slot(filter, bucket_idx, slot, fingerprint) do
    {:ok, result} =
      update_bucket(filter, bucket_idx, fn word ->
        current = slot_value(word, slot, filter)

        cond do
          current == fingerprint ->
            {:keep, :duplicate}

          current == 0 ->
            {:ok, put_slot(word, slot, fingerprint, filter), :inserted}

          true ->
            {:ok, put_slot(word, slot, fingerprint, filter), {:evicted, current}}
        end
      end)

    case result do
      :inserted -> :inserted
      :duplicate -> :duplicate
      {:evicted, victim} -> {:evicted, victim}
    end
  end

  defp choose_slot(filter, bucket_idx, fingerprint, hash_seed, kicks) do
    mix =
      fingerprint
      |> bxor(bucket_idx <<< 8)
      |> bxor(hash_seed >>> 16)
      |> bxor(kicks <<< 2)
      |> mix64()

    Integer.mod(mix, filter.bucket_size)
  end

  defp increment_count(filter), do: :atomics.add_get(filter.count_ref, 1, 1)

  defp decrement_count(filter) do
    new_value = :atomics.add_get(filter.count_ref, 1, -1)
    if new_value < 0, do: :atomics.put(filter.count_ref, 1, 0)
    :ok
  end

  defp bucket_word(filter, bucket_idx) do
    :atomics.get(filter.atomics, bucket_idx + 1)
  end

  defp update_bucket(filter, bucket_idx, fun) do
    pos = bucket_idx + 1
    current = :atomics.get(filter.atomics, pos)

    case fun.(current) do
      {:ok, new_word, result} ->
        case :atomics.compare_exchange(filter.atomics, pos, current, new_word) do
          :ok -> {:ok, result}
          ^current -> {:ok, result}
          _ -> update_bucket(filter, bucket_idx, fun)
        end

      {:keep, result} ->
        {:ok, result}
    end
  end

  defp slot_value(word, slot, filter) do
    shift = slot * filter.fingerprint_bits
    band(word >>> shift, filter.fingerprint_mask)
  end

  defp put_slot(word, slot, fingerprint, filter) do
    shift = slot * filter.fingerprint_bits
    mask = filter.fingerprint_mask <<< shift
    cleared = band(word, bnot(mask))
    cleared ||| fingerprint <<< shift
  end

  defp clear_slot(word, slot, filter) do
    shift = slot * filter.fingerprint_bits
    mask = filter.fingerprint_mask <<< shift
    band(word, bnot(mask))
  end

  defp alt_index_from_fingerprint(index, fingerprint, filter) do
    mix = mix64(fingerprint)
    to_bucket(bxor(index, mix), filter)
  end

  defp mix64(value) do
    value = band(value, @mask64)
    value = band(bxor(value, value >>> 33), @mask64)
    value = band(value * 0xFF51AFD7ED558CCD, @mask64)
    value = band(bxor(value, value >>> 33), @mask64)
    value = band(value * 0xC4CEB9FE1A85EC53, @mask64)
    band(bxor(value, value >>> 33), @mask64)
  end

  defp required_bucket_count(capacity, bucket_size, load_factor) do
    Float.ceil(capacity / (bucket_size * load_factor))
    |> trunc()
    |> max(1)
  end

  defp next_power_of_two(value) when value <= 1, do: 1

  defp next_power_of_two(value) do
    v = value - 1
    v = bor(v, v >>> 1)
    v = bor(v, v >>> 2)
    v = bor(v, v >>> 4)
    v = bor(v, v >>> 8)
    v = bor(v, v >>> 16)
    v = bor(v, v >>> 32)
    v + 1
  end

  defp validate_load_factor!(value) when is_number(value) and value > 0 and value < 1, do: value
  defp validate_load_factor!(_), do: raise(ArgumentError, "load factor must be between 0 and 1")

  defp validate_bucket_size!(value) when is_integer(value) and value > 0, do: value

  defp validate_bucket_size!(_),
    do: raise(ArgumentError, "bucket size must be a positive integer")

  defp validate_fingerprint_bits!(value) when is_integer(value) and value > 0, do: value

  defp validate_fingerprint_bits!(_),
    do: raise(ArgumentError, "fingerprint bits must be a positive integer")

  defp ensure_bucket_capacity!(bucket_size, fingerprint_bits) do
    if bucket_size * fingerprint_bits > 64 do
      raise ArgumentError,
            "bucket_size (#{bucket_size}) * fingerprint_bits (#{fingerprint_bits}) must be <= 64"
    end
  end
end
