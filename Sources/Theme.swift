import SwiftUI

/// 和电脑版手机端一致的配色
enum Theme {
    static let bg = Color(hex: 0xF5F6F8)
    static let panel = Color.white
    static let line = Color(hex: 0xE6E8EC)
    static let text = Color(hex: 0x1F2329)
    static let muted = Color(hex: 0x8A9099)
    static let brand = Color(hex: 0x2F6FED)
    static let brandSoft = Color(hex: 0xEAF1FF)
    static let danger = Color(hex: 0xE5484D)
    static let dangerSoft = Color(hex: 0xFDECEC)
    static let warn = Color(hex: 0xE08A00)
    static let warnSoft = Color(hex: 0xFFF6E5)
    static let ok = Color(hex: 0x12A150)
    static let okSoft = Color(hex: 0xE8F7EE)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

/// 白色卡片
struct Card: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View {
        modifier(Card(padding: padding))
    }
}

/// 简笔小钟（细线条，不用系统图标）
struct MiniClock: View {
    var size: CGFloat = 10
    var color: Color = Theme.muted

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: size / 2))
                p.addLine(to: CGPoint(x: size / 2, y: size * 0.26))
                p.move(to: CGPoint(x: size / 2, y: size / 2))
                p.addLine(to: CGPoint(x: size * 0.74, y: size / 2))
            }
            .stroke(color, lineWidth: 1)
        }
        .frame(width: size, height: size)
    }
}

/// 统一的胶囊按钮：白底 + 细边框（和聊天页左上角的提示同一风格）
struct PillButton: ViewModifier {
    var blue: Bool = false
    var active: Bool = false
    var filled: Bool = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(filled ? Color.white : ((blue || active) ? Theme.brand : Theme.muted))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(filled ? Theme.ok : Theme.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(filled ? Color.clear : Theme.line, lineWidth: 1))
    }
}

extension View {
    func pill(blue: Bool = false, active: Bool = false, filled: Bool = false) -> some View {
        modifier(PillButton(blue: blue, active: active, filled: filled))
    }
}
