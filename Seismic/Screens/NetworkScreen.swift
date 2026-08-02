import SwiftUI
import MapKit
import SeismicCore
import SeismicGeo
import SeismicSignal
import SeismicData

/// Several nodes, and what they can work out together that none can alone.
///
/// One node knows *when* the shaking reached it and can range the source from
/// the gap between the P and S waves. Three nodes know where it came from. The
/// screen is built around that difference, and — more importantly — around
/// being honest when the geometry is too poor to support the answer: three
/// sensors in a straight line produce a confident-looking dot that is wrong,
/// and the azimuthal gap is the number that gives it away.
struct NetworkScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var arrivals: [NodeArrival] = []
    @State private var solution: Triangulation.Solution?
    @State private var camera: MapCameraPosition = .automatic
    @State private var isSimulating = false

    /// Held rather than computed.
    ///
    /// RANSAC runs two hundred grid searches, and a computed property is
    /// re-evaluated on every pass through `body` — which for a screen with a
    /// live map means many times a second. Solved once when the arrivals
    /// change, which is the only time the answer can differ.
    @State private var consensus: ArrivalConsensus.Consensus?
    @State private var consensusNames: [UUID: String] = [:]
    @State private var bearing: PolarisationAnalysis.Bearing?

    /// What each station actually recorded, and what correlating those records
    /// says about its clock.
    @State private var waveforms: [String: Waveform] = [:]
    @State private var clockSkew: [(station: String, skewSeconds: Double,
                                    correlation: Double)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                if arrivals.isEmpty {
                    // The empty state already offers both simulations; showing
                    // the control block underneath it would repeat them.
                    empty
                } else {
                    map
                    solutionSection
                    consensusSection
                    clockSection
                    bearingSection
                    stationList
                    controls
                }
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        // The bearing comes from the node's own buffer, which is still filling
        // in the first seconds after launch. Measured on a task that waits for
        // it rather than once at simulation time, which is how the panel came
        // to be reliably absent on a freshly opened screen.
        .task {
            for _ in 0..<12 where bearing == nil {
                measureBearing()
                if bearing != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var empty: some View {
        DesignedEmptyState(
            icon: "point.3.connected.trianglepath.dotted",
            title: "One node, so far",
            message: "A single node can tell you how far away an earthquake was, from the delay "
                + "between the first wave and the second. Three can tell you where it was. "
                + "Add nodes on the map, or simulate a network to see how the geometry "
                + "changes the answer.",
            actionTitle: "Simulate a five-node network",
            action: { simulate(count: 5, collinear: false) },
            secondaryActionTitle: "Simulate three nodes in a line",
            secondaryAction: { simulate(count: 3, collinear: true) })
            .fillsAvailableHeight()
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(arrivals) { arrival in
                Annotation(arrival.id,
                           coordinate: CLLocationCoordinate2D(latitude: arrival.location.latitude,
                                                              longitude: arrival.location.longitude)) {
                    ZStack {
                        Circle()
                            .fill(Theme.Palette.accent.opacity(0.25))
                            .frame(width: 26, height: 26)
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }

            if let solution {
                Annotation("Epicentre",
                           coordinate: CLLocationCoordinate2D(
                            latitude: solution.epicentre.latitude,
                            longitude: solution.epicentre.longitude)) {
                    ZStack {
                        Circle()
                            .strokeBorder(Theme.Palette.verdictAmber, lineWidth: 2)
                            .frame(width: 28, height: 28)
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.verdictAmber)
                    }
                }

                // The uncertainty is drawn, not just quoted. A 40 km circle
                // around a dot says something a number beside it does not.
                MapCircle(center: CLLocationCoordinate2D(
                    latitude: solution.epicentre.latitude,
                    longitude: solution.epicentre.longitude),
                          radius: solution.horizontalUncertaintyKm * 1000)
                    .foregroundStyle(Theme.Palette.verdictAmber.opacity(0.12))
                    .stroke(Theme.Palette.verdictAmber.opacity(0.5), lineWidth: 1)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var solutionSection: some View {
        if let solution {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Epicentre", systemImage: "scope",
                             trailing: solution.isWellConstrained ? "Well constrained" : "Weak")

                ReadoutGrid(readouts: [
                    Readout(label: "Latitude",
                            value: String(format: "%.4f", solution.epicentre.latitude), unit: "°"),
                    Readout(label: "Longitude",
                            value: String(format: "%.4f", solution.epicentre.longitude), unit: "°"),
                    Readout(label: "Uncertainty",
                            value: String(format: "%.0f", solution.horizontalUncertaintyKm),
                            unit: "km",
                            tint: solution.horizontalUncertaintyKm > 30
                                ? Theme.Palette.verdictAmber : Theme.Palette.textPrimary),
                    Readout(label: "Fit residual",
                            value: String(format: "%.2f", solution.rmsResidualSeconds), unit: "s",
                            caption: "how well one source explains every arrival"),
                ])

                let gap = Triangulation.azimuthalGap(from: solution.epicentre,
                                                     to: arrivals.map(\.location))
                Readout(label: "Azimuthal gap", value: String(format: "%.0f", gap), unit: "°",
                        tint: gap > 270 ? Theme.Palette.verdictRed
                            : (gap > 180 ? Theme.Palette.verdictAmber : Theme.Palette.verdictGreen),
                        caption: gap > 270
                            ? "The sensors are all on one side. The position along the line of "
                              + "sight is essentially a guess."
                            : "Under 180° means the sensors surround the source.")

                Text(solution.explanation)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    // MARK: Clocks

    /// What the waveforms say about the clocks, as opposed to what the clocks
    /// say about themselves.
    ///
    /// The reason this matters got much larger when the app started accepting
    /// phones as sensors. A wired node's clock is disciplined; a phone's is
    /// synchronised over the network to somewhere between ten and a hundred
    /// milliseconds, and at six kilometres a second a hundred milliseconds is
    /// six hundred metres of epicentre. The timing error is bigger than the
    /// measurement.
    ///
    /// Two stations that felt the same earthquake give a way out that needs no
    /// clock at all: the lag that maximises the correlation between their
    /// records is the true travel-time difference, and the gap between that and
    /// what the timestamps claim is the skew. Parabolic interpolation around
    /// the correlation peak resolves it to about a millisecond, which is a
    /// hundredth of what the timestamps manage.
    @ViewBuilder
    private var clockSection: some View {
        if !clockSkew.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Clock check", systemImage: "clock.badge.exclamationmark",
                             trailing: "from the waveforms")

                ForEach(clockSkew, id: \.station) { entry in
                    HStack {
                        Text(entry.station)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        if entry.correlation < 0.5 {
                            Text("did not correlate")
                                .font(Theme.Typography.numericSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        } else {
                            Text(String(format: "%+.0f ms", entry.skewSeconds * 1000))
                                .font(Theme.Typography.numeric)
                                .foregroundStyle(abs(entry.skewSeconds) > 0.05
                                                 ? Theme.Palette.verdictAmber
                                                 : Theme.Palette.textSecondary)
                            Text(String(format: "· %.0f m",
                                        abs(entry.skewSeconds) * EpicentralDistance.vP * 1000))
                                .font(Theme.Typography.numericSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }

                Text("Each station's record is cross-correlated against the first station's. "
                     + "The lag that maximises the correlation is the true delay between them; "
                     + "the difference from what their timestamps claim is clock skew, and the "
                     + "metres beside it are how much epicentre error that skew buys. "
                     + "Recovered to about a millisecond by fitting a parabola through the "
                     + "correlation peak — the sample interval alone would only give ten.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    /// Correlates every station against the first and records what it finds.
    private func checkClocks() {
        guard let reference = arrivals.first,
              let referenceWave = waveforms[reference.id], arrivals.count > 1 else {
            clockSkew = []
            return
        }

        clockSkew = arrivals.dropFirst().compactMap { arrival in
            guard let wave = waveforms[arrival.id],
                  let alignment = TimeAlignment.align(referenceWave, wave,
                                                      maximumLag: 4.0) else { return nil }
            // What the timestamps claim the delay is.
            let claimed = arrival.pArrivalTime.timeIntervalSince(reference.pArrivalTime)
            // Correlation lag is positive when the second record lags the
            // first, which is the same sign convention the timestamps use.
            return (station: arrival.id,
                    skewSeconds: alignment.lagSeconds - claimed,
                    correlation: alignment.correlation)
        }
    }

    // MARK: Consensus

    /// The same arrivals, solved again with outlier rejection.
    ///
    /// A wired array of nodes is trustworthy; a crowd of phones is not. One in
    /// a moving car, one being picked up as the shaking starts, one whose clock
    /// has not synchronised for a week — each contributes an arrival time that
    /// is not an arrival time, and least squares accommodates it rather than
    /// rejecting it, because a station wrong by two seconds contributes four
    /// hundred times more to the objective than one wrong by a tenth.
    ///
    /// Shown next to the plain solution rather than replacing it, so the size
    /// of the difference is visible instead of asserted.
    @ViewBuilder
    private var consensusSection: some View {
        if let consensus {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Consensus", systemImage: "person.3.sequence",
                             trailing: "\(consensus.inliers.count) of \(arrivals.count) agree")

                ReadoutGrid(readouts: [
                    Readout(label: "Latitude",
                            value: String(format: "%.4f", consensus.latitude), unit: "°",
                            size: .small),
                    Readout(label: "Longitude",
                            value: String(format: "%.4f", consensus.longitude), unit: "°",
                            size: .small),
                    Readout(label: "Inlier residual",
                            value: String(format: "%.2f", consensus.residualRMS), unit: "s",
                            size: .small),
                    Readout(label: "Azimuthal gap",
                            value: String(format: "%.0f", consensus.azimuthalGap), unit: "°",
                            tint: consensus.isGeometricallySound
                                ? Theme.Palette.verdictGreen : Theme.Palette.verdictAmber,
                            size: .small),
                ], columns: 2)

                if consensus.outliers.isEmpty {
                    Text("Every station agrees with the same source to within half a second, "
                         + "so nothing was rejected. Repeatedly fitting three at random and "
                         + "counting how many of the rest agree is what establishes that — it "
                         + "is not the same as a good overall residual, which one bad station "
                         + "can produce by dragging the answer towards itself.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    InlineNotice(
                        level: .warning,
                        title: consensus.outliers.count == 1
                            ? "One station was excluded" : "\(consensus.outliers.count) stations were excluded",
                        message: "They do not agree with any source the others are consistent "
                            + "with. A least-squares fit would have moved the epicentre "
                            + "towards them instead of leaving them out — which is why this "
                            + "answer and the one above differ by "
                            + String(format: "%.1f km.", consensusDisagreementKm))
                }

                ForEach(consensus.outliers) { outlier in
                    outlierRow(outlier, in: consensus)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    /// One rejected station, and by how much it disagreed.
    private func outlierRow(_ outlier: ArrivalConsensus.Observation,
                            in consensus: ArrivalConsensus.Consensus) -> some View {
        let residual = ArrivalConsensus.residual(
            outlier,
            at: (lat: consensus.latitude, lon: consensus.longitude,
                 time: consensus.originTime),
            waveSpeed: EpicentralDistance.vP)

        return HStack {
            Image(systemName: "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.verdictAmber)
            Text(stationName(for: outlier))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(String(format: "%.2f s off", abs(residual)))
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    /// How far apart the plain and robust solutions are.
    private var consensusDisagreementKm: Double {
        guard let consensus, let solution else { return 0 }
        return Geodesy.distanceKm(
            solution.epicentre,
            GeoPoint(latitude: consensus.latitude, longitude: consensus.longitude))
    }

    /// Re-solves with outlier rejection. Called when the arrivals change.
    private func solveConsensus() {
        guard arrivals.count >= 4, let reference = arrivals.map(\.pArrivalTime).min() else {
            consensus = nil
            consensusNames = [:]
            return
        }
        var names: [UUID: String] = [:]
        let observations = arrivals.map { arrival -> ArrivalConsensus.Observation in
            let observation = ArrivalConsensus.Observation(
                latitude: arrival.location.latitude,
                longitude: arrival.location.longitude,
                arrivalTime: arrival.pArrivalTime.timeIntervalSince(reference))
            names[observation.id] = arrival.id
            return observation
        }
        consensusNames = names
        consensus = ArrivalConsensus.locate(observations, waveSpeed: EpicentralDistance.vP,
                                            tolerance: 0.4)
    }

    private func stationName(for observation: ArrivalConsensus.Observation) -> String {
        consensusNames[observation.id] ?? "Unknown station"
    }

    // MARK: Single-station bearing

    /// A direction to the source from one sensor, with no network at all.
    ///
    /// The thing a crowd version of this app needs most, because most phones
    /// will never be part of a network — they will be the only sensor in their
    /// building. A P wave compresses the ground *along* its direction of
    /// travel, so for a few tenths of a second after it arrives the motion is
    /// confined to a line, and that line points at the source.
    @ViewBuilder
    private var bearingSection: some View {
        if let bearing {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Bearing from this sensor alone", systemImage: "location.north.line",
                             trailing: bearing.isReliable ? nil : "Unreliable")

                ReadoutGrid(readouts: [
                    Readout(label: "Back-azimuth",
                            value: String(format: "%.0f", bearing.backAzimuth), unit: "°",
                            tint: bearing.isReliable ? Theme.Palette.accent
                                                     : Theme.Palette.textSecondary,
                            size: .large,
                            caption: bearing.compassPoint),
                    Readout(label: "Rectilinearity",
                            value: String(format: "%.2f", bearing.rectilinearity),
                            size: .large,
                            caption: "how confined to one line the motion was"),
                ], columns: 2)

                Text(bearing.isReliable
                     ? "The motion in the first half-second was strongly polarised along one "
                       + "line, which is what a P wave does — it compresses the ground along "
                       + "its direction of travel. The covariance matrix of the three channels "
                       + "over that window has one dominant eigenvector, and it points back "
                       + "towards the source."
                     : "The motion was not confined enough to a line for the direction to mean "
                       + "anything. That is the honest answer for an S wave, for a nearby door "
                       + "slamming, or for a window that caught the coda rather than the onset.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if bearing.isAmbiguous {
                    Text("The vertical first motion was too weak to tell the two ends of the "
                         + "line apart, so the true bearing may be "
                         + String(format: "%.0f°", (bearing.backAzimuth + 180)
                                  .truncatingRemainder(dividingBy: 360))
                         + " instead.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.verdictAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    private func measureBearing() {
        let record = env.session.bufferedRecord()
        guard record.count > 512 else { bearing = nil; return }
        // From the P pick where there is one, and from the start of the buffer
        // otherwise — an ambient buffer has no arrival in it, and the bearing
        // is then honestly reported as unreliable rather than withheld.
        let from = ArrivalPicker.pickP(record.z)?.time ?? 0
        bearing = PolarisationAnalysis.analyse(record, from: from, windowSeconds: 0.5)
    }

    private var stationList: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Arrivals", systemImage: "clock", trailing: "\(arrivals.count) nodes")

            ForEach(arrivals) { arrival in
                HStack {
                    Text(arrival.id)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if let solution {
                        let distance = Geodesy.distanceKm(arrival.location, solution.epicentre)
                        Text(String(format: "%.0f km", distance))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(arrival.pArrivalTime.formatted(date: .omitted, time: .standard))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            Text("Each node timestamps the first arrival against a clock synchronised with the "
                 + "phone. A tenth of a second of clock error moves the answer by about "
                 + "600 metres, which is why the residual matters more than any single arrival.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var controls: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                simulate(count: 5, collinear: false)
            } label: {
                Label("Simulate a well-spread network", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                simulate(count: 3, collinear: true)
            } label: {
                Label("Simulate three nodes in a line", systemImage: "line.diagonal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

            if !arrivals.isEmpty {
                Button("Clear") {
                    arrivals = []; solution = nil; consensus = nil
                    consensusNames = [:]; waveforms = [:]; clockSkew = []
                }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    // MARK: Simulation

    /// Places nodes around the selected building and computes what each would
    /// have recorded for a source 40 km away, then solves for the source from
    /// those arrivals alone. The collinear case exists to demonstrate the
    /// failure honestly rather than only ever showing the flattering geometry.
    private func simulate(count: Int, collinear: Bool) {
        let centre = env.selectedBuilding.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
        } ?? GeoPoint(latitude: 37.7749, longitude: -122.4194)

        // 40 km out on a north-westerly bearing.
        let source = Geodesy.destination(from: centre, distanceMetres: 40_000, bearingDegrees: 315)
        let originTime = Date()

        var generated: [NodeArrival] = []
        var waves: [String: Waveform] = [:]
        for index in 0..<count {
            // Collinear: strung out along one bearing, which is the geometry
            // that produces a confident-looking answer in the wrong place.
            // Otherwise: evenly around the building, which is the good case.
            let location: GeoPoint = collinear
                ? Geodesy.destination(from: centre,
                                      distanceMetres: Double(index) * 12_000 + 4_000,
                                      bearingDegrees: 45)
                : Geodesy.destination(from: centre, distanceMetres: 14_000,
                                      bearingDegrees: 360 * Double(index) / Double(count))

            let distance = Geodesy.distanceKm(location, source)
            let travel = distance / EpicentralDistance.vP
            // A tenth of a second of timing scatter, which is roughly what a
            // real node's clock synchronisation achieves.
            var noise = SeededRandom(seed: UInt64(index) &+ 991)
            let jitter = noise.gaussian() * 0.1

            let name = "Node \(index + 1)"
            generated.append(NodeArrival(
                id: name,
                location: location,
                pArrivalTime: originTime.addingTimeInterval(travel + jitter)))

            // And what that station actually recorded, so the clocks can be
            // checked against the waveforms rather than against each other.
            //
            // One station is given a deliberate clock error. Not to flatter the
            // algorithm — the point is that the timestamp and the waveform then
            // disagree, which is exactly the situation a crowd of phones
            // produces routinely and which nothing else on this screen can see.
            let deliberateSkew = index == 2 ? 0.35 : 0.0
            waves[name] = Self.stationRecording(delay: travel + jitter - deliberateSkew,
                                                seed: UInt64(index) &+ 5_000)
        }

        arrivals = generated
        waveforms = waves
        solution = Triangulation.locate(generated)
        solveConsensus()
        checkClocks()
        measureBearing()
        if let solution {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: solution.epicentre.latitude,
                                               longitude: solution.epicentre.longitude),
                span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)))
        }
        Haptics.shared.play(.assessmentComplete)
    }

    /// One station's record of the same event: a shared wavelet, delayed, with
    /// that station's own independent noise on top.
    ///
    /// The wavelet has to be *shared* and the noise *independent*, because that
    /// is the physical situation — every station saw the same source through a
    /// different path — and it is what makes correlation the right tool. Give
    /// them independent signals and nothing correlates; give them identical
    /// noise and everything does, for the wrong reason.
    private static func stationRecording(delay: TimeInterval, seed: UInt64) -> Waveform {
        let rate = 100.0
        let count = Int(rate * 30)
        let onset = Int(delay * rate)
        var rng = SeededRandom(seed: seed)

        var samples = (0..<count).map { _ in rng.gaussian(sd: 0.02) }
        for i in 0..<count where i >= onset {
            let t = Double(i - onset) / rate
            samples[i] += exp(-t * 0.8) * sin(2 * Double.pi * 3.5 * t)
        }
        return Waveform(samples: samples, sampleRate: rate)
    }
}

#Preview {
    NavigationStack {
        NetworkScreen()
            .seismicBackground()
            .navigationTitle("Network")
    }
    .previewEnvironment()
}
