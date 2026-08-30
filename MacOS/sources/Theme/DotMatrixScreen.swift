import SwiftUI

/// Dot-matrix-flavored screen readout panel.
///
/// Renders a title, a mono status line, and a large elapsed-time readout on
/// the dark screen background. Screen text is white by default; pass a
/// distinct color (e.g. `Palette.matrixGreen`) for function readouts.
struct DotMatrixScreen: View {
    let title: String
    let statusLine: String
    let readout: String
    var readoutColor: Color = Palette.screenText

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Typography.monoLabel(title, size: 11)
                    .foregroundColor(Palette.screenText.opacity(0.7))
                Spacer()
            }
            .padding(.bottom, 8)

            Spacer()

            Text(readout)
                .font(Typography.monoReadout(size: 48))
                .foregroundColor(readoutColor)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Text(statusLine)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Palette.screenText.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Palette.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
