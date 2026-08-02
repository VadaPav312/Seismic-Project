import Foundation
import SeismicCore
import SeismicSignal
import SeismicStructures
import SeismicData
import SeismicDevice

/// Turns a recorded event into a verdict.
///
/// This is where the algorithms meet: the recording is conditioned and
/// characterised, the building's period is measured before and after and
/// corrected for temperature, the structural model is run to estimate demand,
/// each measurement is turned into a piece of stated evidence, and the whole lot
/// is fused into one probability with an honest interval.
///
/// Every intermediate result is kept on the assessment so the screen can show
/// its working. Nothing here contributes to a verdict without appearing in the
/// evidence list.
enum AssessmentEngine {

    static func assess(building: BuildingModel,
                       event: SeismicEvent,
                       history: [ModeObservation],
                       store: SeismicStore) -> Assessment {

        var evidence: [Evidence] = []
        let record = event.record ?? store.recording(for: event.id)

        // MARK: Shaking severity — context for everything that follows.

        var peaks = PeakValues(pga: 0, pgv: 0, pgd: 0, pgaTime: 0)
        var energy = EnergyMeasures(arias: 0, cav: 0, significantDuration: 0,
                                    durationStart: 0, durationEnd: 0, husid: [])
        if let record, record.count > 16 {
            peaks = GroundMotion.peaks(record)
            energy = EnergyAnalysis.compute(record.magnitude)
            evidence.append(EvidenceBuilder.fromShakingSeverity(
                pga: peaks.pga, cav: energy.cav,
                thresholdExceeded: energy.exceedsDamageThreshold))
        }

        // MARK: Period, before and after, temperature corrected.

        let modeOne = history.filter { $0.modeNumber == 1 }.sorted { $0.at < $1.at }
        let temperatureModel = TemperatureNormalisation.fit(modeOne)

        // "Before" is the median of the settled history preceding the event,
        // which is far more robust than the single most recent scan.
        let before = modeOne.filter { $0.at < event.startTime }
        let baselinePeriod = before.isEmpty ? building.empiricalPeriod
            : Stats.median(before.suffix(60).map(\.period))
        let baselineTemperature = before.isEmpty ? nil
            : Stats.median(before.suffix(60).compactMap(\.temperature))

        // "After" comes from the post-event record itself where possible: the
        // building's free decay after the shaking stops is the cleanest
        // measurement of its period that will ever be available.
        var measuredAfter: Double?
        var measurementConfidence = 0.5
        if let record, record.count > 256 {
            let tail = record.dominantHorizontal.slice(
                from: max(record.duration * 0.65, energy.durationEnd),
                to: record.duration)
            if tail.count > 128 {
                let crossChecked = PeriodEstimation.crossChecked(
                    tail, band: (building.empiricalPeriod * 0.35)...(building.empiricalPeriod * 3.5))
                measuredAfter = crossChecked.consensus
                measurementConfidence = crossChecked.agreement
            }
        }
        // Fall back to the most recent scan if the record could not be measured.
        if measuredAfter == nil {
            measuredAfter = modeOne.last(where: { $0.at >= event.startTime })?.period
                ?? modeOne.last?.period
            measurementConfidence = 0.45
        }

        let correctedAfter: Double? = {
            guard let measuredAfter else { return nil }
            guard temperatureModel.isReliable,
                  let reference = baselineTemperature else { return measuredAfter }
            return temperatureModel.normalise(period: measuredAfter,
                                              measuredAt: event.structureTemperature,
                                              referenceTemperature: reference)
        }()

        if let after = correctedAfter {
            if let item = EvidenceBuilder.fromPeriodChange(
                before: baselinePeriod, after: after,
                temperatureCorrected: temperatureModel.isReliable,
                measurementConfidence: measurementConfidence) {
                evidence.append(item)
            }
        }

        // MARK: The two independent damage confirmations.

        if let item = EvidenceBuilder.fromResidualDisplacement(
            event.residualDisplacement, buildingHeight: building.height) {
            evidence.append(item)
        }
        if let item = EvidenceBuilder.fromTilt(degrees: event.tiltAngle,
                                               tripped: event.permanentTilt) {
            evidence.append(item)
        }

        // MARK: Simulated demand, from this building's own model.

        let model = ShearBuilding.from(building)
        let thresholds = DriftThresholds.forSystem(building.system, material: building.material)
        var demand = 0.0
        if let record, record.count > 32 {
            let result = StructuralSolver.run(
                model, groundAcceleration: record.dominantHorizontal,
                thresholds: thresholds,
                options: .init(allowDegradation: true, keepHistory: false))
            demand = result.maximumDrift
            evidence.append(EvidenceBuilder.fromDriftDemand(
                result.maximumDrift, storey: result.worstStorey, thresholds: thresholds))
        }

        // MARK: Fuse.

        let fragility = FragilitySet.from(thresholds, label: building.system.label)
        let prior = BayesianFusion.prior(fromDemand: demand, fragility: fragility)
        let fused = BayesianFusion.fuse(.init(prior: prior, evidence: evidence))

        var assessment = Assessment(
            buildingID: building.id,
            eventID: event.id,
            verdict: fused.verdict,
            damageProbability: fused.probability,
            confidenceInterval: fused.interval,
            confidence: fused.confidence,
            evidence: evidence,
            periodBefore: baselinePeriod,
            periodDuring: nil,
            periodAfter: measuredAfter,
            periodAfterTemperatureCorrection: correctedAfter,
            temperatureAtBaseline: baselineTemperature,
            temperatureAtMeasurement: event.structureTemperature,
            narrative: fused.reasoning,
            narrativeIsAIGenerated: false,
            assessorTier: event.isSimulated ? .unverified : .sensorVerified)

        // A record captured during a brownout cannot be trusted on its own, and
        // saying so is more useful than quietly producing a confident verdict
        // from bad data.
        if event.capturedDuringBrownout {
            assessment.verdict = .needsInspection
            assessment.narrative = "The node's supply dipped while this event was being recorded, "
                + "so the measurements may be unreliable. " + assessment.narrative
        }

        return assessment
    }

    /// Re-measures the building from ambient vibration alone, with no event.
    /// This is what "Measure now" does, and what runs nightly to build history.
    static func ambientMeasurement(building: BuildingModel,
                                   session: NodeSessionMeasuring,
                                   temperature: Double) -> ModeObservation? {
        let band = (building.empiricalPeriod * 0.35)...(building.empiricalPeriod * 3.5)
        let result = session.measurePeriod(band: band)
        guard let period = result.consensus, period > 0 else { return nil }
        return ModeObservation(modeNumber: 1, frequency: 1 / period,
                               amplitude: 1, at: Date(), temperature: temperature)
    }
}

/// Narrow protocol so the engine can be tested without a live session.
protocol NodeSessionMeasuring {
    func measurePeriod(band: ClosedRange<Double>) -> PeriodEstimation.CrossCheckedPeriod
}

extension NodeSession: NodeSessionMeasuring {
    func measurePeriod(band: ClosedRange<Double>) -> PeriodEstimation.CrossCheckedPeriod {
        measurePeriodFromAmbient(band: band)
    }

    /// The same measurement, on a channel the caller has already prepared.
    ///
    /// Exists so the overnight scheduler can cancel plant noise before the
    /// period is picked off, without that filtering having to live inside the
    /// session — which streams from a node and should not know what an adaptive
    /// filter is.
    func measurePeriod(of waveform: Waveform,
                       band: ClosedRange<Double>) -> PeriodEstimation.CrossCheckedPeriod {
        PeriodEstimation.crossChecked(waveform, band: band)
    }
}
