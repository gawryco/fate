# Fate

[![Hex.pm](https://img.shields.io/hexpm/v/fate.svg)](https://hex.pm/packages/fate)
[![Hex.pm](https://img.shields.io/hexpm/dt/fate.svg)](https://hex.pm/packages/fate)
[![CI](https://github.com/YOUR_USERNAME/fate/workflows/CI/badge.svg)](https://github.com/gawryco/fate/actions)
[![Coverage](https://img.shields.io/badge/coverage-87%25-green)](https://github.com/gawryco/fate)

<p align="center">
  <img src="docs/assets/fate-logo.png" alt="Fate logo" width="260">
</p>

**High-performance probabilistic data structures for Elixir**

Fate provides concurrent, space-efficient implementations of probabilistic data structures backed by `:atomics` for thread-safe operations. Perfect for membership testing, cardinality estimation, and frequency counting at scale.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Data Structures](#data-structures)
  - [Bloom Filter](#bloom-filter)
  - [Cuckoo Filter](#cuckoo-filter)
  - [HyperLogLog](#hyperloglog)
- [Performance](#performance)
- [When to Use What](#when-to-use-what)
- [Documentation](#documentation)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)
- [References](#references)

## Features

- 🚀 **High Performance**: Optimized implementations matching or exceeding Erlang reference libraries
- 🔒 **Concurrent**: Thread-safe operations using `:atomics` with lock-free reads
- 🎯 **Pluggable Hashing**: Support for multiple hash functions (xxHash, Murmur3, XXH3, FNV1a)
- 📊 **Accurate Cardinality**: HyperLogLog delivers lock-free distinct counting at sub-millisecond speeds
- 📦 **Zero Dependencies**: Core functionality requires no external dependencies
- 🧪 **Well Tested**: Comprehensive test coverage (~87%) with 61+ tests
- 🔄 **Production Ready**: Battle-tested algorithms with comprehensive error handling

## Installation

Add `fate` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fate, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get` to install.

### Optional Hash Function Dependencies

For better performance, install one or more hash function libraries:

```elixir
def deps do
  [
    {:fate, "~> 0.1.0"},
    # Choose one or more:
    {:xxh3, "~> 0.3"},      # Fastest for most workloads
    {:xxhash, "~> 0.3"},    # Fast general-purpose hash
    {:murmur, "~> 2.0"}     # Good distribution
  ]
end
```

Fate will automatically select the best available hash function, or you can specify one explicitly.

## Quick Start

```elixir
# Bloom Filter - Fast membership testing
bloom = Fate.Filter.Bloom.new(1000, false_positive_probability: 0.01)
Fate.Filter.Bloom.put(bloom, "user:123")
Fate.Filter.Bloom.member?(bloom, "user:123")  # => true

# Cuckoo Filter - Membership testing with deletion
cuckoo = Fate.Filter.Cuckoo.new(1000)
Fate.Filter.Cuckoo.put(cuckoo, "session:abc")
Fate.Filter.Cuckoo.delete(cuckoo, "session:abc")  # => :ok
Fate.Filter.Cuckoo.member?(cuckoo, "session:abc")  # => false
```

## Data Structures

### Bloom Filter

Space-efficient probabilistic set membership testing with configurable false-positive rates.

**Key Features:**
- Configurable false-positive probability
- Cardinality estimation
- Serialization/deserialization
- Set operations (merge, intersection)
- No deletion support

**Example:**

```elixir
alias Fate.Filter.Bloom

# Create a filter for ~1000 items with 1% false positive rate
bloom = Bloom.new(1000, false_positive_probability: 0.01)

# Insert items
Bloom.put(bloom, "user:123")
Bloom.put(bloom, "user:456")

# Check membership
Bloom.member?(bloom, "user:123")  # => true
Bloom.member?(bloom, "user:789")  # => false (probably)

# Get statistics
Bloom.cardinality(bloom)  # => ~2
Bloom.false_positive_probability(bloom)  # => ~0.01
Bloom.bits_info(bloom)    # => %{total_bits: ..., set_bits_count: ..., set_ratio: ...}

# Serialize for storage
binary = Bloom.serialize(bloom)
restored = Bloom.deserialize(binary)

# Merge multiple filters
merged = Bloom.merge([bloom1, bloom2, bloom3])
intersected = Bloom.intersection([bloom1, bloom2])
```

**Performance**: ~2x faster than existing Elixir implementations

### Cuckoo Filter

Compact filter with deletion support, making it more versatile than Bloom filters.

**Key Features:**
- Item deletion support (unlike Bloom filters)
- Dynamic insertion with bounded relocation
- Exact item count tracking
- Serialization/deserialization
- Set operations (merge, intersection)
- Statistics and analytics

**Example:**

```elixir
alias Fate.Filter.Cuckoo

# Create a filter for ~1000 items
cuckoo = Cuckoo.new(1000)

# Insert items
:ok = Cuckoo.put(cuckoo, "session:abc")
:ok = Cuckoo.put(cuckoo, "session:def")

# Check membership
Cuckoo.member?(cuckoo, "session:abc")  # => true
Cuckoo.member?(cuckoo, "session:xyz")  # => false

# Delete items (unique to Cuckoo filters!)
:ok = Cuckoo.delete(cuckoo, "session:abc")
Cuckoo.member?(cuckoo, "session:abc")  # => false

# Check capacity and load
Cuckoo.size(cuckoo)         # => 1
Cuckoo.capacity(cuckoo)     # => 1000
Cuckoo.load_factor(cuckoo)  # => 0.0002...

# Get statistics
Cuckoo.bits_info(cuckoo)              # => %{total_slots: ..., occupied_slots: ..., ...}
Cuckoo.cardinality(cuckoo)            # => 1 (same as size for Cuckoo)
Cuckoo.false_positive_probability(cuckoo)  # => ~0.0001

# Serialize for storage
binary = Cuckoo.serialize(cuckoo)
restored = Cuckoo.deserialize(binary)

# Merge multiple filters
merged = Cuckoo.merge([cuckoo1, cuckoo2, cuckoo3])
intersected = Cuckoo.intersection([cuckoo1, cuckoo2])

# Handle full filter
case Cuckoo.put(cuckoo, item) do
  :ok -> :inserted
  {:error, :full} -> :filter_full
end
```

**Performance**: On par with Erlang reference implementation when using the same hash function

### HyperLogLog

Approximate distinct counter with configurable precision and lock-free updates, ideal for large-scale analytics.

**Key Features:**
- Precision range 4–18 with <1% typical relative error at default settings
- Lock-free concurrent updates backed by `:atomics`
- Supports `add_hashed/2` for workloads that already have 64-bit hashes
- Mergeable sketches with serialization support

**Example:**

```elixir
alias Fate.Cardinality.HyperLogLog

# Create a sketch with default precision (14)
hll = HyperLogLog.new()

# Add raw items using the selected hash module
Enum.each(1..1_000, &HyperLogLog.add(hll, &1))

# Or skip hashing if you already have 64-bit hashes
Enum.each(1..1_000, fn value ->
  hash = :erlang.phash2({value, 0})
  HyperLogLog.add_hashed(hll, hash)
end)

# Estimate distinct count
HyperLogLog.cardinality(hll)  # => ~1000

# Merge sketches
merged = HyperLogLog.merge([hll, HyperLogLog.new()])
```

**Performance**: Outruns Erlang `HLL` and Elixir `Hypex` when fed pre-hashed values (see [Performance](#performance))

## Configuration

### Custom Hash Functions

```elixir
# Specify a hash function explicitly
bloom = Fate.Filter.Bloom.new(1000, hash_module: Fate.Hash.XXH3)
cuckoo = Fate.Filter.Cuckoo.new(1000, hash_module: Fate.Hash.Murmur3)

# Or let Fate choose the best available
hash_module = Fate.Hash.module()  # Auto-selects best available
```

### Advanced Configuration

```elixir
# Bloom filter with custom parameters
bloom = Fate.Filter.Bloom.new(10_000,
  false_positive_probability: 0.001,  # 0.1% FPP
  hash_count: 10,                     # Override optimal k
  hash_module: Fate.Hash.XXH3
)

# Cuckoo filter with custom parameters
cuckoo = Fate.Filter.Cuckoo.new(10_000,
  bucket_size: 4,          # Slots per bucket (default: 4)
  fingerprint_bits: 16,   # Bits per fingerprint (default: 16)
  load_factor: 0.95,      # Target load before failures (default: 0.95)
  max_kicks: 100,         # Max relocation attempts (default: 100)
  hash_module: Fate.Hash.Default
)
```

## Performance

Benchmarks on Intel Xeon E5-2695 v4 @ 2.10GHz:

### Bloom Filter vs Talan.BloomFilter

```
# Insert 10k items
Fate.Bloom put/2         12.82 ips (78.00 ms)
Talan.BloomFilter put/2   5.74 ips (174.21 ms) - 2.23x slower

# Lookup 10k items
Fate.Bloom member?/2     12.89 ips (77.59 ms)
Talan.BloomFilter        6.09 ips (164.29 ms) - 2.12x slower
```

### Cuckoo Filter vs :cuckoo_filter (Erlang)

```
# Insert 10k items (with phash2)
Fate.Cuckoo put/2         ~50 ips (~20 ms)
:cuckoo_filter.add/2      ~55 ips (~18 ms) - 1.1x faster

# Lookup 10k items (with phash2)
Fate.Cuckoo member?/2     121 ips (8.24 ms)
:cuckoo_filter.contains   133 ips (7.53 ms) - 1.09x faster
```

**Note**: Performance is on par when using the same hash function. Differences are within measurement variance.

Run benchmarks locally:

```bash
mix run bench/bloom_cmp.exs
mix run bench/cuckoo_cmp.exs
```

### HyperLogLog vs HLL / Hypex

```
# Insert 1M hashed values (phash2)
Fate.HyperLogLog add_hashed/2   5.22 ips (191.75 ms)
HLL.add/2                       3.19 ips (313.88 ms) - 1.64x slower
Hypex.update/2                  2.68 ips (373.43 ms) - 1.95x slower

# Insert 1k raw values
Fate.HyperLogLog add/2          1.92 K ips (520.71 µs)
HLL.add/2                       2.86 K ips (349.85 µs) - 1.49x faster
Hypex.update/2                  1.15 K ips (872.18 µs) - 1.67x slower

# Cardinality (1M values)
Fate.HyperLogLog cardinality    1.24 K ips (805.81 µs)
HLL.cardinality                 0.72 K ips (1397.38 µs) - 1.73x slower
Hypex.cardinality               1.15 K ips (867.12 µs) - 1.08x slower
```

## When to Use What

### Use Bloom Filter when:
- ✅ You only need membership testing (no deletions)
- ✅ You want to minimize memory usage
- ✅ You need set operations (merge/intersection)
- ✅ False positives are acceptable
- ✅ You need cardinality estimation

### Use Cuckoo Filter when:
- ✅ You need to delete items
- ✅ You want bounded false-positive rates
- ✅ You need exact item counts
- ✅ You need set operations with deletion support
- ✅ Slightly higher memory usage than Bloom is acceptable

### Use HyperLogLog when:
- ✅ You need approximate distinct counts with fixed memory
- ✅ Lock-free concurrent updates are important
- ✅ Sub-millisecond cardinality queries matter
- ✅ You can tolerate small relative error (≈1% by default)
- ✅ You already hash keys and want to reuse those 64-bit hashes (via `add_hashed/2`)

## Documentation

Full documentation is available on [HexDocs](https://hexdocs.pm/fate) (when published).

Generate local documentation:

```bash
mix docs
```

## Testing

The project includes comprehensive test coverage:

```bash
# Run tests
mix test

# Run tests with coverage
mix coveralls

# Generate HTML coverage report
mix coveralls.html
```

**Current Coverage**: ~87% overall
- `Fate.Filter.Bloom`: 97.3%
- `Fate.Filter.Cuckoo`: 89.4%
- `Fate.Hash`: 52.3% (expected - many hash modules are optional)

## Implementation Details

- **Bloom Filter**: Uses double hashing with configurable hash functions, stores bits in `:atomics` words with lock-free CAS operations. Optimized with direct recursion to avoid list allocations.
- **Cuckoo Filter**: Follows the Erlang reference implementation with bitpacked bucket storage, eviction caching, and bounded relocation. Uses fast bit-mixing for alternate index calculation.
- **Hash Functions**: Pluggable via `Fate.Hash` behaviour, with runtime availability checking. Supports XXH3, XXHash, Murmur3, FNV1a, and Erlang's `phash2`.

## Roadmap

Future data structures planned:
- Count-Min Sketch (frequency estimation)
- Quotient Filter (compact alternative to Cuckoo)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/fate.git
cd fate

# Install dependencies
mix deps.get

# Run tests
mix test

# Run benchmarks
mix run bench/bloom_cmp.exs
mix run bench/cuckoo_cmp.exs

# Format code
mix format

# Check formatting
mix format --check-formatted
```

### Contribution Guidelines

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Make sure tests pass (`mix test`)
4. Ensure code is formatted (`mix format`)
5. Add tests for new functionality
6. Update documentation as needed
7. Commit your changes (`git commit -m 'Add some amazing feature'`)
8. Push to the branch (`git push origin feature/amazing-feature`)
9. Open a Pull Request

### Code Style

- Follow Elixir style guide
- Use `mix format` before committing
- Write descriptive commit messages
- Add tests for new features
- Update documentation for API changes

## License

Copyright (c) 2025 Gustavo Gawryszeski

Licensed under the MIT License. See [LICENSE](LICENSE) for details.

## References

- [Bloom Filter (Wikipedia)](https://en.wikipedia.org/wiki/Bloom_filter)
- [Cuckoo Filter: Practically Better Than Bloom](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)
- [Erlang cuckoo_filter](https://github.com/farhadi/cuckoo_filter)

## Acknowledgments

- Inspired by the Erlang `cuckoo_filter` implementation
- Built with performance and concurrency in mind
