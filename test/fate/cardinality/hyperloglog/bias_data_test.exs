defmodule Fate.Cardinality.HyperLogLog.BiasDataTest do
  use ExUnit.Case, async: true

  alias Fate.Cardinality.HyperLogLog.BiasData

  test "threshold returns expected values" do
    assert BiasData.threshold(4) == 10
    assert BiasData.threshold(14) == 11_500
    assert BiasData.threshold(18) == 350_000
  end

  test "raw_estimates and biases have matching sizes per precision" do
    for p <- 4..18 do
      assert tuple_size(BiasData.raw_estimates(p)) == tuple_size(BiasData.biases(p)),
             "Size mismatch at precision #{p}"
    end
  end

  test "raw_estimates are approximately sorted ascending per precision" do
    # The source data has a few entries that are very slightly out of order
    # (< 0.5 difference) due to simulation rounding. This is fine for interpolation.
    for p <- 4..18 do
      estimates = BiasData.raw_estimates(p)
      size = tuple_size(estimates)

      monotonic? =
        Enum.all?(0..(size - 2), fn i ->
          elem(estimates, i) <= elem(estimates, i + 1) + 0.5
        end)

      assert monotonic?, "raw_estimates not approximately sorted for precision #{p}"
    end
  end

  test "table_size returns correct counts" do
    # Precision 4 has the fewest entries, higher precisions have ~200
    assert BiasData.table_size(4) > 0
    assert BiasData.table_size(14) > 0
    assert BiasData.table_size(4) < BiasData.table_size(14)
  end
end
