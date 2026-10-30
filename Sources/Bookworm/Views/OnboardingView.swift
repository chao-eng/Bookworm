import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        ZStack {
            BookwormBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                PaperBookHero(size: 400)
                    .frame(width: 480, height: 480)

                Spacer(minLength: 24)

                Text("把书架放进桌面一角，把故事留给自己。")
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .multilineTextAlignment(.center)

                Spacer(minLength: 36)

                Button {
                    library.promptForFolder()
                } label: {
                    Text("选择书库文件夹")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.07, green: 0.08, blue: 0.12))
                                .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 60)
        }
    }
}

struct BookwormBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color.white, location: 0.0),
                    .init(color: Color(red: 0.972, green: 0.973, blue: 0.980), location: 0.55),
                    .init(color: Color(red: 0.957, green: 0.961, blue: 0.973), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 左下角极淡的粉紫光，呼应参考图侧边栏的暖色晕染
            RadialGradient(
                colors: [
                    Color(red: 0.969, green: 0.910, blue: 0.933).opacity(0.35),
                    Color.clear
                ],
                center: UnitPoint(x: 0.12, y: 0.95),
                startRadius: 0,
                endRadius: 620
            )
        }
    }
}
