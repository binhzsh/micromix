import SwiftUI

/// Faint horizontal scanline overlay for the dark screen panel, giving the
/// recessed-dot-matrix CRT feel described in the spec.
struct ScanlinesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let spacing: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    let line = CGRect(x: 0, y: y, width: size.width, height: 1)
                    context.fill(Path(line), with: .color(Color.black.opacity(0.18)))
                    y += spacing
                }
            }
        }
        .allowsHitTesting(false)
    }
}
