import ParleyCore
import SwiftUI

struct RuntimeBanner: View {
    let runtime: ParleyRuntime

    @ViewBuilder
    var body: some View {
        if let marker = runtime.visibleMarker {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 18)
                    .accessibilityHidden(true)
                Text(marker)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                Text("Isolated data, embedded panes and coordination core")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(marker)
        }
    }
}
