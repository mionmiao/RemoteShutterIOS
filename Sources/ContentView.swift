import SwiftUI

struct RootView: View {
    @EnvironmentObject var hub: ServiceHub
    @State private var relayURL = ""
    @State private var deviceId = ""
    @State private var agentKey = ""

    var body: some View {
        ZStack {
            NavigationStack {
                Form {
                    Section("服务") {
                        LabeledContent("状态", value: hub.status)
                        LabeledContent("局域网", value: hub.address.isEmpty ? "—" : hub.address)
                        Button(hub.started ? "停止服务" : "启动服务") { hub.toggleService() }
                        Toggle("黑屏遮罩（不真锁屏）", isOn: $hub.blackout)
                        Toggle("退到后台仍保持声音/中继", isOn: $hub.backgroundAudio)
                    }
                    Section("公网中继（可选，自建 server.js）") {
                        TextField("ws://<VPS>:8787/_relay/agent", text: $relayURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("设备 ID", text: $deviceId)
                        SecureField("AGENT_KEY", text: $agentKey)
                        LabeledContent("中继", value: hub.relayStatus)
                        Button("保存并连接") {
                            hub.saveRelay(url: relayURL, id: deviceId, key: agentKey)
                        }
                    }
                    Section("分时说明") {
                        Text("前台：相机、预览、拍照、中继全部可用。\n后台/锁屏：iOS 强制中断相机，只剩声音与链路；回到前台自动恢复。\n免费 Apple ID 签名 7 天有效，需 Sideloadly / AltStore 续签。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("iOS 版未实现") {
                        Text("屏幕镜像、远程点击/按键、系统内录、录像、PIP 双摄拍照：接口返回 501。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("远程快门 iOS")
            }
            if hub.blackout {
                Color.black.ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Button("退出黑屏") { hub.blackout = false }
                            .padding().background(.ultraThinMaterial).cornerRadius(10).padding(.bottom, 40)
                    }
            }
        }
        .onAppear {
            relayURL = hub.relayURL
            deviceId = hub.deviceId
            agentKey = hub.agentKey
        }
    }
}
