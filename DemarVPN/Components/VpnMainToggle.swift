import SwiftUI

struct VpnMainToggle: View {
    let state: VpnConnectionState
    let hasError: Bool
    let onTap: (() -> Void)?

    private var compact: Bool { state.isConnected || state == .disconnecting }
    private var busy: Bool { state == .connecting || state == .disconnecting }

    private var fill: Color {
        if compact { return .demarPrimaryContainer }
        if hasError { return .demarErrorContainer }
        return .demarSurfaceContainerHighest
    }

    private var iconColor: Color {
        if compact { return .demarOnPrimaryContainer }
        if hasError { return .demarOnErrorContainer }
        return .demarOnSurfaceVariant
    }

    var body: some View {
        let diameter: CGFloat = compact ? 116 : 200
        let iconSize: CGFloat = compact ? 44 : 92

        VStack(spacing: 0) {
            Button(action: { onTap?() }) {
                Circle()
                    .fill(fill)
                    .frame(width: diameter, height: diameter)
                    .overlay { indicator(iconSize: iconSize) }
            }
            .buttonStyle(VpnCircleButtonStyle())
            .disabled(onTap == nil)

            if state.isConnected {
                Text("Подключено")
                    .font(.demarTitleMediumBold)
                    .foregroundStyle(Color.demarPrimary)
                    .padding(.top, 14)
            }
        }
        .animation(.easeOut(duration: 0.32), value: compact)
        .animation(.easeOut(duration: 0.32), value: state.isConnected)
    }

    @ViewBuilder
    private func indicator(iconSize: CGFloat) -> some View {
        if busy {
            SpinningRefreshIcon(color: iconColor)
        } else if state.isConnected {
            Image(systemName: "shield.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(iconColor)
        } else {
            Image(systemName: "power")
                .font(.system(size: iconSize))
                .foregroundStyle(iconColor)
        }
    }
}

private struct SpinningRefreshIcon: View {
    let color: Color
    private let size: CGFloat = 46
    private let lineWidth: CGFloat = 3.5

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.75)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size - lineWidth, height: size - lineWidth)
            .rotationEffect(.degrees(rotation))
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct VpnCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    Circle().fill(Color.demarPrimary.opacity(0.10))
                }
            }
    }
}
