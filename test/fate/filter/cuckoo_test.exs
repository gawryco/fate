defmodule Fate.Filter.CuckooTest do
  use ExUnit.Case, async: true

  alias Fate.Filter.Cuckoo

  setup do
    %{filter: Cuckoo.new(128, hash_module: Fate.Hash.Default)}
  end

  test "put/member?/size is consistent", %{filter: filter} do
    values = Enum.to_list(1..50)

    Enum.each(values, fn value ->
      assert :ok = Cuckoo.put(filter, value)
    end)

    Enum.each(values, fn value ->
      assert Cuckoo.member?(filter, value)
    end)

    assert Cuckoo.size(filter) == 50

    # reinserting same values should not change size
    Enum.each(values, fn value ->
      assert :ok = Cuckoo.put(filter, value)
    end)

    assert Cuckoo.size(filter) == 50
  end

  test "delete removes fingerprints and updates size", %{filter: filter} do
    :ok = Cuckoo.put(filter, "alpha")
    :ok = Cuckoo.put(filter, "beta")
    assert Cuckoo.member?(filter, "alpha")
    assert Cuckoo.size(filter) == 2

    assert :ok = Cuckoo.delete(filter, "alpha")
    refute Cuckoo.member?(filter, "alpha")
    assert Cuckoo.size(filter) == 1

    assert :not_found = Cuckoo.delete(filter, "gamma")
  end

  test "eventually reports {:error, :full} when saturated" do
    filter =
      Cuckoo.new(4,
        bucket_size: 2,
        fingerprint_bits: 6,
        max_kicks: 5,
        hash_module: Fate.Hash.Default
      )

    result =
      Enum.reduce_while(1..200, :ok, fn value, _ ->
        case Cuckoo.put(filter, {:value, value}) do
          :ok -> {:cont, :ok}
          {:error, :full} -> {:halt, :full}
        end
      end)

    assert result == :full
  end
end
