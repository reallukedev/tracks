import SwiftUI
import CoreImage
import WidgetKit

/// A cover's overall colour, for a widget background that carries on from the artwork the
/// way Music's widgets do.
struct CoverColor: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Light text reads on it. WCAG's relative luminance, with the midpoint nudged down so
    /// mid-tones get white text, as Music's do.
    var isDark: Bool {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) < 0.36
    }

    /// The average of the whole cover, or nil when the data isn't an image.
    ///
    /// One Core Image reduction to a single pixel: a few milliseconds, once per timeline.
    init?(artwork: Data) {
        guard let image = CIImage(data: artwork), !image.extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: image.extent),
              ]),
              let output = filter.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: false])
        context.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        red = Double(pixel[0]) / 255
        green = Double(pixel[1]) / 255
        blue = Double(pixel[2]) / 255
    }
}

extension View {
    /// The cover's colour behind the widget, with text that reads on it. Only in full colour
    /// with the background showing: tinted and clear Home Screens, StandBy and the Lock Screen
    /// draw their own, and the system's colours read there.
    func coverBackground(_ cover: CoverColor?) -> some View {
        modifier(CoverBackground(cover: cover))
    }
}

private struct CoverBackground: ViewModifier {
    let cover: CoverColor?
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    func body(content: Content) -> some View {
        if let cover, renderingMode == .fullColor, showsBackground {
            content
                .environment(\.colorScheme, cover.isDark ? .dark : .light)
                .containerBackground(for: .widget) {
                    // A little light from the top, as a lit surface rather than a flat swatch.
                    cover.color
                        .overlay(LinearGradient(
                            colors: [.white.opacity(cover.isDark ? 0.08 : 0.14), .black.opacity(cover.isDark ? 0.12 : 0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
        } else {
            content.containerBackground(.fill.tertiary, for: .widget)
        }
    }
}
