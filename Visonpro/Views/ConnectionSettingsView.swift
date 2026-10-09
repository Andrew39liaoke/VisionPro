import SwiftUI
import StreamingCore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let session: StreamSession
    let pointCloudSession: PointCloudPageSession
    @State private var address = ""
    @State private var pointCloudAddress = ""
    @State private var authentication = "none"
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var fill = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://10.252.68.17:8889/d435i/whep", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityLabel("WHEP 视频地址")
                } header: { Text("视频地址") } footer: {
                    Text("填写 Ubuntu 主机的地址，末尾保留 /d435i/whep。首次连接请允许访问本地网络。")
                }
                Section {
                    TextField("http://192.168.3.21:8080/", text: $pointCloudAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityLabel("点云网页地址")
                } header: { Text("点云网页地址") } footer: {
                    Text("网页内的点云服务器连接参数仍在网页中填写。将点云切换为主视图后即可正常输入。")
                }
                Section("访问认证") {
                    Picker("认证方式", selection: $authentication) {
                        Text("无需认证").tag("none")
                        Text("用户名和密码").tag("basic")
                        Text("Bearer Token").tag("bearer")
                    }
                    if authentication == "basic" {
                        TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $password)
                    }
                    if authentication == "bearer" { SecureField("Token", text: $token) }
                    Text("凭据按视频地址保存在设备钥匙串中。更换地址时，请填写该服务器对应的凭据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("画面") {
                    Toggle("裁剪画面以填满区域", isOn: $fill)
                    Text("关闭时保留完整画面和原始宽高比。").font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    NavigationLink("开源组件许可") {
                        ScrollView {
                            Text(licenseText).font(.caption.monospaced()).textSelection(.enabled).padding()
                        }.navigationTitle("开源组件许可")
                    }
                }
            }
            .navigationTitle("连接设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并连接") { save() }
                        .disabled(
                            address.trimmingCharacters(in: .whitespaces).isEmpty ||
                            pointCloudAddress.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            }
        }
        .frame(width: 640, height: 700)
        .alert("无法保存连接设置", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "请检查连接参数。")
        }
        .onAppear {
            address = session.endpointText
            pointCloudAddress = pointCloudSession.endpointText
            fill = session.fillVideo
            guard !address.isEmpty else { return }
            do {
                switch try CredentialStore.load(for: address) {
                case .none: authentication = "none"
                case .basic(let user, let pass): authentication = "basic"; username = user; password = pass
                case .bearer(let value): authentication = "bearer"; token = value
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func save() {
        let credential: StreamCredential
        switch authentication {
        case "basic":
            guard !username.isEmpty, !username.contains(":"), !username.contains("\n"), !password.contains("\n") else {
                message = "请填写有效用户名，用户名不能包含冒号或换行。"; return
            }
            credential = .basic(username: username, password: password)
        case "bearer":
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { message = "请填写有效 Token。"; return }
            credential = .bearer(value)
        default: credential = .none
        }
        do {
            let pointCloudURL = try PointCloudPageSession.pageURL(from: pointCloudAddress)
            try session.saveSettings(url: address, credential: credential, fill: fill)
            pointCloudSession.apply(url: pointCloudURL)
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "LiveKitWebRTC — MIT / WebRTC — BSD-3-Clause" }
        return text
    }
}
