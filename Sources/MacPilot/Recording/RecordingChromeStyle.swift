//
//  RecordingChromeStyle.swift
//  MacPilot
//
//  The visual language of the recording flow's floating surfaces: the prepare
//  bar, the in-selection settings bar, the live controller bar and the
//  countdown. They are all the same kind of object — a control strip parked on
//  top of whatever the user's screen happens to be showing — so they share one
//  set of tokens, and retuning the capsule retunes all four together.
//
//  Two things this file deliberately is not:
//
//  - It is not `CaptureChromeStyle`, which draws a *tool card* (an adaptive
//    `windowBackgroundColor` surface holding native controls) for the
//    annotation toolbar. Recording bars are dark HUD strips, not cards.
//  - It is not `PinnedScreenshotChromeStyle` either. A pin's chrome is a hover
//    affordance that belongs to a picture; these bars are permanent fixtures of
//    a session. The capsule values happen to agree because both are HUDs, and
//    that is the whole relationship — merging the files would let a retune for
//    one flow silently restyle the other, which is exactly the coupling that had
//    to be undone once already.
//
//  No surface here samples what is behind it, and none casts a shadow.
//  `glassEffect` and every `Material` need a backdrop, and these float in
//  borderless, non-activating panels where macOS 26's glass comes back as a flat
//  grey slab; a strip that is only legible over some part of the screen is not
//  legible. The shadow rule has the same shape: the pin capsule and the capture
//  toolbar can cast one because they sit inside a surface larger than they are,
//  while every host here is measured to the strip — a panel sized by
//  `panelSize(barFitting:)`, an `NSHostingView` framed at `preferredSize` — so
//  nothing reserves room for a shadow outside the capsule edge. At best it is
//  clipped away, at worst it survives on one of the three surfaces and not the
//  others. What is left is the only thing guaranteed to work everywhere: a dark
//  fill plus a light hairline. A control's own glow is a different matter, since
//  `CircleAction` falls its shadow inside the strip, where the padding is.
//

import SwiftUI

enum RecordingChromeStyle {
    // MARK: - Capsule

    /// Dark enough to hold white glyphs over a white page, translucent enough to
    /// still read as an overlay.
    static let fillOpacity: Double = 0.62
    /// The hairline is what separates a strip from a dark screenshot, where the
    /// fill alone has no contrast left to work with.
    static let strokeOpacity: Double = 0.22

    /// Horizontal padding inside a strip, between the capsule edge and the first
    /// / last control.
    static let capsulePadding: CGFloat = 8
    /// One height for all three strips, so the flow reads as a single widget
    /// vocabulary: `controlSide` plus two `capsulePadding`.
    static let stripHeight: CGFloat = controlSide + 2 * capsulePadding

    /// Room beyond a strip's own width: the mic meter or a longer localized
    /// label can widen the bar after the panel opens, and a panel sized to the
    /// bar as it was measured then clips it instead.
    static let panelWidthSlack: CGFloat = 48

    /// Window size for a bar measured at `fitting`. The panel is never exactly
    /// as wide as the bar was at the moment it opened.
    static func panelSize(barFitting fitting: NSSize) -> NSSize {
        NSSize(
            width: ceil(fitting.width) + panelWidthSlack,
            height: ceil(fitting.height)
        )
    }

    // MARK: - Controls inside a strip

    /// Hit target of one control, and the radius of the pill a selected control
    /// is drawn with.
    static let controlSide: CGFloat = 28
    static let controlCornerRadius: CGFloat = 8
    static let controlSpacing: CGFloat = 6

    /// Resting glyph, and the glyph of a control that is switched off.
    static let glyph: Color = .white
    static let glyphDimmed: Color = .white.opacity(0.42)
    /// The faint pill of a control that is engaged or simply pressable, and the
    /// inverted pill of the active choice: white with a dark label, which reads
    /// as "this one" far faster than another shade of white ever could.
    static let controlFillTinted: Color = .white.opacity(0.18)
    static let controlFillInverted: Color = .white
    static let glyphOnInvertedControl: Color = .black
    static let controlGlyphSize: CGFloat = 14

    // MARK: - Meaning colours

    /// Recording-state colours are the one place a hue carries information, so
    /// they are pinned here rather than written per call site.
    static let recordRed: Color = Color(red: 0.94, green: 0.27, blue: 0.27)
    static let startGreen: Color = Color(red: 0.30, green: 0.85, blue: 0.39)
}

extension View {
    /// The one capsule surface every recording strip is drawn into.
    func recordingHUDCapsule(height: CGFloat) -> some View {
        let shape = Capsule()
        return self
            .frame(height: height)
            .background(shape.fill(Color.black.opacity(RecordingChromeStyle.fillOpacity)))
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(RecordingChromeStyle.strokeOpacity),
                    lineWidth: 1
                )
            )
    }
}

// MARK: - Controls

extension RecordingChromeStyle {
    /// What a control looks like right now. The five states are the whole
    /// vocabulary of these strips: nothing in a recording bar is styled ad hoc
    /// beyond one of them. They are named for what they draw, not for the
    /// semantic at the call site, because the same tint serves both a switch
    /// that is on and an option that is merely pressable.
    enum ControlEmphasis {
        /// An action with no state to show — settings, dismiss.
        case resting
        /// A faint pill: a switch that is on, or an option that is not the
        /// active one but still wants to look pressable.
        case tinted
        /// A switch that is off: the glyph itself dims, so the state is readable
        /// without looking at which icon is drawn.
        case dimmed
        /// The active choice among siblings — white pill, dark label.
        case inverted
        /// Second press of the two-step cancel: discarding the recording.
        case destructive

        var glyph: Color {
            switch self {
            case .resting, .tinted, .inverted, .destructive: return RecordingChromeStyle.glyph
            case .dimmed: return RecordingChromeStyle.glyphDimmed
            }
        }

        var fill: Color {
            switch self {
            case .resting, .dimmed: return .clear
            case .tinted: return RecordingChromeStyle.controlFillTinted
            case .inverted: return RecordingChromeStyle.controlFillInverted
            case .destructive: return RecordingChromeStyle.recordRed
            }
        }

        /// `inverted` is the only state that flips the glyph dark, because it is
        /// the only one sitting on a white pill.
        var glyphOnFill: Color {
            self == .inverted ? RecordingChromeStyle.glyphOnInvertedControl : glyph
        }
    }

    /// A control inside a recording strip. Glyph labels are square
    /// `controlSide` hit targets; a text pill ("16:9", "HD") passes `width: nil`
    /// and pads its own label.
    struct ControlButtonStyle: ButtonStyle {
        let emphasis: ControlEmphasis
        var width: CGFloat? = RecordingChromeStyle.controlSide

        private var shape: RoundedRectangle {
            RoundedRectangle(
                cornerRadius: RecordingChromeStyle.controlCornerRadius,
                style: .continuous
            )
        }

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(
                    size: RecordingChromeStyle.controlGlyphSize,
                    weight: .semibold
                ))
                .foregroundStyle(emphasis.glyphOnFill)
                .frame(width: width, height: RecordingChromeStyle.controlSide)
                .background(emphasis.fill, in: shape)
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.65 : 1)
        }
    }

    /// The coloured round action at the end of a strip. A filled circle with the
    /// glyph punched out in white: the hue carries the meaning, the glyph the
    /// verb.
    struct CircleAction: View {
        let color: Color
        let systemImage: String
        var side: CGFloat = 26
        var glyphSize: CGFloat = 10
        /// Play triangles read off-centre in a circle unless nudged.
        var glyphOffset: CGSize = .zero

        var body: some View {
            ZStack {
                Circle().fill(color)
                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(glyphOffset)
            }
            .frame(width: side, height: side)
            .shadow(color: color.opacity(0.45), radius: 4, y: 1)
        }
    }
}
