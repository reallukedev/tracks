import Foundation

/// The colours a cover is made of, as they look, for the player's backgrounds.
///
/// The pixels are sorted into buckets by hue, a light and a dark bucket for each of twelve
/// hues, and three for greys by lightness. Each bucket's weight is its share of the cover,
/// counted up for how vivid it is, since a small bright shape carries more of a cover than
/// the same area of grey. The heaviest buckets come back, most of the cover first, leaving
/// out any too close to one already taken, so a cover of reds gives one red, not three.
public nonisolated enum CoverPalette {
    public struct Colour: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// How far it is from grey, 0 to 1.
        public var chroma: Double { max(red, green, blue) - min(red, green, blue) }

        public var brightness: Double { max(red, green, blue) }

        /// Hue, 0 to 1, red at 0.
        public var hue: Double {
            let high = max(red, green, blue)
            let chroma = self.chroma
            guard chroma > 0 else { return 0 }
            let sector: Double = switch high {
            case red: (green - blue) / chroma
            case green: (blue - red) / chroma + 2
            default: (red - green) / chroma + 4
            }
            let hue = sector / 6
            return hue < 0 ? hue + 1 : hue
        }

        /// Straight-line distance, 0 for the same colour, about 1 for black to white.
        public func distance(to other: Colour) -> Double {
            let (r, g, b) = (red - other.red, green - other.green, blue - other.blue)
            return (r * r + g * g + b * b).squareRoot() / 3.squareRoot()
        }

        /// Toward `other` by `amount`, 0 to 1.
        public func mixed(with other: Colour, by amount: Double) -> Colour {
            Colour(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount
            )
        }

        public static let white = Colour(red: 1, green: 1, blue: 1)
        public static let black = Colour(red: 0, green: 0, blue: 0)
    }

    /// Below this chroma a pixel counts as grey.
    static let greyChroma = 0.12
    /// Colours closer than this are one colour.
    static let sameColour = 0.12
    /// A bucket with less of the weight than this is a speck, unless it's all there is.
    static let speck = 0.03

    /// The cover's colours, most of it first, at most `limit` of them.
    ///
    /// - Parameter rgba: pixels as red, green, blue and alpha bytes, four to a pixel. Pixels
    ///   less than half opaque are left out.
    public static func colours(rgba: [UInt8], limit: Int = 5) -> [Colour] {
        var weights = [Double](repeating: 0, count: 27)
        var sums = [Colour](repeating: .black, count: 27)
        var counts = [Double](repeating: 0, count: 27)
        var index = 0
        while index + 3 < rgba.count {
            defer { index += 4 }
            guard rgba[index + 3] >= 128 else { continue }
            let alpha = Double(rgba[index + 3]) / 255
            // Premultiplied bytes are divided back out, so a soft edge keeps its colour.
            let pixel = Colour(
                red: min(1, Double(rgba[index]) / 255 / alpha),
                green: min(1, Double(rgba[index + 1]) / 255 / alpha),
                blue: min(1, Double(rgba[index + 2]) / 255 / alpha)
            )
            let bucket: Int
            let weight: Double
            if pixel.chroma < greyChroma {
                bucket = 24 + min(2, Int(pixel.brightness * 3))
                weight = 0.6
            } else {
                bucket = min(11, Int(pixel.hue * 12)) * 2 + (pixel.brightness < 0.55 ? 0 : 1)
                weight = 1 + 2 * pixel.chroma
            }
            weights[bucket] += weight
            counts[bucket] += 1
            sums[bucket].red += pixel.red
            sums[bucket].green += pixel.green
            sums[bucket].blue += pixel.blue
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var chosen: [Colour] = []
        for bucket in weights.indices.sorted(by: { weights[$0] > weights[$1] }) {
            guard chosen.count < limit, counts[bucket] > 0 else { break }
            guard chosen.isEmpty || weights[bucket] / total >= speck else { break }
            let sum = sums[bucket]
            let colour = Colour(red: sum.red / counts[bucket], green: sum.green / counts[bucket], blue: sum.blue / counts[bucket])
            if chosen.allSatisfy({ $0.distance(to: colour) >= sameColour }) {
                chosen.append(colour)
            }
        }
        return chosen
    }

    /// At least `count` colours: the cover's, then lighter and darker shades of its first,
    /// for a cover of one colour.
    public static func filled(_ colours: [Colour], to count: Int) -> [Colour] {
        guard let first = colours.first else { return [] }
        var filled = colours
        var step = 0
        while filled.count < count {
            let shade = step.isMultiple(of: 2)
                ? first.mixed(with: .white, by: 0.22 + 0.1 * Double(step / 2))
                : first.mixed(with: .black, by: 0.3 + 0.1 * Double(step / 2))
            filled.append(shade)
            step += 1
        }
        return filled
    }
}
