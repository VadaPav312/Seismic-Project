import SwiftUI

/// What sits behind everything.
///
/// A flat dark fill gives translucent surfaces nothing to pick up — every card
/// ends up the same grey, and the glass reads as paint. Three very large, very
/// blurred pools of colour drifting slowly behind the interface fix that: each
/// panel now samples a slightly different tint depending on where it sits, and
/// the whole app feels like a place rather than a screen.
///
/// It has to be cheap, because it is on screen for the entire life of the app.
/// So: three circles, no per-frame work of our own, and the motion is a single
/// repeating animation the render server owns rather than anything driven from
/// a timer.
struct AmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        ZStack {
            // The base. Slightly lighter towards the top, because the light in
            // this interface comes from above and the background should agree
            // with the cards about that.
            LinearGradient(
                colors: [Theme.Palette.backgroundRaised, Theme.Palette.background],
                startPoint: .top, endPoint: .bottom)

            GeometryReader { proxy in
                let size = max(proxy.size.width, proxy.size.height)

                orb(Theme.Palette.accent, diameter: size * 1.05)
                    .offset(x: drifting ? -size * 0.28 : -size * 0.16,
                            y: drifting ? -size * 0.34 : -size * 0.22)

                orb(Theme.Palette.accentSecondary, diameter: size * 0.9)
                    .offset(x: drifting ? size * 0.34 : size * 0.20,
                            y: drifting ? size * 0.10 : size * 0.28)

                // Deliberately not the verdict green, tempting though it is as
                // a third hue. Green, amber and red are reserved for structural
                // verdicts and nothing else — a wash of green behind the
                // interface is exactly the kind of thing that erodes that, and
                // the rule is only worth having if it holds for decoration too.
                orb(Theme.Palette.accent.opacity(0.7), diameter: size * 0.75)
                    .offset(x: drifting ? size * 0.06 : -size * 0.10,
                            y: drifting ? size * 0.52 : size * 0.66)
            }
            // Screen blending keeps the orbs additive, so they lighten the
            // background rather than muddying it the way normal blending would.
            .allowsHitTesting(false)
            // Rendered once into a single layer rather than composited live.
            //
            // Three large translucent circles over a gradient is three
            // full-screen blend passes every frame, and they sit behind the
            // entire app — so every scroll paid for them. `drawingGroup`
            // flattens the lot into one texture that only re-renders when the
            // drift animation actually moves it.
            .compositingGroup()
            .drawingGroup()
        }
        .onAppear {
            // Reduce Motion gets the colour without the drift. The tint is the
            // point; the movement is decoration.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 44).repeatForever(autoreverses: true)) {
                drifting = true
            }
        }
    }

    private func orb(_ colour: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [colour.opacity(0.28), colour.opacity(0.0)],
                    center: .center, startRadius: 0, endRadius: diameter / 2)
            )
            .frame(width: diameter, height: diameter)
            // No blur. A Gaussian blur on a view this large is genuinely
            // expensive, and a radial gradient with a transparent outer stop is
            // already a perfectly smooth falloff — the blur was smoothing
            // something that had no edges to begin with.
    }
}

#Preview {
    ZStack {
        AmbientBackground().ignoresSafeArea()
        VStack(spacing: 16) {
            Text("Glass over ambient")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Each card picks up whatever colour is behind it.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .instrumentPanel()
        .padding()
    }
}
