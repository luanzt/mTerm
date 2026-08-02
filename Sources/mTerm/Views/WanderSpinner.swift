import SwiftUI

/// A SwiftUI port of the "Wander" spinner from react-native-animated-spinkit:
/// three squares, each tracing an L-shaped loop, offset 90° apart so they
/// appear to chase one another around the frame.
struct WanderSpinner: View {
    var size: CGFloat = 16
    var color: Color = MTermTheme.accent

    private static let phases = Array(0...4)

    var body: some View {
        PhaseAnimator(Self.phases) { phase in
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    WanderDot(size: size, color: color, index: index, phase: phase)
                }
            }
            .frame(width: size, height: size)
        } animation: { _ in
            .linear(duration: 0.5)
        }
    }
}

private struct WanderDot: View {
    let size: CGFloat
    let color: Color
    let index: Int
    let phase: Int

    // Keyframes at 0/25/50/75/100%, matching the original: translate along
    // one edge, then the next, scale pulses out of phase between dots, and
    // the dot spins a full turn over the loop.
    private static let translateXFraction: [CGFloat] = [0, 1, 1, 0, 0]
    private static let translateYFraction: [CGFloat] = [0, 0, 1, 1, 0]
    private static let scaleEven: [CGFloat] = [1, 0.6, 1, 0.6, 1]
    private static let scaleOdd: [CGFloat] = [0.6, 1, 0.6, 1, 0.6]
    private static let rotationDegrees: [Double] = [0, -90, -180, -270, -360]

    var body: some View {
        let distance = size * 0.75
        let dotSize = size / 5 + 1
        let scale = index % 2 == 0 ? Self.scaleEven[phase] : Self.scaleOdd[phase]

        Rectangle()
            .fill(color)
            .frame(width: dotSize, height: dotSize)
            .rotationEffect(.degrees(Self.rotationDegrees[phase]))
            .scaleEffect(scale)
            .offset(
                x: Self.translateXFraction[phase] * distance,
                y: Self.translateYFraction[phase] * distance)
            .frame(width: size, height: size, alignment: .topLeading)
            .rotationEffect(.degrees(Double(index) * 90))
    }
}
