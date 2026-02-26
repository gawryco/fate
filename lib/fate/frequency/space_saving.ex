defmodule Fate.Frequency.SpaceSaving do
  @moduledoc """
  Space-Saving algorithm for deterministic heavy-hitter / top-k streaming.

  Maintains exactly `capacity` monitored counters. Any item with true frequency
  greater than N/capacity is guaranteed to be monitored. Per-item error bounds
  (overcount at most the evicted counter's value); deterministic — no hash
  collisions.

  ## Examples

      ss = SpaceSaving.new(10)
      SpaceSaving.put(ss, "page:/home")
      SpaceSaving.put(ss, "page:/home")
      SpaceSaving.estimate(ss, "page:/home")           # => 2
      SpaceSaving.guaranteed_estimate(ss, "page:/home") # => {min, max}
      SpaceSaving.top(ss, 5)                          # => [{item, count}, ...]
      SpaceSaving.serialize(ss)
      SpaceSaving.deserialize(binary)
  """

  @type t :: %__MODULE__{
          table: :ets.tid(),
          capacity: pos_integer(),
          meta_ref: reference()
        }

  defstruct [:table, :capacity, :meta_ref]

  @ets_opts [:set, :public, write_concurrency: :auto]
  @tag :fate_space_saving
  @version 1

  @doc """
  Creates a new Space-Saving structure with the given capacity (max monitored items).
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(capacity, opts \\ []) when is_list(opts) do
    unless is_integer(capacity) and capacity > 0 do
      raise ArgumentError, "capacity must be a positive integer"
    end

    meta_ref = make_ref()
    table = :ets.new(:fate_space_saving, @ets_opts)
    :ets.insert(table, {meta_ref, 0, 0})

    %__MODULE__{table: table, capacity: capacity, meta_ref: meta_ref}
  end

  @doc """
  Observes one occurrence of `item`. Increments if monitored, otherwise replaces
  the current minimum-count item when full.
  """
  @spec put(t(), term()) :: :ok
  def put(%__MODULE__{} = ss, item) do
    do_put(ss, item, 1)
  end

  @doc """
  Observes `item` with a count greater than 1.
  """
  @spec update(t(), term(), pos_integer()) :: :ok
  def update(%__MODULE__{} = ss, item, count) when is_integer(count) and count > 0 do
    do_put(ss, item, count)
  end

  @doc """
  Returns the estimated count for `item`, or 0 if not monitored.
  """
  @spec estimate(t(), term()) :: non_neg_integer()
  def estimate(%__MODULE__{table: table}, item) do
    case :ets.lookup_element(table, item, 2, nil) do
      nil -> 0
      count -> count
    end
  end

  @doc """
  Returns `{min_count, max_count}` such that the true count is in that range.
  Uses the stored error bound: true_count >= count - error, so min = count - error,
  max = count (overcount at most error).
  """
  @spec guaranteed_estimate(t(), term()) :: {non_neg_integer(), non_neg_integer()} | nil
  def guaranteed_estimate(%__MODULE__{table: table}, item) do
    case :ets.lookup(table, item) do
      [{^item, count, error}] -> {max(0, count - error), count}
      [] -> nil
    end
  end

  @doc """
  Returns the top-n monitored items as `[{item, count}]` sorted descending by count.
  If `n` is `nil`, returns all monitored items.
  """
  @spec top(t(), pos_integer() | nil) :: [{term(), non_neg_integer()}]
  def top(%__MODULE__{table: table, meta_ref: meta_ref}, n \\ nil) do
    entries =
      select_item_rows(table, meta_ref, :name_count)
      |> Enum.sort_by(fn {_item, count} -> count end, :desc)

    if n, do: Enum.take(entries, n), else: entries
  end

  @doc """
  Returns whether `item` is currently in the monitored set.
  """
  @spec monitored?(t(), term()) :: boolean()
  def monitored?(%__MODULE__{table: table}, item) do
    :ets.member(table, item)
  end

  @doc """
  Returns the current number of monitored items.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{table: table, meta_ref: _meta_ref}) do
    :ets.info(table, :size) - 1
  end

  @doc """
  Returns the maximum number of monitored items (capacity).
  """
  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{capacity: cap}), do: cap

  @doc """
  Returns the total number of observations N.
  """
  @spec total_count(t()) :: non_neg_integer()
  def total_count(%__MODULE__{table: table, meta_ref: meta_ref}) do
    total_count_from_table(table, meta_ref)
  end

  @doc """
  Merges multiple Space-Saving instances. All must have the same capacity.
  For duplicate items, counts and errors are summed; if result exceeds capacity,
  only the top-capacity items by count are kept.
  """
  @spec merge([t(), ...]) :: t()
  def merge([first | rest]) do
    cap = first.capacity

    Enum.each(rest, fn ss ->
      unless ss.capacity == cap do
        raise ArgumentError, "all Space-Saving instances must have the same capacity"
      end
    end)

    merged = new(cap)
    ref = merged.meta_ref
    tbl = merged.table

    # Union: collect all {item, count, error} from all instances
    combined =
      [first | rest]
      |> Enum.flat_map(fn ss ->
        select_item_rows(ss.table, ss.meta_ref, :all)
      end)
      |> Enum.group_by(fn {item, _c, _e} -> item end, fn {_item, c, e} -> {c, e} end)
      |> Enum.map(fn {item, pairs} ->
        {total_count, total_error} =
          Enum.reduce(pairs, {0, 0}, fn {c, e}, {acc_c, acc_e} -> {acc_c + c, acc_e + e} end)

        {item, total_count, total_error}
      end)
      |> Enum.sort_by(fn {_item, count, _error} -> count end, :desc)
      |> Enum.take(cap)

    total = Enum.reduce([first | rest], 0, &(total_count(&1) + &2))
    Enum.each(combined, fn {item, count, error} -> :ets.insert(tbl, {item, count, error}) end)
    :ets.insert(tbl, {ref, total, cached_min_from_entries(combined)})

    merged
  end

  @doc """
  Clears all monitored items and total count; capacity is unchanged.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{meta_ref: meta_ref, table: table} = t) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {meta_ref, 0, 0})
    t
  end

  @doc """
  Serializes the structure to a binary for storage or transmission.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{table: table, capacity: cap, meta_ref: meta_ref}) do
    entries = select_item_rows(table, meta_ref, :all)
    total = total_count_from_table(table, meta_ref)
    data = %{capacity: cap, entries: entries, total_count: total}
    :erlang.term_to_binary({@tag, @version, data})
  end

  @doc """
  Deserializes a binary produced by `serialize/1`.
  """
  @spec deserialize(binary()) :: t()
  def deserialize(binary) when is_binary(binary) do
    {@tag, version, data} = :erlang.binary_to_term(binary)
    do_deserialize(version, data)
  end

  # -- Private ----------------------------------------------------------------

  defp do_put(%__MODULE__{table: table, capacity: cap, meta_ref: meta_ref} = ss, item, amount) do
    :ets.update_counter(table, meta_ref, {2, amount})

    case :ets.lookup_element(table, item, 2, nil) do
      nil ->
        current_size = :ets.info(table, :size) - 1

        if current_size < cap do
          :ets.insert(table, {item, amount, 0})
          refresh_cached_min(ss)
        else
          evict_and_insert(table, meta_ref, item, amount, ss)
        end

      count ->
        :ets.update_element(table, item, {2, count + amount})
        refresh_cached_min(ss)
    end

    :ok
  end

  defp evict_and_insert(table, meta_ref, item, amount, ss) do
    {min_item, min_count, _error} = find_min_entry(table, meta_ref)
    :ets.delete(table, min_item)
    :ets.insert(table, {item, min_count + amount, min_count})
    refresh_cached_min(ss)
  end

  defp find_min_entry(table, meta_ref) do
    select_item_rows(table, meta_ref, :all)
    |> Enum.min_by(fn {_item, count, _error} -> count end, fn -> raise "empty" end)
  end

  defp refresh_cached_min(%__MODULE__{table: table, meta_ref: meta_ref}) do
    min_count =
      case select_item_rows(table, meta_ref, :count) do
        [] -> 0
        counts -> Enum.min(counts)
      end

    :ets.update_element(table, meta_ref, {3, min_count})
  end

  defp total_count_from_table(table, meta_ref) do
    case :ets.lookup_element(table, meta_ref, 2, nil) do
      nil -> 0
      total -> total
    end
  end

  defp cached_min_from_entries([]), do: 0

  defp cached_min_from_entries(entries) do
    entries
    |> Enum.map(fn {_item, count, _error} -> count end)
    |> Enum.min()
  end

  defp do_deserialize(1, data) do
    meta_ref = make_ref()
    table = :ets.new(:fate_space_saving, @ets_opts)

    Enum.each(data.entries, fn {item, count, error} ->
      :ets.insert(table, {item, count, error})
    end)

    min_count = cached_min_from_entries(data.entries)
    :ets.insert(table, {meta_ref, data.total_count, min_count})

    %__MODULE__{table: table, capacity: data.capacity, meta_ref: meta_ref}
  end

  # Match spec: select all rows where key =/= meta_ref.
  # $1=key, $2=count, $3=error. result_term is a single term (e.g. {{:"$1", :"$2"}}); we wrap in list so one term per match.
  defp select_item_rows(table, meta_ref, :all) do
    spec = [{{:"$1", :"$2", :"$3"}, [{:"=/=", :"$1", meta_ref}], [{{:"$1", :"$2", :"$3"}}]}]
    :ets.select(table, spec)
  end

  defp select_item_rows(table, meta_ref, :name_count) do
    spec = [{{:"$1", :"$2", :"$3"}, [{:"=/=", :"$1", meta_ref}], [{{:"$1", :"$2"}}]}]
    :ets.select(table, spec)
  end

  defp select_item_rows(table, meta_ref, :count) do
    spec = [{{:"$1", :"$2", :"$3"}, [{:"=/=", :"$1", meta_ref}], [:"$2"]}]
    :ets.select(table, spec)
  end

  defp select_item_rows(table, meta_ref, result_term) do
    spec = [{{:"$1", :"$2", :"$3"}, [{:"=/=", :"$1", meta_ref}], [result_term]}]
    :ets.select(table, spec)
  end
end
