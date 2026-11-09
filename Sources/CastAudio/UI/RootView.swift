import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            StudioTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("投音 Mac")
                    .font(StudioTheme.displayFont)
                    .foregroundStyle(StudioTheme.textPrimary)
                StudioCard(title: "投音控制台", subtitle: "BOOTING") {
                    Text("正在初始化采集与投送管线…")
                        .font(StudioTheme.monoFont)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
