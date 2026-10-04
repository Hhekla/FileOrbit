import SwiftUI

/// The warm "citrus glass" palette shared by the wheel and the tool windows.
enum Theme {
    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        let red: Double = Double((value >> 16) & 0xff) / 255
        let green: Double = Double((value >> 8) & 0xff) / 255
        let blue: Double = Double(value & 0xff) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    // Accent
    static let tangerine = hex(0x176D60)
    static let tangerineLight = hex(0x429B86)
    static let tangerineDeep = hex(0x0F5146)

    /// Dark brown used for text on peach surfaces.
    static let ink = hex(0x183C35)
    static let inkSecondary = hex(0x4D7168)

    // Wheel
    static let discFill = LinearGradient(colors: [hex(0xD5E8DF, 0.78), hex(0xB7D6C8, 0.74), hex(0xA0C8B6, 0.76)],
                                         startPoint: .top, endPoint: .bottom)
    static let rim = LinearGradient(colors: [hex(0xFFFFFF, 0.85), hex(0xDBEAE2, 0.45), hex(0x689A85, 0.55)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let segmentFill = LinearGradient(colors: [hex(0xE3EEE7, 0.96), hex(0xCBDDD3, 0.94)],
                                            startPoint: .top, endPoint: .bottom)
    static let segmentHover = LinearGradient(colors: [hex(0x3C917D), hex(0x176D60)],
                                             startPoint: .top, endPoint: .bottom)
    static let well = RadialGradient(colors: [hex(0x80B29D, 0.92), hex(0x5C9983, 0.92)],
                                     center: .center, startRadius: 0, endRadius: 60)
    static let pill = LinearGradient(colors: [hex(0xD4E7DC), hex(0xB8D4C4)], startPoint: .top, endPoint: .bottom)

    // Windows
    static let windowGradient = LinearGradient(colors: [hex(0xEFF3E9, 0.93), hex(0xE3EEDF, 0.93), hex(0xD6E6DA, 0.93)],
                                               startPoint: .top, endPoint: .bottom)
    static let fieldFill = Color.white.opacity(0.85)
    static let trackFill = Color.white.opacity(0.32)
    static let separator = Color.white.opacity(0.35)
}

