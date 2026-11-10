import SwiftUI

/// 启动页（参考电脑版的加载界面）
struct SplashView: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .padding(.bottom, 26)

                Text("AI小助手")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.text)

                Text("作者：Night")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 12)

                VStack(spacing: 12) {
                    Text("正在打开库存…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.line)
                            .frame(width: 130, height: 2)
                        Capsule()
                            .fill(Color(hex: 0xE07B39))
                            .frame(width: 130 * progress, height: 2)
                    }
                }
                .padding(.top, 22)
            }
            .offset(y: -40)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2)) { progress = 1 }
        }
    }
}
