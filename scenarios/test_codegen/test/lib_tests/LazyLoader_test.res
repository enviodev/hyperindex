open RescriptMocha

describe("LazyLoader", () => {
  describe("calculateBackoffDelay", () => {
    it("returns value within expected range for attempt 0", () => {
      // For attempt 0: base * 2^0 = base * 1 = 1000
      // With jitter (0.5 to 1.0): 500 to 1000
      let delay = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=1000,
        ~maxDelayMillis=60000,
        ~attempt=0,
      )
      Assert.ok(delay >= 500 && delay <= 1000, ~message="Delay should be between 500ms and 1000ms")
    })

    it("increases exponentially with each attempt", () => {
      // Collect multiple samples to verify exponential growth
      // attempt 0: base * 1 = 1000 -> [500, 1000]
      // attempt 1: base * 2 = 2000 -> [1000, 2000]
      // attempt 2: base * 4 = 4000 -> [2000, 4000]
      // attempt 3: base * 8 = 8000 -> [4000, 8000]
      let baseDelay = 1000
      let maxDelay = 60000

      let delay0 = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=baseDelay,
        ~maxDelayMillis=maxDelay,
        ~attempt=0,
      )
      let delay1 = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=baseDelay,
        ~maxDelayMillis=maxDelay,
        ~attempt=1,
      )
      let delay2 = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=baseDelay,
        ~maxDelayMillis=maxDelay,
        ~attempt=2,
      )
      let delay3 = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=baseDelay,
        ~maxDelayMillis=maxDelay,
        ~attempt=3,
      )

      // Verify ranges (accounting for jitter factor of 0.5 to 1.0)
      Assert.ok(delay0 >= 500 && delay0 <= 1000, ~message="Attempt 0: delay should be 500-1000ms")
      Assert.ok(
        delay1 >= 1000 && delay1 <= 2000,
        ~message="Attempt 1: delay should be 1000-2000ms",
      )
      Assert.ok(
        delay2 >= 2000 && delay2 <= 4000,
        ~message="Attempt 2: delay should be 2000-4000ms",
      )
      Assert.ok(
        delay3 >= 4000 && delay3 <= 8000,
        ~message="Attempt 3: delay should be 4000-8000ms",
      )
    })

    it("caps delay at maxDelayMillis", () => {
      // With attempt 10: base * 2^10 = 1000 * 1024 = 1,024,000
      // But max is 5000, so should be capped
      // With jitter (0.5 to 1.0): 2500 to 5000
      let delay = LazyLoader.calculateBackoffDelay(
        ~baseDelayMillis=1000,
        ~maxDelayMillis=5000,
        ~attempt=10,
      )
      Assert.ok(
        delay >= 2500 && delay <= 5000,
        ~message="Delay should be capped at max (2500-5000ms with jitter)",
      )
    })

    it("applies jitter consistently", () => {
      // Run multiple times and verify all results are within jitter range
      let baseDelay = 1000
      let maxDelay = 60000
      let attempt = 2
      // Expected: 1000 * 4 = 4000, with jitter: 2000-4000

      let results = []
      for _ in 0 to 19 {
        let delay = LazyLoader.calculateBackoffDelay(
          ~baseDelayMillis=baseDelay,
          ~maxDelayMillis=maxDelay,
          ~attempt,
        )
        let _ = results->Js.Array2.push(delay)
      }

      // All results should be in valid range
      let allInRange = results->Belt.Array.every(d => d >= 2000 && d <= 4000)
      Assert.ok(allInRange, ~message="All delays should be within jitter range (2000-4000ms)")

      // At least some variation (jitter is working) - check that not all values are identical
      let hasVariation = {
        let first = results[0]->Belt.Option.getWithDefault(0)
        results->Belt.Array.some(d => d != first)
      }
      Assert.ok(hasVariation, ~message="Should have some variation due to jitter")
    })
  })

  describe("make", () => {
    it("creates loader with correct default configuration", () => {
      let loader = LazyLoader.make(~loaderFn=async k => k)

      // Check defaults
      Assert.deepEqual(loader._cacheSize, 10_000, ~message="Default cache size should be 10000")
      Assert.deepEqual(
        loader._loaderPoolSize,
        10,
        ~message="Default loader pool size should be 10",
      )
      Assert.deepEqual(
        loader._baseRetryDelayMillis,
        1_000,
        ~message="Default base retry delay should be 1000ms",
      )
      Assert.deepEqual(
        loader._maxRetryDelayMillis,
        60_000,
        ~message="Default max retry delay should be 60000ms",
      )
      Assert.deepEqual(loader._maxRetries, 10, ~message="Default max retries should be 10")
      Assert.deepEqual(
        loader._timeoutMillis,
        300_000,
        ~message="Default timeout should be 300000ms",
      )
    })

    it("accepts custom configuration", () => {
      let loader = LazyLoader.make(
        ~loaderFn=async k => k,
        ~cacheSize=100,
        ~loaderPoolSize=5,
        ~baseRetryDelayMillis=500,
        ~maxRetryDelayMillis=10000,
        ~maxRetries=3,
        ~timeoutMillis=5000,
      )

      Assert.deepEqual(loader._cacheSize, 100, ~message="Custom cache size")
      Assert.deepEqual(loader._loaderPoolSize, 5, ~message="Custom loader pool size")
      Assert.deepEqual(loader._baseRetryDelayMillis, 500, ~message="Custom base retry delay")
      Assert.deepEqual(loader._maxRetryDelayMillis, 10000, ~message="Custom max retry delay")
      Assert.deepEqual(loader._maxRetries, 3, ~message="Custom max retries")
      Assert.deepEqual(loader._timeoutMillis, 5000, ~message="Custom timeout")
    })
  })

  describe("get", () => {
    Async.it("returns loaded value successfully", async () => {
      let loader = LazyLoader.make(~loaderFn=async key => key ++ "-loaded")

      let result = await loader->LazyLoader.get("test")
      Assert.deepEqual(result, "test-loaded", ~message="Should return loaded value")
    })

    Async.it("caches results for the same key", async () => {
      let callCount = ref(0)
      let loader = LazyLoader.make(
        ~loaderFn=async key => {
          callCount := callCount.contents + 1
          key ++ "-" ++ callCount.contents->Belt.Int.toString
        },
      )

      let result1 = await loader->LazyLoader.get("test")
      let result2 = await loader->LazyLoader.get("test")

      Assert.deepEqual(result1, "test-1", ~message="First call should return value")
      Assert.deepEqual(result2, "test-1", ~message="Second call should return cached value")
      Assert.deepEqual(callCount.contents, 1, ~message="Loader function should only be called once")
    })

    Async.it("handles different keys independently", async () => {
      let loader = LazyLoader.make(~loaderFn=async key => key ++ "-loaded")

      let result1 = await loader->LazyLoader.get("key1")
      let result2 = await loader->LazyLoader.get("key2")

      Assert.deepEqual(result1, "key1-loaded", ~message="First key should load correctly")
      Assert.deepEqual(result2, "key2-loaded", ~message="Second key should load correctly")
    })
  })
})
