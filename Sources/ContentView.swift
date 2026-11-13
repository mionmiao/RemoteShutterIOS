import SwiftUI

/// 相机端界面：默认纯黑、不显示任何控件。所有控制移到观看端网页。
/// 首次启动显示 8 秒地址便于接入；之后长按屏幕 1.2 秒可临时查看状态（5 秒后自动隐藏）。
struct RootView: View {
    @EnvironmentObject var hub: ServiceHub
    @State private var showInfo = false
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.2) { reveal() }

            if showInfo {
                VStack(spacing: 8) {
                    Text("远程快门 · iOS").font(.headline)
                    Text(hub.address.isEmpty ? "服务启动中…" : hub.address)
                        .font(.system(.body, design: .monospaced))
                    Text("相机：\(hub.cameraNote.isEmpty ? "—" : hub.cameraNote)")
                    Text("中继：\(hub.relayStatus)")
                    Text("长按屏幕可再次查看 · 全部控制在网页端")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .padding()
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "rs.addressShown") {
                UserDefaults.standard.set(true, forKey: "rs.addressShown")
                reveal(seconds: 8)
            }
        }
    }

    private func reveal(seconds: Double = 5) {
        showInfo = true
        hideWork?.cancel()
        let work = DispatchWorkItem { showInfo = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
