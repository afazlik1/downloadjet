import SwiftUI
import DownloadCore

struct SpeedHistoryView: View {
    let samples: [DownloadSpeedSample]
    let speed: Double

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("LIVE SPEED").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(bytes(Int64(speed)) + "/s").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.blue)
            }
            Canvas { context, size in
                let bottom = size.height - 1
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    let y = 1 + (bottom - 1) * fraction
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)
                guard let end = samples.last?.time else { return }
                let maximum = max(1024, (samples.map(\.bytesPerSecond).max() ?? 0) * 1.1)
                let points = samples.map { sample in
                    CGPoint(x: min(size.width, max(0, (sample.time - end + DownloadSpeedHistory.duration) / DownloadSpeedHistory.duration * size.width)),
                            y: bottom - min(1, max(0, sample.bytesPerSecond / maximum)) * (bottom - 2))
                }
                guard let first = points.first, let last = points.last else { return }
                var line = Path(); line.move(to: first)
                for point in points.dropFirst() { line.addLine(to: point) }
                var fill = line
                fill.addLine(to: CGPoint(x: last.x, y: bottom))
                fill.addLine(to: CGPoint(x: first.x, y: bottom)); fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [.blue.opacity(0.3), .blue.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: bottom)))
                context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }.frame(height: 38).accessibilityHidden(true)
            HStack {
                Text("30s ago"); Spacer(); Text("Now")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .help("Combined download speed over the last 30 seconds. Updates five times per second and includes retry traffic.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live download speed, last 30 seconds")
        .accessibilityValue(bytes(Int64(speed)) + " per second")
    }
}
