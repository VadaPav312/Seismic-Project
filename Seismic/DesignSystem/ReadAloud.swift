import SwiftUI

/// A speaker button that reads a specific piece of the screen.
///
/// The app already speaks during an event, when nobody can look at a phone. This
/// is the quieter case and the more common one: somebody who would rather listen
/// than read. That includes people with low vision who are not VoiceOver users,
/// people reading in a moving vehicle, and — the case this app runs into
/// constantly — anybody being handed a phone by somebody else who is trying to
/// explain what it says.
///
/// One button per block of text rather than one per screen, because "read the
/// screen" is not a useful offer on a screen with four paragraphs and a chart.
/// The button is beside the thing it will read, and it stops what it started.
struct SpeakButton: View {
    /// What to say. Resolved lazily so a caller can build an expensive sentence
    /// without paying for it on every redraw.
    let text: () -> String
    var compact = false

    @EnvironmentObject private var voice: VoiceController
    /// Whether this particular button started the speech that is running.
    ///
    /// Without it, every speaker button on the screen turns into a stop button
    /// the moment any one of them is pressed, and pressing a different one then
    /// stops the first rather than reading the second.
    @State private var isMine = false

    init(_ text: @autoclosure @escaping () -> String, compact: Bool = false) {
        self.text = text
        self.compact = compact
    }

    private var isSpeakingThis: Bool { isMine && voice.isSpeaking }

    var body: some View {
        Button {
            if isSpeakingThis {
                voice.stopSpeaking()
                isMine = false
            } else {
                voice.stopSpeaking()
                isMine = true
                // `force`, because this is an explicit request. The automatic
                // narration setting governs speech nobody asked for; a person
                // pressing a speaker button has asked.
                voice.speak(text(), urgency: .calm, force: true)
            }
            Haptics.shared.play(.selection)
        } label: {
            if compact {
                Image(systemName: isSpeakingThis ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: Theme.Metrics.minimumTapTarget,
                           height: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            } else {
                Label(isSpeakingThis ? "Stop" : "Read aloud",
                      systemImage: isSpeakingThis ? "stop.fill" : "speaker.wave.2")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, Theme.Metrics.s4)
                    .frame(height: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onChange(of: voice.isSpeaking) { _, speaking in
            if !speaking { isMine = false }
        }
        // VoiceOver reads the text itself; offering to speak it as well is
        // noise, and the button would be one more thing to swipe past.
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts a speaker button underneath a block of text, clear of it.
    ///
    /// It was an overlay, which was wrong: an overlay is drawn *on top of* what
    /// it is attached to, so the button sat over the last line of every
    /// paragraph it was added to and covered the words. Reserving a row for it
    /// costs a little vertical space and is the only arrangement that cannot
    /// hide the thing it offers to read.
    func readAloud(_ text: @autoclosure @escaping () -> String,
                   alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            self
            SpeakButton(text())
                .padding(.leading, alignment == .leading ? -Theme.Metrics.s4 : 0)
                .padding(.trailing, alignment == .trailing ? -Theme.Metrics.s4 : 0)
        }
        .frame(maxWidth: .infinity,
               alignment: alignment == .trailing ? .trailing : .leading)
    }
}
