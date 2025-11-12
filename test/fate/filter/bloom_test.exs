defmodule Fate.Filter.BloomTest do
  use ExUnit.Case, async: true

  alias Fate.Filter.Bloom

  test "inserts and checks membership" do
    bloom = Bloom.new(128, false_positive_probability: 0.01, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom, "hello")
    assert Bloom.member?(bloom, "hello")
    refute Bloom.member?(bloom, "world")
  end

  test "serialize and deserialize preserve state" do
    bloom =
      1..40
      |> Enum.reduce(Bloom.new(128, hash_module: Fate.Hash.Default), fn i, acc ->
        :ok = Bloom.put(acc, i)
        acc
      end)

    binary = Bloom.serialize(bloom)
    restored = Bloom.deserialize(binary)

    assert restored.bit_length == bloom.bit_length
    assert restored.hash_count == bloom.hash_count
    assert Enum.all?(1..40, &Bloom.member?(restored, &1))
  end

  test "merge and intersection require compatible filters" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom1, :a)
    :ok = Bloom.put(bloom2, :b)

    merged = Bloom.merge([bloom1, bloom2])
    assert Bloom.member?(merged, :a)
    assert Bloom.member?(merged, :b)

    intersected = Bloom.intersection([bloom1, bloom2])
    refute Bloom.member?(intersected, :a)
    refute Bloom.member?(intersected, :b)
  end
end
