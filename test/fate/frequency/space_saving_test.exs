defmodule Fate.Frequency.SpaceSavingTest do
  use ExUnit.Case, async: true

  alias Fate.Frequency.SpaceSaving

  # -- Creation ----------------------------------------------------------------

  test "creates with valid capacity" do
    ss = SpaceSaving.new(10)
    assert ss.capacity == 10
    assert SpaceSaving.size(ss) == 0
    assert SpaceSaving.total_count(ss) == 0
  end

  test "raises on capacity 0" do
    assert_raise ArgumentError, ~r/capacity/, fn ->
      SpaceSaving.new(0)
    end
  end

  test "raises on negative capacity" do
    assert_raise ArgumentError, ~r/capacity/, fn ->
      SpaceSaving.new(-1)
    end
  end

  test "raises on non-integer capacity" do
    assert_raise ArgumentError, ~r/capacity/, fn ->
      SpaceSaving.new(1.5)
    end
  end

  # -- Put & Estimate ----------------------------------------------------------

  test "put and estimate for single item" do
    ss = SpaceSaving.new(10)

    :ok = SpaceSaving.put(ss, "hello")
    :ok = SpaceSaving.put(ss, "hello")
    :ok = SpaceSaving.put(ss, "hello")

    assert SpaceSaving.estimate(ss, "hello") == 3
  end

  test "multiple items" do
    ss = SpaceSaving.new(10)

    :ok = SpaceSaving.put(ss, "a")
    :ok = SpaceSaving.put(ss, "a")
    :ok = SpaceSaving.put(ss, "b")

    assert SpaceSaving.estimate(ss, "a") == 2
    assert SpaceSaving.estimate(ss, "b") == 1
  end

  test "estimate for unseen item returns 0" do
    ss = SpaceSaving.new(10)
    :ok = SpaceSaving.put(ss, "seen")
    assert SpaceSaving.estimate(ss, "never_inserted") == 0
  end

  # -- Eviction ---------------------------------------------------------------

  test "when full, lowest-count item is evicted and replaced" do
    ss = SpaceSaving.new(3)

    Enum.each(1..10, fn _ -> SpaceSaving.put(ss, "high") end)
    Enum.each(1..5, fn _ -> SpaceSaving.put(ss, "medium") end)
    Enum.each(1..2, fn _ -> SpaceSaving.put(ss, "low") end)

    assert SpaceSaving.size(ss) == 3
    assert SpaceSaving.estimate(ss, "high") == 10
    assert SpaceSaving.estimate(ss, "medium") == 5
    assert SpaceSaving.estimate(ss, "low") == 2

    # New item should evict "low" (minimum count)
    :ok = SpaceSaving.put(ss, "newcomer")

    assert SpaceSaving.monitored?(ss, "newcomer")
    refute SpaceSaving.monitored?(ss, "low")
    assert SpaceSaving.estimate(ss, "newcomer") == 3
  end

  # -- Error bounds -----------------------------------------------------------

  test "guaranteed_estimate returns correct min max range" do
    ss = SpaceSaving.new(2)

    :ok = SpaceSaving.put(ss, "a")
    :ok = SpaceSaving.put(ss, "a")
    :ok = SpaceSaving.put(ss, "b")

    assert SpaceSaving.guaranteed_estimate(ss, "a") == {2, 2}
    # "b" has count 1, error 0
    assert SpaceSaving.guaranteed_estimate(ss, "b") == {1, 1}

    # Fill and evict: newcomer gets count = min_count + 1, error = min_count
    :ok = SpaceSaving.put(ss, "c")
    # "b" was evicted (count 1). "c" has count 2, error 1 => true in [1, 2]
    assert SpaceSaving.guaranteed_estimate(ss, "c") == {1, 2}
    assert SpaceSaving.guaranteed_estimate(ss, "unseen") == nil
  end

  # -- Frequency guarantee -----------------------------------------------------

  test "items with frequency > N/k are always monitored" do
    k = 10
    ss = SpaceSaving.new(k)

    # Insert k+1 distinct items, each with count 1
    Enum.each(1..(k + 1), fn i -> SpaceSaving.put(ss, "item_#{i}") end)

    # Total N = k+1. Threshold N/k = (k+1)/10. So items with count > (k+1)/10
    # must be monitored. With each at 1, no item has count > (k+1)/10.
    # So we need a different test: insert one item many times so its frequency
    # is > N/k.
    ss2 = SpaceSaving.new(5)
    Enum.each(1..20, fn _ -> SpaceSaving.put(ss2, "heavy") end)
    Enum.each(1..5, fn i -> SpaceSaving.put(ss2, "light_#{i}") end)
    # N = 25, N/k = 5. "heavy" has 20 > 5, so must be monitored
    assert SpaceSaving.monitored?(ss2, "heavy")
    assert SpaceSaving.estimate(ss2, "heavy") == 20
  end

  # -- Data types --------------------------------------------------------------

  test "handles various data types" do
    ss = SpaceSaving.new(20)

    items = [
      "string",
      123,
      :atom,
      {:tuple, "with", "values"},
      [1, 2, 3],
      %{map: "value"}
    ]

    Enum.each(items, fn item ->
      :ok = SpaceSaving.put(ss, item)
      assert SpaceSaving.estimate(ss, item) == 1
      assert SpaceSaving.monitored?(ss, item)
    end)
  end

  # -- Top ---------------------------------------------------------------------

  test "top returns sorted descending" do
    ss = SpaceSaving.new(10)

    Enum.each(1..5, fn _ -> SpaceSaving.put(ss, "a") end)
    Enum.each(1..3, fn _ -> SpaceSaving.put(ss, "b") end)
    :ok = SpaceSaving.put(ss, "c")

    top_all = SpaceSaving.top(ss)
    assert top_all == [{"a", 5}, {"b", 3}, {"c", 1}]

    top_2 = SpaceSaving.top(ss, 2)
    assert top_2 == [{"a", 5}, {"b", 3}]
  end

  test "top with n respects parameter" do
    ss = SpaceSaving.new(5)
    Enum.each(1..5, fn i -> SpaceSaving.put(ss, "item_#{i}") end)
    assert length(SpaceSaving.top(ss, 2)) == 2
    assert length(SpaceSaving.top(ss, nil)) == 5
  end

  # -- Merge -------------------------------------------------------------------

  test "merge combines instances" do
    s1 = SpaceSaving.new(5)
    s2 = SpaceSaving.new(5)

    Enum.each(1..4, fn _ -> SpaceSaving.put(s1, "a") end)
    Enum.each(1..3, fn _ -> SpaceSaving.put(s2, "a") end)
    Enum.each(1..2, fn _ -> SpaceSaving.put(s2, "b") end)

    merged = SpaceSaving.merge([s1, s2])

    assert SpaceSaving.estimate(merged, "a") == 7
    assert SpaceSaving.estimate(merged, "b") == 2

    assert SpaceSaving.total_count(merged) ==
             SpaceSaving.total_count(s1) + SpaceSaving.total_count(s2)
  end

  test "merge respects capacity" do
    s1 = SpaceSaving.new(2)
    s2 = SpaceSaving.new(2)

    SpaceSaving.put(s1, "x")
    SpaceSaving.put(s1, "y")
    SpaceSaving.put(s2, "z")
    SpaceSaving.put(s2, "w")

    merged = SpaceSaving.merge([s1, s2])
    assert SpaceSaving.size(merged) == 2
    assert SpaceSaving.capacity(merged) == 2
  end

  test "merge raises for different capacities" do
    s1 = SpaceSaving.new(5)
    s2 = SpaceSaving.new(10)

    assert_raise ArgumentError, ~r/capacity/, fn ->
      SpaceSaving.merge([s1, s2])
    end
  end

  # -- Serialization -----------------------------------------------------------

  test "serialize and deserialize round-trip preserves state" do
    ss = SpaceSaving.new(5)

    Enum.each(1..3, fn _ -> SpaceSaving.put(ss, "a") end)
    Enum.each(1..2, fn _ -> SpaceSaving.put(ss, "b") end)
    SpaceSaving.put(ss, "c")

    binary = SpaceSaving.serialize(ss)
    restored = SpaceSaving.deserialize(binary)

    assert SpaceSaving.capacity(restored) == 5
    assert SpaceSaving.size(restored) == 3
    assert SpaceSaving.total_count(restored) == SpaceSaving.total_count(ss)
    assert SpaceSaving.estimate(restored, "a") == 3
    assert SpaceSaving.estimate(restored, "b") == 2
    assert SpaceSaving.estimate(restored, "c") == 1
  end

  test "serialize and deserialize empty structure" do
    ss = SpaceSaving.new(10)
    binary = SpaceSaving.serialize(ss)
    restored = SpaceSaving.deserialize(binary)

    assert SpaceSaving.capacity(restored) == 10
    assert SpaceSaving.size(restored) == 0
    assert SpaceSaving.total_count(restored) == 0
    assert SpaceSaving.estimate(restored, "anything") == 0
  end

  # -- Reset -------------------------------------------------------------------

  test "reset clears counters and preserves capacity" do
    ss = SpaceSaving.new(5)

    Enum.each(1..3, fn _ -> SpaceSaving.put(ss, "a") end)
    assert SpaceSaving.estimate(ss, "a") == 3

    reset = SpaceSaving.reset(ss)
    assert SpaceSaving.capacity(reset) == 5
    assert SpaceSaving.size(reset) == 0
    assert SpaceSaving.total_count(reset) == 0
    assert SpaceSaving.estimate(reset, "a") == 0
  end

  # -- Edge cases --------------------------------------------------------------

  test "capacity 1" do
    ss = SpaceSaving.new(1)

    SpaceSaving.put(ss, "first")
    assert SpaceSaving.estimate(ss, "first") == 1

    SpaceSaving.put(ss, "second")
    refute SpaceSaving.monitored?(ss, "first")
    assert SpaceSaving.estimate(ss, "second") == 2
  end

  test "update with count > 1" do
    ss = SpaceSaving.new(5)

    :ok = SpaceSaving.update(ss, "item", 10)
    assert SpaceSaving.estimate(ss, "item") == 10
    assert SpaceSaving.total_count(ss) == 10

    :ok = SpaceSaving.update(ss, "item", 5)
    assert SpaceSaving.estimate(ss, "item") == 15
    assert SpaceSaving.total_count(ss) == 15
  end

  test "monitored? for present and absent items" do
    ss = SpaceSaving.new(5)
    SpaceSaving.put(ss, "here")
    assert SpaceSaving.monitored?(ss, "here")
    refute SpaceSaving.monitored?(ss, "absent")
  end

  test "size and capacity" do
    ss = SpaceSaving.new(10)
    assert SpaceSaving.capacity(ss) == 10
    assert SpaceSaving.size(ss) == 0

    SpaceSaving.put(ss, "a")
    SpaceSaving.put(ss, "b")
    assert SpaceSaving.size(ss) == 2
  end
end
