import SwiftUI

/// Liquid Glass — the material every piece of chrome in this app is made of.
///
/// Two implementations of one idea, picked at runtime:
///
/// 1. On iOS 26 the system draws it properly. `glassEffect` refracts what is
///    actually behind the surface, runs a specular edge that tracks the light,
///    and lenses as the shape moves. It is the same GPU path the system's own
///    controls take, so it costs a fraction of what an equivalent hand-built
///    stack of blurs and gradients would.
/// 2. Below iOS 26 there is no such API, so the look is assembled by hand: a
///    material, a vertical wash that is brightest at the top, a one-pixel
///    gradient rim bright at the top-left and dim at the bottom-right, and a
///    long soft shadow. It is a good likeness, and it is what this app shipped
///    with before.
///
/// The single rule that governs both: **the light comes from above.** Every
/// gradient here agrees with `AmbientBackground` and `InstrumentPanel` about
/// that, which is most of why a screen of these reads as one surface rather
/// than as a pile of translucent rectangles.
enum LiquidGlass {

    /// Whether the system can draw real Liquid Glass, as opposed to the
    /// hand-built likeness.
    ///
    /// Exposed so a caller can *choose differently*, not merely draw
    /// differently — the navigation bloom, for instance, only asks for a
    /// morphing glass container when there is a system to morph it.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

// MARK: - The surface

/// A pane of liquid glass behind whatever it is applied to.
///
/// The caller supplies the shape and its own padding; this only supplies the
/// material. That split matters — a capsule dock, a rounded bloom tile and a
/// circular orb are the same substance at three radii, and baking a radius in
/// here would have produced three near-identical modifiers instead.
struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    /// A colour the glass carries in it. Nil is plain glass, which is the right
    /// answer for anything that is not the current selection — a tinted
    /// surface reads as *active*, and if everything is tinted nothing is.
    var tint: Color?
    /// Whether the surface should deform under a finger. Only for things that
    /// are actually pressable; on a decorative panel it reads as a glitch.
    var isInteractive: Bool = false
    /// The grounding shadow. Off for a surface sitting inside another glass
    /// container, where a second shadow only muddies the first.
    var isLifted: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(systemGlass, in: shape)
                .shadow(color: .black.opacity(isLifted ? 0.42 : 0),
                        radius: isLifted ? 26 : 0, y: isLifted ? 14 : 0)
        } else {
            content
                .background(handBuiltGlass)
                .overlay(shape.strokeBorder(Theme.Palette.rim, lineWidth: 1))
                .shadow(color: .black.opacity(isLifted ? 0.45 : 0),
                        radius: isLifted ? 24 : 0, y: isLifted ? 12 : 0)
        }
    }

    @available(iOS 26.0, *)
    private var systemGlass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }

    /// The pre-26 likeness. Three layers, each doing one job: the material is
    /// the blur, the wash is the light from above, and the tint — when there is
    /// one — sits between them so it colours the surface rather than painting
    /// over it.
    private var handBuiltGlass: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(tint.map { shape.fill($0.opacity(0.28)) })
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14),
                                 Color.white.opacity(0.03),
                                 Color.white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom))
            )
    }
}

extension View {
    /// Renders this view on liquid glass.
    ///
    /// - Parameters:
    ///   - shape: the pane's outline. Supply the same one you padded for.
    ///   - tint: a colour carried *in* the glass; nil for plain.
    ///   - interactive: whether it should deform under a finger.
    ///   - lifted: whether it casts a grounding shadow.
    func liquidGlass<S: InsettableShape>(in shape: S,
                               tint: Color? = nil,
                               interactive: Bool = false,
                               lifted: Bool = true) -> some View {
        modifier(LiquidGlassSurface(shape: shape, tint: tint,
                                    isInteractive: interactive, isLifted: lifted))
    }
}

// MARK: - Grouping

/// Wraps content so neighbouring glass surfaces inside it blend into one
/// another as they move, instead of overlapping like two sheets of acetate.
///
/// This is what makes the navigation bloom read as one substance flowing out of
/// the orb rather than as nine separate tiles appearing. Below iOS 26 there is
/// nothing to blend, so it passes the content straight through — which is
/// correct, not a degradation: the hand-built glass has no live refraction for
/// neighbours to share in the first place.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 24
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Press feedback

/// The give a glass control has under a finger.
///
/// On iOS 26 `Glass.interactive()` already does the deformation, so this only
/// adds the scale that sells the press as a press; below it, the scale is doing
/// all of the work. Either way the curve is the house press spring, so a tab, a
/// bloom tile and a button all feel like the same object.
struct LiquidPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
