defmodule Fate.Cardinality.HyperLogLogTest do
  use ExUnit.Case, async: true

  alias Fate.Cardinality.HyperLogLog

  test "creates new HyperLogLog" do
    hll = HyperLogLog.new()
    assert hll.precision == 14
    assert hll.register_count == 16384
  end

  test "creates HyperLogLog with custom precision" do
    hll = HyperLogLog.new(precision: 12)
    assert hll.precision == 12
    assert hll.register_count == 4096
  end

  test "adds elements and estimates cardinality" do
    hll = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    # Add 100 unique items
    Enum.each(1..100, fn i ->
      HyperLogLog.add(hll, i)
    end)

    cardinality = HyperLogLog.cardinality(hll)
    # Should be close to 100, allow some variance
    assert cardinality >= 90 and cardinality <= 110
  end

  test "handles duplicate elements" do
    hll = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    # Add same item multiple times
    Enum.each(1..10, fn _ ->
      HyperLogLog.add(hll, "duplicate")
    end)

    cardinality = HyperLogLog.cardinality(hll)
    # Should estimate ~1 unique element
    assert cardinality >= 1 and cardinality <= 3
  end

  test "handles various data types" do
    hll = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    test_items = [
      "string",
      123,
      :atom,
      {:tuple, "with", "values"},
      [1, 2, 3],
      %{map: "value"}
    ]

    Enum.each(test_items, fn item ->
      HyperLogLog.add(hll, item)
    end)

    cardinality = HyperLogLog.cardinality(hll)
    assert cardinality >= length(test_items) - 2 and cardinality <= length(test_items) + 2
  end

  test "merge combines multiple sketches" do
    hll1 = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)
    hll2 = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    Enum.each(1..50, fn i ->
      HyperLogLog.add(hll1, i)
    end)

    Enum.each(51..100, fn i ->
      HyperLogLog.add(hll2, i)
    end)

    merged = HyperLogLog.merge([hll1, hll2])
    cardinality = HyperLogLog.cardinality(merged)

    # Should estimate ~100 unique elements
    assert cardinality >= 90 and cardinality <= 110
  end

  test "merge with overlapping elements" do
    hll1 = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)
    hll2 = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    Enum.each(1..100, fn i ->
      HyperLogLog.add(hll1, i)
    end)

    Enum.each(50..150, fn i ->
      HyperLogLog.add(hll2, i)
    end)

    merged = HyperLogLog.merge([hll1, hll2])
    cardinality = HyperLogLog.cardinality(merged)

    # Should estimate ~150 unique elements (1-150)
    assert cardinality >= 140 and cardinality <= 160
  end

  test "merge raises error for incompatible sketches" do
    hll1 = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)
    hll2 = HyperLogLog.new(precision: 14, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share precision/, fn ->
      HyperLogLog.merge([hll1, hll2])
    end
  end

  test "serialize and deserialize preserve state" do
    hll = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)

    Enum.each(1..100, fn i ->
      HyperLogLog.add(hll, i)
    end)

    original_cardinality = HyperLogLog.cardinality(hll)
    binary = HyperLogLog.serialize(hll)
    restored = HyperLogLog.deserialize(binary)

    assert restored.precision == hll.precision
    assert restored.register_count == hll.register_count
    assert HyperLogLog.cardinality(restored) == original_cardinality
  end

  test "serialize and deserialize empty sketch" do
    hll = HyperLogLog.new(precision: 12, hash_module: Fate.Hash.Default)
    binary = HyperLogLog.serialize(hll)
    restored = HyperLogLog.deserialize(binary)

    assert HyperLogLog.cardinality(restored) == 0
  end

  test "validates precision range" do
    assert_raise ArgumentError, ~r/precision must be/, fn ->
      HyperLogLog.new(precision: 3)
    end

    assert_raise ArgumentError, ~r/precision must be/, fn ->
      HyperLogLog.new(precision: 20)
    end
  end

  test "handles large cardinalities" do
    hll = HyperLogLog.new(precision: 14, hash_module: Fate.Hash.Default)

    Enum.each(1..10_000, fn i ->
      HyperLogLog.add(hll, i)
    end)

    cardinality = HyperLogLog.cardinality(hll)
    # Should be reasonably close to 10k
    assert cardinality >= 9_000 and cardinality <= 11_000
  end

  test "works with different hash functions" do
    hash_modules = [Fate.Hash.Default, Fate.Hash.FNV1a]

    Enum.each(hash_modules, fn hash_module ->
      hll = HyperLogLog.new(precision: 12, hash_module: hash_module)

      Enum.each(1..100, fn i ->
        HyperLogLog.add(hll, i)
      end)

      cardinality = HyperLogLog.cardinality(hll)
      assert cardinality >= 90 and cardinality <= 110
    end)
  end

  test "add_hashed/2 matches add/2 results" do
    hll_add = HyperLogLog.new(precision: 10, hash_module: Fate.Hash.Default)
    hll_hashed = HyperLogLog.new(precision: 10, hash_module: Fate.Hash.Default)

    data = Enum.to_list(1..200)

    Enum.each(data, fn value ->
      HyperLogLog.add(hll_add, value)
      hash = Fate.Hash.Default.hash(value, 0)
      HyperLogLog.add_hashed(hll_hashed, hash)
    end)

    assert_in_delta HyperLogLog.cardinality(hll_add), HyperLogLog.cardinality(hll_hashed), 20
  end

  # --- HLL++ mode tests ---

  test "creates HyperLogLog with mode :hll_plus" do
    hll = HyperLogLog.new(mode: :hll_plus)
    assert hll.mode == :hll_plus
    assert hll.precision == 14
  end

  test "validates mode option" do
    assert_raise ArgumentError, ~r/mode must be/, fn ->
      HyperLogLog.new(mode: :invalid)
    end
  end

  test "HLL++ estimates small cardinalities accurately" do
    for n <- [10, 25, 50, 75, 100] do
      hll = HyperLogLog.new(precision: 14, mode: :hll_plus, hash_module: Fate.Hash.FNV1a)
      Enum.each(1..n, &HyperLogLog.add(hll, &1))
      estimate = HyperLogLog.cardinality(hll)
      error = abs(estimate - n) / n

      assert error < 0.20,
             "HLL++ at n=#{n}: expected ~#{n}, got #{estimate} (#{Float.round(error * 100, 1)}% error)"
    end
  end

  test "HLL++ estimates medium cardinalities near threshold" do
    hll = HyperLogLog.new(precision: 12, mode: :hll_plus, hash_module: Fate.Hash.FNV1a)
    Enum.each(1..1000, &HyperLogLog.add(hll, &1))
    estimate = HyperLogLog.cardinality(hll)
    assert_in_delta estimate, 1000, 200
  end

  test "HLL++ handles large cardinalities" do
    hll = HyperLogLog.new(precision: 14, mode: :hll_plus, hash_module: Fate.Hash.Default)

    Enum.each(1..10_000, fn i ->
      HyperLogLog.add(hll, i)
    end)

    cardinality = HyperLogLog.cardinality(hll)
    assert cardinality >= 9_000 and cardinality <= 11_000
  end

  test "HLL++ works across all supported precisions" do
    for p <- 4..18 do
      hll = HyperLogLog.new(precision: p, mode: :hll_plus, hash_module: Fate.Hash.FNV1a)
      Enum.each(1..50, &HyperLogLog.add(hll, &1))
      estimate = HyperLogLog.cardinality(hll)
      assert estimate > 0, "precision #{p} returned non-positive estimate"
    end
  end

  test "merge raises when modes differ" do
    hll1 = HyperLogLog.new(precision: 12, mode: :hll, hash_module: Fate.Hash.Default)
    hll2 = HyperLogLog.new(precision: 12, mode: :hll_plus, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share precision/, fn ->
      HyperLogLog.merge([hll1, hll2])
    end
  end

  test "serialize and deserialize preserve mode" do
    hll = HyperLogLog.new(precision: 12, mode: :hll_plus, hash_module: Fate.Hash.Default)
    Enum.each(1..50, &HyperLogLog.add(hll, &1))

    binary = HyperLogLog.serialize(hll)
    restored = HyperLogLog.deserialize(binary)

    assert restored.mode == :hll_plus
    assert HyperLogLog.cardinality(restored) == HyperLogLog.cardinality(hll)
  end
end
