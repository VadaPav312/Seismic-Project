import XCTest
@testable import SeismicCore

final class StatsTests: XCTestCase {
    func testBasicMoments() {
        let x = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(Stats.mean(x), 5.0, accuracy: 1e-12)
        // Sample standard deviation (n−1), not population.
        XCTAssertEqual(Stats.stdDev(x), 2.13808993529939, accuracy: 1e-9)
        XCTAssertEqual(Stats.median(x), 4.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.peakAbs([-3, 1, 2]), 3, accuracy: 1e-12)
        XCTAssertEqual(Stats.rms([3, 4]), 3.5355339059327378, accuracy: 1e-12)
    }

    func testMedianAbsoluteDeviationIgnoresOutlier() {
        let clean = [10.0, 10.1, 9.9, 10.2, 9.8]
        let poisoned = clean + [500.0]
        // The MAD barely moves; the standard deviation is destroyed.
        XCTAssertEqual(Stats.mad(clean), Stats.mad(poisoned), accuracy: 0.1)
        XCTAssertGreaterThan(Stats.stdDev(poisoned), 50 * Stats.stdDev(clean))
    }

    func testPercentileInterpolates() {
        let x = [0.0, 1, 2, 3, 4]
        XCTAssertEqual(Stats.percentile(x, 0), 0, accuracy: 1e-12)
        XCTAssertEqual(Stats.percentile(x, 50), 2, accuracy: 1e-12)
        XCTAssertEqual(Stats.percentile(x, 100), 4, accuracy: 1e-12)
        XCTAssertEqual(Stats.percentile(x, 25), 1, accuracy: 1e-12)
    }

    func testLinearRegressionRecoversKnownLine() {
        let x = (0..<50).map(Double.init)
        let y = x.map { 3.5 * $0 - 12 }
        let fit = Stats.linearRegression(x: x, y: y)
        XCTAssertEqual(fit.slope, 3.5, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, -12, accuracy: 1e-9)
        XCTAssertEqual(fit.r2, 1.0, accuracy: 1e-9)
    }

    func testNormalCDFAndInverseRoundTrip() {
        XCTAssertEqual(Stats.normalCDF(0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.normalCDF(1.959963985), 0.975, accuracy: 1e-6)
        for p in [0.01, 0.1, 0.5, 0.9, 0.99] {
            XCTAssertEqual(Stats.normalCDF(Stats.inverseNormalCDF(p)), p, accuracy: 1e-6)
        }
    }

    func testInterpolationClampsOutsideTable() {
        let xs = [0.0, 1, 2], ys = [10.0, 20, 40]
        XCTAssertEqual(Stats.interpolate(x: -5, xs: xs, ys: ys), 10, accuracy: 1e-12)
        XCTAssertEqual(Stats.interpolate(x: 0.5, xs: xs, ys: ys), 15, accuracy: 1e-12)
        XCTAssertEqual(Stats.interpolate(x: 1.5, xs: xs, ys: ys), 30, accuracy: 1e-12)
        XCTAssertEqual(Stats.interpolate(x: 99, xs: xs, ys: ys), 40, accuracy: 1e-12)
    }
}

final class SeededRandomTests: XCTestCase {
    func testSameSeedGivesIdenticalStream() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: 1), b = SeededRandom(seed: 2)
        XCTAssertNotEqual(a.next(), b.next())
    }

    func testGaussianHasExpectedMomentsAndUniformIsInRange() {
        var rng = SeededRandom(seed: 7)
        let g = (0..<20_000).map { _ in rng.gaussian(mean: 2, sd: 3) }
        XCTAssertEqual(Stats.mean(g), 2, accuracy: 0.1)
        XCTAssertEqual(Stats.stdDev(g), 3, accuracy: 0.1)
        let u = (0..<5000).map { _ in rng.uniform(-1, 1) }
        XCTAssertTrue(u.allSatisfy { $0 >= -1 && $0 <= 1 })
    }
}

final class IntensityScaleTests: XCTestCase {
    func testKnownIntensityAnchors() {
        // ~0.02 g barely felt; ~0.3 g is a strong, damaging shake.
        XCTAssertLessThanOrEqual(IntensityScale.fromPGA(0.02 * gravity).continuous, 4.5)
        let strong = IntensityScale.fromPGA(0.30 * gravity)
        XCTAssertGreaterThanOrEqual(strong.continuous, 6.5)
        XCTAssertLessThanOrEqual(strong.continuous, 9.0)
    }

    func testMonotonicInPGA() {
        var last = -Double.infinity
        for pga in stride(from: 0.001, through: 15.0, by: 0.05) {
            let v = IntensityScale.fromPGA(pga).continuous
            XCTAssertGreaterThanOrEqual(v, last - 1e-9)
            last = v
        }
    }

    func testInverseRoundTrips() {
        for mmi in [3.0, 5.0, 6.0, 8.0] {
            let pga = IntensityScale.pgaFor(intensity: mmi)
            XCTAssertEqual(IntensityScale.fromPGA(pga).continuous, mmi, accuracy: 0.05)
        }
    }

    func testEveryIntensityHasHumanConsequence() {
        for i in MercalliIntensity.allCases {
            XCTAssertFalse(i.consequence.isEmpty)
            XCTAssertFalse(i.roman.isEmpty)
        }
    }
}

final class WaveformTests: XCTestCase {
    func testGeometryAndSlicing() {
        let w = Waveform(samples: Array(0..<100).map(Double.init), sampleRate: 50)
        XCTAssertEqual(w.duration, 2.0, accuracy: 1e-12)
        XCTAssertEqual(w.dt, 0.02, accuracy: 1e-12)
        XCTAssertEqual(w.index(atTime: 1.0), 50)
        let s = w.slice(from: 0.5, to: 1.0)
        XCTAssertEqual(s.samples.first, 25)
        XCTAssertEqual(s.samples.last, 50)
    }

    func testSliceOutOfRangeIsClampedNotCrashing() {
        let w = Waveform(samples: [1, 2, 3], sampleRate: 10)
        XCTAssertEqual(w.slice(from: -100, to: 900).samples.count, 3)
        XCTAssertTrue(Waveform(samples: [], sampleRate: 10).slice(from: 0, to: 5).isEmpty)
    }

    func testTriaxialMagnitudeIsOrientationIndependent() {
        let n = 10
        let x = Waveform(samples: Array(repeating: 3, count: n), sampleRate: 100)
        let y = Waveform(samples: Array(repeating: 4, count: n), sampleRate: 100)
        let z = Waveform(samples: Array(repeating: 0, count: n), sampleRate: 100)
        let rec = TriaxialRecord(x: x, y: y, z: z)
        XCTAssertEqual(rec.magnitude.samples[0], 5, accuracy: 1e-12)
        XCTAssertEqual(rec.dominantHorizontal.samples[0], 4, accuracy: 1e-12)
    }
}

final class SecretsTests: XCTestCase {
    func testEnvParsingHandlesRealWorldMess() {
        let env = """
        # a comment
        CEREBRAS_API_KEY=abc123

        export OPENAI_API_KEY = "sk-quoted"
        SUPABASE_URL='https://x.example.com'  # trailing comment
        MALFORMED_LINE_NO_EQUALS
        EMPTY_VALUE=
        """
        let parsed = EnvFileParser.parse(env)
        XCTAssertEqual(parsed["CEREBRAS_API_KEY"], "abc123")
        XCTAssertEqual(parsed["OPENAI_API_KEY"], "sk-quoted")
        XCTAssertEqual(parsed["SUPABASE_URL"], "https://x.example.com")
        XCTAssertEqual(parsed["EMPTY_VALUE"], "")
        XCTAssertNil(parsed["MALFORMED_LINE_NO_EQUALS"])
    }

    func testSettingsValueOverridesEnvFile() {
        let vault = SecretsVault(storage: InMemorySecretStorage())
        vault.bootstrap(from: ["CEREBRAS_API_KEY": "from-env"])
        XCTAssertEqual(vault.value(for: .cerebrasAPIKey), "from-env")
        vault.set(.cerebrasAPIKey, to: "typed-in-settings")
        XCTAssertEqual(vault.value(for: .cerebrasAPIKey), "typed-in-settings")
        vault.clear(.cerebrasAPIKey)
        // Clearing the stored value falls back to .env rather than to nothing.
        XCTAssertEqual(vault.value(for: .cerebrasAPIKey), "from-env")
    }

    func testEndpointKeysAreNeverMissing() {
        let vault = SecretsVault(storage: InMemorySecretStorage())
        XCTAssertEqual(vault.status(for: .wikidataEndpoint), .present)
        XCTAssertEqual(vault.status(for: .overpassEndpoint), .present)
        XCTAssertEqual(vault.status(for: .cerebrasAPIKey), .missing)
    }

    func testFingerprintNeverLeaksTheKey() {
        let vault = SecretsVault(storage: InMemorySecretStorage())
        vault.set(.openAIAPIKey, to: "sk-supersecretvalue12345")
        let fp = vault.fingerprint(for: .openAIAPIKey)
        XCTAssertFalse(fp.contains("supersecret"))
        XCTAssertTrue(fp.hasPrefix("sk-"))
    }

    func testEveryKeyDocumentsItselfAndItsFallback() {
        for key in SecretKey.allCases {
            XCTAssertFalse(key.purpose.isEmpty, "\(key.rawValue) has no purpose")
            XCTAssertFalse(key.fallbackBehaviour.isEmpty, "\(key.rawValue) has no fallback")
        }
    }
}

final class AlgorithmCatalogTests: XCTestCase {
    func testFiftyCountedAlgorithmsArePresentAndNumberedContiguously() {
        let counted = AlgorithmCatalog.all.filter { $0.family != .infrastructure }
        XCTAssertEqual(counted.count, AlgorithmCatalog.countedAlgorithms)
        XCTAssertEqual(counted.map(\.number).sorted(), Array(1...50))
    }

    func testEveryAlgorithmNamesWhereItSurfacesInTheUI() {
        for entry in AlgorithmCatalog.all {
            XCTAssertFalse(entry.surfacedAt.isEmpty, "algorithm \(entry.number) is invisible")
            XCTAssertFalse(entry.purpose.isEmpty, "algorithm \(entry.number) has no purpose")
        }
    }

    func testNumbersAreUnique() {
        let numbers = AlgorithmCatalog.all.map(\.number)
        XCTAssertEqual(Set(numbers).count, numbers.count)
    }
}

final class BuildingModelTests: XCTestCase {
    func testEmpiricalPeriodMatchesRuleOfThumb() {
        // The old engineer's rule: T ≈ N/10 seconds for a moment frame.
        let b = BuildingModel(name: "Test", storeyCount: 10, height: 32,
                              material: .reinforcedConcrete, system: .momentFrame)
        XCTAssertEqual(b.empiricalPeriod, 1.0, accuracy: 0.35)
    }

    func testTallerBuildingsSwayMoreSlowly() {
        let short = BuildingModel(name: "a", storeyCount: 3, height: 10)
        let tall = BuildingModel(name: "b", storeyCount: 40, height: 140)
        XCTAssertLessThan(short.empiricalPeriod, tall.empiricalPeriod)
    }

    func testRetrofitStiffensAndShortensPeriod() {
        let base = BuildingModel(name: "a", storeyCount: 8, height: 26, retrofit: .none)
        let fixed = BuildingModel(name: "a", storeyCount: 8, height: 26, retrofit: .full)
        XCTAssertLessThan(fixed.empiricalPeriod, base.empiricalPeriod)
    }

    func testDegenerateInputsAreClampedNotAccepted() {
        let b = BuildingModel(name: "bad", storeyCount: 0, height: -5, footprintArea: 0)
        XCTAssertGreaterThanOrEqual(b.storeyCount, 1)
        XCTAssertGreaterThan(b.height, 0)
        XCTAssertFalse(b.footprint.isEmpty)
    }
}
