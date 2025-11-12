Mix.Task.run("app.start")

alias Fate.Filter.Bloom
alias Fate.Hash
alias Talan.BloomFilter, as: TalanBloom

inputs =
  %{
    "1k integers" => Enum.to_list(1..1_000),
    "10k integers" => Enum.to_list(1..10_000)
  }

hash_module = Hash.module(preferred: [Fate.Hash.XXH3, Fate.Hash.XXHash, Fate.Hash.Murmur3])

Benchee.run(
  %{
    "Fate.Bloom put/2" => fn data ->
      filter = Bloom.new(length(data), hash_module: hash_module)
      Enum.each(data, &Bloom.put(filter, &1))
      filter
    end,
    "Talan.BloomFilter put/2" => fn data ->
      filter = TalanBloom.new(length(data))
      Enum.each(data, &TalanBloom.put(filter, &1))
      filter
    end
  },
  inputs: inputs,
  time: 5
)

Benchee.run(
  %{
    "Fate.Bloom member?/2" => fn %{fate_filter: filter, data: data} ->
      Enum.each(data, &Bloom.member?(filter, &1))
    end,
    "Talan.BloomFilter member?/2" => fn %{talan_filter: filter, data: data} ->
      Enum.each(data, &TalanBloom.member?(filter, &1))
    end
  },
  inputs: inputs,
  before_scenario: fn data ->
    fate_filter = Bloom.new(length(data), hash_module: hash_module)
    Enum.each(data, &Bloom.put(fate_filter, &1))

    talan_filter = TalanBloom.new(length(data))
    Enum.each(data, &TalanBloom.put(talan_filter, &1))

    %{data: data, fate_filter: fate_filter, talan_filter: talan_filter}
  end,
  time: 5
)
