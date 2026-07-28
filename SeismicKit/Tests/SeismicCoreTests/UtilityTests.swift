import XCTest
@testable import SeismicCore

final class BackoffTests: XCTestCase {

    func testDelayGrowsExponentiallyAndIsCapped() {
        let policy = BackoffPolicy(initialDelay: 1, maximumDelay: 20, multiplier: 2,
                                   jitterFraction: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 100), 20, accuracy: 1e-9)
    }

    func testJitterSpreadsRetriesWithinTheExpectedBand() {
        var rng = SeededRandom(seed: 5)
        let policy = BackoffPolicy(initialDelay: 4, maximumDelay: 60, multiplier: 2,
                                   jitterFraction: 0.5)
        var delays: [Double] = []
        for _ in 0..<500 { delays.append(policy.delay(forAttempt: 3, using: &rng)) }

        // Attempt 3 is a 16 s base; with 50% jitter the delay lies in 8…16 s.
        XCTAssertTrue(delays.allSatisfy { $0 >= 8 - 1e-9 && $0 <= 16 + 1e-9 })
        // And it must genuinely vary, or the whole point is lost.
        XCTAssertGreaterThan(Stats.stdDev(delays), 1.0)
    }

    func testTwoClientsRetryingTogetherDoNotStayInLockstep() {
        var a = SeededRandom(seed: 1), b = SeededRandom(seed: 2)
        let policy = BackoffPolicy.network
        var collisions = 0
        for attempt in 1...50 {
            let delayA = policy.delay(forAttempt: attempt, using: &a)
            let delayB = policy.delay(forAttempt: attempt, using: &b)
            if abs(delayA - delayB) < 0.001 { collisions += 1 }
        }
        XCTAssertLessThan(collisions, 3)
    }

    func testZeroJitterIsDeterministic() {
        var rng = SeededRandom(seed: 1)
        let policy = BackoffPolicy(initialDelay: 2, maximumDelay: 100, multiplier: 3,
                                   jitterFraction: 0)
        XCTAssertEqual(policy.delay(forAttempt: 2, using: &rng), 6, accuracy: 1e-9)
    }

    func testStateResetsOnSuccess() {
        var state = BackoffState(policy: .bluetooth)
        state.recordFailure(); state.recordFailure(); state.recordFailure()
        XCTAssertEqual(state.attempt, 3)
        XCTAssertGreaterThan(state.nextDelay, 0)
        state.recordSuccess()
        XCTAssertEqual(state.attempt, 0)
        XCTAssertEqual(state.nextDelay, 0)
    }

    func testBluetoothPolicyNeverGivesUp() {
        var state = BackoffState(policy: .bluetooth)
        for _ in 0..<200 { state.recordFailure() }
        XCTAssertFalse(state.hasGivenUp, "a paired node must be retried indefinitely")
    }

    func testNetworkPolicyEventuallyGivesUp() {
        var state = BackoffState(policy: .network)
        for _ in 0..<10 { state.recordFailure() }
        XCTAssertTrue(state.hasGivenUp)
    }

    func testNonsensicalPolicyIsClamped() {
        let policy = BackoffPolicy(initialDelay: -5, maximumDelay: -100, multiplier: 0.1,
                                   jitterFraction: 5)
        XCTAssertGreaterThan(policy.initialDelay, 0)
        XCTAssertGreaterThanOrEqual(policy.maximumDelay, policy.initialDelay)
        XCTAssertGreaterThan(policy.multiplier, 1)
        XCTAssertLessThanOrEqual(policy.jitterFraction, 1)
    }
}

final class TokenBucketTests: XCTestCase {

    func testAllowsABurstUpToCapacity() {
        let bucket = TokenBucket(capacity: 10, refillRate: 1)
        let now = Date()
        for _ in 0..<10 { XCTAssertTrue(bucket.tryConsume(now: now)) }
        XCTAssertFalse(bucket.tryConsume(now: now), "burst exceeded capacity")
    }

    func testRefillsOverTime() {
        let bucket = TokenBucket(capacity: 5, refillRate: 2)   // 2 per second
        let start = Date()
        for _ in 0..<5 { _ = bucket.tryConsume(now: start) }
        XCTAssertFalse(bucket.tryConsume(now: start))

        // One second later, two tokens are back.
        let later = start.addingTimeInterval(1)
        XCTAssertTrue(bucket.tryConsume(now: later))
        XCTAssertTrue(bucket.tryConsume(now: later))
        XCTAssertFalse(bucket.tryConsume(now: later))
    }

    func testNeverExceedsCapacityHoweverLongItWaits() {
        let bucket = TokenBucket(capacity: 3, refillRate: 100)
        let farFuture = Date().addingTimeInterval(10_000)
        var granted = 0
        while bucket.tryConsume(now: farFuture) {
            granted += 1
            if granted > 10 { break }
        }
        XCTAssertEqual(granted, 3)
    }

    func testTimeUntilAvailableIsReportedHonestly() {
        let bucket = TokenBucket(capacity: 2, refillRate: 0.5)   // one every 2 s
        let now = Date()
        _ = bucket.tryConsume(now: now); _ = bucket.tryConsume(now: now)
        XCTAssertEqual(bucket.timeUntilAvailable(now: now), 2, accuracy: 0.01)
        XCTAssertEqual(bucket.timeUntilAvailable(2, now: now), 4, accuracy: 0.01)
    }

    func testZeroWaitWhenTokensAreAvailable() {
        let bucket = TokenBucket(capacity: 5, refillRate: 1)
        XCTAssertEqual(bucket.timeUntilAvailable(), 0)
    }

    func testResetRefillsImmediately() {
        let bucket = TokenBucket(capacity: 4, refillRate: 0.1)
        let now = Date()
        for _ in 0..<4 { _ = bucket.tryConsume(now: now) }
        bucket.reset()
        XCTAssertEqual(bucket.availableTokens, 4, accuracy: 0.01)
    }
}

final class LRUCacheTests: XCTestCase {

    func testStoresAndRetrieves() {
        let cache = LRUCache<String, Int>(countLimit: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "b"), 2)
        XCTAssertNil(cache.value(forKey: "missing"))
    }

    func testEvictsLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(countLimit: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        // Touch "a" so "b" becomes the least recently used.
        _ = cache.value(forKey: "a")
        cache.setValue(4, forKey: "d")

        XCTAssertNil(cache.value(forKey: "b"), "wrong entry evicted")
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.value(forKey: "d"), 4)
        XCTAssertEqual(cache.count, 3)
    }

    func testRecencyOrderIsMaintained() {
        let cache = LRUCache<String, Int>(countLimit: 4)
        for (index, key) in ["a", "b", "c"].enumerated() {
            cache.setValue(index, forKey: key)
        }
        _ = cache.value(forKey: "a")
        XCTAssertEqual(cache.keysByRecency, ["a", "c", "b"])
    }

    func testCostLimitEvictsEvenWhenCountIsFine() {
        let cache = LRUCache<String, Int>(countLimit: 100, costLimit: 10)
        cache.setValue(1, forKey: "big", cost: 8)
        cache.setValue(2, forKey: "small", cost: 1)
        XCTAssertEqual(cache.totalCost, 9)
        cache.setValue(3, forKey: "another", cost: 5)
        XCTAssertLessThanOrEqual(cache.totalCost, 10)
        XCTAssertNil(cache.value(forKey: "big"))
    }

    func testOverwritingUpdatesCostRatherThanAccumulating() {
        let cache = LRUCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.setValue(1, forKey: "a", cost: 5)
        cache.setValue(2, forKey: "a", cost: 3)
        XCTAssertEqual(cache.totalCost, 3)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(forKey: "a"), 2)
    }

    func testRemovalAndClear() {
        let cache = LRUCache<String, Int>(countLimit: 5)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.removeValue(forKey: "a")
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.count, 1)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testHitRateIsTracked() {
        let cache = LRUCache<String, Int>(countLimit: 5)
        cache.setValue(1, forKey: "a")
        _ = cache.value(forKey: "a")       // hit
        _ = cache.value(forKey: "a")       // hit
        _ = cache.value(forKey: "zzz")     // miss
        XCTAssertEqual(cache.hitRate, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testStaysBoundedUnderHeavyChurn() {
        let cache = LRUCache<Int, Int>(countLimit: 50)
        for i in 0..<10_000 { cache.setValue(i, forKey: i) }
        XCTAssertEqual(cache.count, 50)
        XCTAssertNil(cache.value(forKey: 0))
        XCTAssertEqual(cache.value(forKey: 9999), 9999)
    }
}

final class CRCTests: XCTestCase {

    func testCRC16KnownVector() {
        // The standard check value for CRC-16/CCITT-FALSE over "123456789".
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(CRC16.compute(bytes), 0x29B1)
    }

    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.compute(Array("123456789".utf8)), 0xCBF43926)
    }

    func testEmptyInputIsStable() {
        XCTAssertEqual(CRC16.compute([]), 0xFFFF)
        XCTAssertEqual(CRC32.compute([]), 0)
    }

    func testSingleBitFlipIsAlwaysDetected() {
        var rng = SeededRandom(seed: 3)
        for _ in 0..<200 {
            var bytes = (0..<64).map { _ in UInt8(rng.uniform(0, 256)) }
            let original = CRC16.compute(bytes)
            let index = Int(rng.uniform(0, 64))
            let bit = UInt8(1) << UInt8(rng.uniform(0, 8))
            bytes[index] ^= bit
            XCTAssertNotEqual(CRC16.compute(bytes), original)
        }
    }

    func testReorderedBytesAreDetected() {
        // A checksum that merely sums bytes would miss this; a CRC does not.
        XCTAssertNotEqual(CRC16.compute([1, 2, 3, 4]), CRC16.compute([4, 3, 2, 1]))
    }

    func testVerifyHelper() {
        let bytes: [UInt8] = [10, 20, 30]
        XCTAssertTrue(CRC16.verify(bytes, expected: CRC16.compute(bytes)))
        XCTAssertFalse(CRC16.verify(bytes, expected: 0))
    }
}

final class DeltaEncodingTests: XCTestCase {

    func testZigZagRoundTrips() {
        for value: Int32 in [0, -1, 1, -2, 2, 1000, -1000, Int32.max, Int32.min] {
            XCTAssertEqual(DeltaEncoding.unZigZag(DeltaEncoding.zigZag(value)), value)
        }
    }

    func testZigZagMapsSmallNegativesToSmallPositives() {
        XCTAssertEqual(DeltaEncoding.zigZag(0), 0)
        XCTAssertEqual(DeltaEncoding.zigZag(-1), 1)
        XCTAssertEqual(DeltaEncoding.zigZag(1), 2)
        XCTAssertEqual(DeltaEncoding.zigZag(-2), 3)
    }

    func testIntegerRoundTrip() {
        let values: [Int32] = [0, 5, 5, 6, 4, -3, 1000, 1001, 999, -20000]
        let encoded = DeltaEncoding.encode(values)
        XCTAssertEqual(DeltaEncoding.decode(encoded, count: values.count), values)
    }

    func testWaveformRoundTripWithinQuantisationError() {
        var rng = SeededRandom(seed: 12)
        let samples = (0..<2000).map { i in
            sin(Double(i) * 0.05) * 2 + rng.gaussian(sd: 0.01)
        }
        let encoded = DeltaEncoding.encodeSamples(samples)
        let decoded = DeltaEncoding.decodeSamples(encoded, count: samples.count)
        XCTAssertEqual(decoded.count, samples.count)
        for i in samples.indices {
            XCTAssertEqual(decoded[i], samples[i], accuracy: 1e-4)
        }
    }

    func testSmoothSignalsCompressWell() {
        // A real accelerometer trace: correlated samples, small deltas.
        let samples = (0..<5000).map { sin(Double($0) * 0.02) * 0.5 }
        let encoded = DeltaEncoding.encodeSamples(samples)
        let ratio = DeltaEncoding.compressionRatio(originalCount: samples.count,
                                                   encodedBytes: encoded.count)
        XCTAssertGreaterThan(ratio, 2.0, "delta encoding is not paying for itself")
    }

    func testNoiseCompressesLessThanSignal() {
        var rng = SeededRandom(seed: 4)
        let smooth = (0..<3000).map { sin(Double($0) * 0.01) }
        let noisy = (0..<3000).map { _ in rng.gaussian(sd: 1) }
        XCTAssertLessThan(DeltaEncoding.encodeSamples(smooth).count,
                          DeltaEncoding.encodeSamples(noisy).count)
    }

    func testTruncatedDataDecodesWhatItCanRatherThanCrashing() {
        let values: [Int32] = Array(0..<100)
        var encoded = DeltaEncoding.encode(values)
        encoded = encoded.prefix(20)
        let decoded = DeltaEncoding.decode(encoded, count: 100)
        XCTAssertLessThan(decoded.count, 100)
        XCTAssertEqual(Array(decoded.prefix(10)), Array(values.prefix(10)))
    }

    func testEmptyInput() {
        XCTAssertTrue(DeltaEncoding.encode([Int32]()).isEmpty)
        XCTAssertTrue(DeltaEncoding.decode(Data(), count: 10).isEmpty)
    }
}

final class FuzzyMatchTests: XCTestCase {

    func testEditDistanceKnownValues() {
        XCTAssertEqual(FuzzyMatch.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(FuzzyMatch.editDistance("", "abc"), 3)
        XCTAssertEqual(FuzzyMatch.editDistance("same", "same"), 0)
        XCTAssertEqual(FuzzyMatch.editDistance("Same", "same"), 0, "must be case insensitive")
    }

    func testSimilarityIsOneForIdenticalAndLowForUnrelated() {
        XCTAssertEqual(FuzzyMatch.similarity("Eiffel Tower", "Eiffel Tower"), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(FuzzyMatch.similarity("Eiffel Tower", "Eifel Tower"), 0.9)
        XCTAssertLessThan(FuzzyMatch.similarity("Eiffel Tower", "Sydney Opera House"), 0.4)
    }

    func testTokenSimilarityHandlesReorderingAndFillerWords() {
        XCTAssertGreaterThan(FuzzyMatch.tokenSimilarity("The Eiffel Tower", "Tower Eiffel"), 0.9)
        // Edit distance alone does badly on this; token matching does not.
        XCTAssertLessThan(FuzzyMatch.similarity("The Eiffel Tower", "Tower Eiffel"), 0.6)
        XCTAssertGreaterThan(FuzzyMatch.combinedSimilarity("The Eiffel Tower", "Tower Eiffel"), 0.9)
    }

    func testTokenisationDropsStopWordsAndPunctuation()  {
        let tokens = FuzzyMatch.tokenise("The Tower of London!")
        XCTAssertTrue(tokens.contains("tower"))
        XCTAssertTrue(tokens.contains("london"))
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("of"))
    }

    func testEmptyStrings() {
        XCTAssertEqual(FuzzyMatch.similarity("", ""), 1)
        XCTAssertEqual(FuzzyMatch.tokenSimilarity("", "anything"), 0)
    }
}

final class BM25Tests: XCTestCase {

    private func index() -> BM25<Int> {
        var engine = BM25<Int>()
        engine.index([
            .init(id: 1, text: "Eiffel Tower Paris iron lattice tower"),
            .init(id: 2, text: "Chrysler Building New York art deco skyscraper"),
            .init(id: 3, text: "Tokyo Skytree broadcasting tower Japan"),
            .init(id: 4, text: "Empire State Building New York skyscraper"),
            .init(id: 5, text: "Sydney Opera House Australia concert hall"),
        ])
        return engine
    }

    func testFindsTheObviousMatchFirst() {
        let results = index().search("Eiffel Tower")
        XCTAssertEqual(results.first?.id, 1)
    }

    func testRareTermsOutweighCommonOnes() {
        // "tower" appears in several documents; "Chrysler" in exactly one. A
        // naive term-frequency ranker would prefer the document with more
        // "tower" hits.
        let results = index().search("Chrysler tower")
        XCTAssertEqual(results.first?.id, 2)
    }

    func testMultiWordQueriesCombineEvidence() {
        let results = index().search("New York skyscraper")
        let top = Set(results.prefix(2).map(\.id))
        XCTAssertEqual(top, [2, 4])
    }

    func testNoMatchReturnsNothingRatherThanEverything() {
        XCTAssertTrue(index().search("submarine volcano").isEmpty)
    }

    func testEmptyQueryOrEmptyIndexIsSafe() {
        XCTAssertTrue(index().search("").isEmpty)
        var empty = BM25<Int>()
        empty.index([])
        XCTAssertTrue(empty.search("anything").isEmpty)
    }

    func testScoresAreDescending() {
        let results = index().search("tower building")
        for i in 1..<results.count {
            XCTAssertGreaterThanOrEqual(results[i - 1].score, results[i].score)
        }
    }

    func testLimitIsRespected() {
        XCTAssertLessThanOrEqual(index().search("tower building york", limit: 2).count, 2)
    }

    func testRepeatedTermsSaturateRatherThanScaleLinearly() {
        var engine = BM25<Int>()
        engine.index([
            .init(id: 1, text: "tower"),
            .init(id: 2, text: "tower tower tower tower tower tower tower tower"),
        ])
        let results = engine.search("tower")
        let scores = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.score) })
        // Eight times the mentions must not mean eight times the score.
        XCTAssertLessThan(scores[2] ?? 0, (scores[1] ?? 0) * 4)
    }
}
