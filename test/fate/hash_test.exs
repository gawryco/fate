defmodule Fate.HashTest do
  use ExUnit.Case, async: true

  alias Fate.Hash

  defmodule UnavailableHash do
    @behaviour Fate.Hash

    @impl true
    def available?, do: false

    @impl true
    def hash(_term, _seed), do: raise("should not be called")
  end

  describe "module/1" do
    test "returns an available provider by default" do
      provider = Hash.module()
      assert Hash.available?(provider)
    end

    test "respects preferred list and skips unavailable providers" do
      provider = Hash.module(preferred: [UnavailableHash, Hash.FNV1a, Hash.Default])
      assert provider == Hash.FNV1a
    end
  end

  describe "hash/3" do
    test "selects default provider when nil" do
      value = Hash.hash(nil, "hello", 0)
      assert is_integer(value)
    end

    for provider <- [Hash.FNV1a, Hash.Default] do
      test "hash/3 returns integer for #{inspect(provider)}" do
        assert Hash.available?(unquote(provider))
        value = Hash.hash(unquote(provider), {:sample, 42}, 123)
        assert is_integer(value)
      end
    end

    optional_providers = [Hash.XXH3, Hash.XXHash, Hash.Murmur3]

    Enum.each(optional_providers, fn provider ->
      test "hash/3 works when #{inspect(provider)} is available" do
        if Hash.available?(unquote(provider)) do
          value = Hash.hash(unquote(provider), "optional", 99)
          assert is_integer(value)
        else
          refute Hash.available?(unquote(provider))
        end
      end
    end)
  end
end
