import Foundation

/// What one of your devices is, for its symbol: a MacBook and an iMac look different in the
/// list, as they do in Find My.
public enum NearbyDeviceKind: String, CaseIterable, Sendable {
    case iPhone, iPad, macBook, iMac, macMini, macPro
    /// A Mac on a desk that doesn't say which: a Mac Studio, or one too new to know.
    case macDesktop

    /// Read from what a device says in its hello. Devices from before kinds were sent say
    /// only their platform, and most Macs are laptops.
    public init(platform: String, kind: String?) {
        switch (platform, kind) {
        case (_, "iMac"): self = .iMac
        case (_, "Mac mini"): self = .macMini
        case (_, "Mac Pro"): self = .macPro
        case (_, "Mac"): self = .macDesktop
        case ("Mac", _): self = .macBook
        case ("iPad", _): self = .iPad
        default: self = .iPhone
        }
    }

    /// This Mac's kind, from its model identifier and whether it runs on a battery. Apple
    /// silicon identifiers ("Mac14,2") no longer name the line, so the battery tells a laptop.
    public static func mac(hardwareModel: String, hasBattery: Bool) -> NearbyDeviceKind {
        if hasBattery || hardwareModel.hasPrefix("MacBook") { return .macBook }
        if hardwareModel.hasPrefix("iMac") { return .iMac }
        if hardwareModel.hasPrefix("Macmini") { return .macMini }
        if hardwareModel.hasPrefix("MacPro") { return .macPro }
        return .macDesktop
    }

    /// How it's said in a hello.
    public var wireName: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .macBook: "MacBook"
        case .iMac: "iMac"
        case .macMini: "Mac mini"
        case .macPro: "Mac Pro"
        case .macDesktop: "Mac"
        }
    }

    public var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .macBook: "laptopcomputer"
        case .iMac: "desktopcomputer"
        case .macMini: "macmini"
        case .macPro: "macpro.gen3"
        case .macDesktop: "display"
        }
    }

    public var isMac: Bool {
        switch self {
        case .iPhone, .iPad: false
        default: true
        }
    }
}
