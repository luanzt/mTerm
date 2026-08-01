import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            typography
                .tabItem { Label("Typography", systemImage: "textformat") }
            ansiColors
                .tabItem { Label("ANSI Colors", systemImage: "paintpalette") }
        }
        .padding(20)
        .frame(width: 540, height: 560)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Terminal Behavior")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Open new terminals in")
                    Picker("Open new terminals in", selection: $settings.newTerminalPlacement) {
                        ForEach(NewTerminalPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            Text("Explicit split commands, including ⇧⌘N and ⇧⌘T, always open a split.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(8)
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Terminal")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Font family")
                    Picker("Font family", selection: $settings.terminalFontName) {
                        ForEach(TerminalFontCatalog.choices) { choice in
                            Text(choice.familyName).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }

                GridRow {
                    Text("Pane content size")
                    Stepper(
                        "\(Int(settings.terminalFontSize)) pt",
                        value: $settings.terminalFontSize,
                        in: AppSettings.terminalFontSizeRange,
                        step: 1)
                        .frame(width: 170, alignment: .leading)
                }

                GridRow {
                    Text("Sidebar text size")
                    Stepper(
                        "\(Int(settings.sidebarFontSize)) pt",
                        value: $settings.sidebarFontSize,
                        in: AppSettings.sidebarFontSizeRange,
                        step: 1)
                        .frame(width: 170, alignment: .leading)
                }

                GridRow {
                    Text("Sidebar width")
                    Stepper(
                        "\(Int(settings.sidebarWidth)) pt",
                        value: $settings.sidebarWidth,
                        in: AppSettings.sidebarWidthRange,
                        step: 10)
                        .frame(width: 170, alignment: .leading)
                }
            }

            Divider()

            HStack {
                Text("Changes apply immediately to every terminal pane.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Typography") {
                    settings.resetTypography()
                }
            }

            Spacer()
        }
        .padding(8)
    }

    private var ansiColors: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ANSI Palette")
                .font(.headline)
            Text("Normal colors are on the left; bright variants are on the right.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(Self.ansiEntries) { entry in
                    ColorPicker(
                        entry.name,
                        selection: ansiBinding(at: entry.index),
                        supportsOpacity: false)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            HStack {
                Text("Colors update live without restarting shell processes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset ANSI Colors") {
                    settings.resetANSIColors()
                }
            }
            .padding(.top, 4)
        }
        .padding(8)
    }

    private func ansiBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: settings.ansiColors[index]) },
            set: { settings.setANSIColor(Self.rgbHex(from: $0), at: index) })
    }

    private static func rgbHex(from color: Color) -> UInt32 {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        let red = UInt32((converted.redComponent * 255).rounded())
        let green = UInt32((converted.greenComponent * 255).rounded())
        let blue = UInt32((converted.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    private struct ANSIEntry: Identifiable {
        let index: Int
        let name: String
        var id: Int { index }
    }

    private static let ansiEntries = [
        ANSIEntry(index: 0, name: "Black"),
        ANSIEntry(index: 8, name: "Bright Black"),
        ANSIEntry(index: 1, name: "Red"),
        ANSIEntry(index: 9, name: "Bright Red"),
        ANSIEntry(index: 2, name: "Green"),
        ANSIEntry(index: 10, name: "Bright Green"),
        ANSIEntry(index: 3, name: "Yellow"),
        ANSIEntry(index: 11, name: "Bright Yellow"),
        ANSIEntry(index: 4, name: "Blue"),
        ANSIEntry(index: 12, name: "Bright Blue"),
        ANSIEntry(index: 5, name: "Magenta"),
        ANSIEntry(index: 13, name: "Bright Magenta"),
        ANSIEntry(index: 6, name: "Cyan"),
        ANSIEntry(index: 14, name: "Bright Cyan"),
        ANSIEntry(index: 7, name: "White"),
        ANSIEntry(index: 15, name: "Bright White"),
    ]
}
