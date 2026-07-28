import SwiftUI
import MapKit
import SeismicCore
import SeismicGeo
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                if arrivals.isEmpty {
                    empty
                } else {
                    map
                    solutionSection
                    stationList
                }
                controls
            }
            .padding(Theme.Metrics.screenPadding)
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
                Button("Clear") { arrivals = []; solution = nil }
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

            generated.append(NodeArrival(
                id: "Node \(index + 1)",
                location: location,
                pArrivalTime: originTime.addingTimeInterval(travel + jitter)))
        }

        arrivals = generated
        solution = Triangulation.locate(generated)
        if let solution {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: solution.epicentre.latitude,
                                               longitude: solution.epicentre.longitude),
                span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)))
        }
        Haptics.shared.play(.assessmentComplete)
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
