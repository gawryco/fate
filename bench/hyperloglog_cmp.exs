Mix.Task.run("app.start")

alias Fate.Cardinality.HyperLogLog
alias Fate.Hash

raw_inputs = %{
  "1k integers" => Enum.to_list(1..1_000),
  # "10k integers" => Enum.to_list(1..10_000),
  # "100k integers" => Enum.to_list(1..100_000),
  "1M integers" => Enum.to_list(1..1_000_000)
}

inputs =
  Enum.into(raw_inputs, %{}, fn {label, values} ->
    hashed = Enum.map(values, &(:erlang.phash2({&1, 0})))
    {label, %{raw: values, hashed: hashed}}
  end)

hash_module = Hash.module(preferred: [Fate.Hash.Default, Fate.Hash.XXH3, Fate.Hash.XXHash, Fate.Hash.Murmur3])

IO.puts("\n=== HyperLogLog add/insert performance ===\n")

Benchee.run(
  %{
    "Fate.HyperLogLog add (p=14)" => fn data ->
      hll = HyperLogLog.new(precision: 14, hash_module: hash_module)
      Enum.each(data.raw, &HyperLogLog.add(hll, &1))
      hll
    end,
    "Fate.HyperLogLog add_hashed (phash2)" => fn data ->
      hll = HyperLogLog.new(precision: 14, hash_module: hash_module)
      Enum.each(data.hashed, &HyperLogLog.add_hashed(hll, &1))
      hll
    end,
    "HLL.add (p=14)" => fn data ->
      hll = HLL.new(14)
      Enum.reduce(data.raw, hll, fn i, acc -> HLL.add(acc, i) end)
    end,
    "Hypex.update (p=14)" => fn data ->
      Enum.reduce(data.raw, Hypex.new(14), fn i, acc -> Hypex.update(acc, i) end)
    end
  },
  inputs: inputs,
  time: 5,
  warmup: 2,
  memory_time: 1
)

IO.puts("\n=== HyperLogLog cardinality estimation performance ===\n")

Benchee.run(
  %{
    "Fate.HyperLogLog cardinality" => fn %{fate_hll: hll} ->
      HyperLogLog.cardinality(hll)
    end,
    "HLL.cardinality" => fn %{hll: hll} ->
      HLL.cardinality(hll)
    end,
    "Hypex.cardinality" => fn %{hypex_hll: hll} ->
      Hypex.cardinality(hll)
    end
  },
  inputs: inputs,
  before_scenario: fn data ->
    fate_hll = HyperLogLog.new(precision: 14, hash_module: hash_module)
    Enum.each(data.raw, &HyperLogLog.add(fate_hll, &1))

    hll = Enum.reduce(data.raw, HLL.new(14), fn i, acc -> HLL.add(acc, i) end)

    hypex_hll = Enum.reduce(data.raw, Hypex.new(14), fn i, acc -> Hypex.update(acc, i) end)

    %{fate_hll: fate_hll, hll: hll, hypex_hll: hypex_hll}
  end,
  time: 5,
  warmup: 2,
  memory_time: 1
)
