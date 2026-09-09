import Foundation
import SwiftTUI

/// A one-line terminal prompt mark with a readable, native-color wordmark.
struct LowlightLogo: View {
    @Environment(\.terminalAppearance) private var terminalAppearance
    private var palette: LowlightPalette { LowlightPalette(appearance: terminalAppearance) }

    private var usesASCII: Bool {
        let value = ProcessInfo.processInfo.environment["SWIFTTUI_ASCII"] ?? "0"
        return CommandLine.arguments.contains("--ascii") || (!value.isEmpty && value != "0")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Text(usesASCII ? ">_" : "›_").bold().foregroundStyle(palette.brand)
            Text("lowlight").bold().foregroundStyle(.primary)
        }
    }
}
