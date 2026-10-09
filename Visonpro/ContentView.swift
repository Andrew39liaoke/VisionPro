import SwiftUI
import StreamingCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = StreamSession()
    @State private var pointCloudSession = PointCloudPageSession()
    @State private var viewportLayout = ViewportLayoutState()
    @State private var showingSettings = false
    #if DEBUG
    @State private var diagnosticURL: URL?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            DualStreamViewport(layout: viewportLayout) {
                videoPanel
            } pointCloud: {
                PointCloudPanel(session: pointCloudSession)
            }
            .padding(.horizontal, 20)
            footer
            if session.showMetrics { metricsPanel }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showingSettings) {
            ConnectionSettingsView(session: session, pointCloudSession: pointCloudSession)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.sceneChanged(phase)
            if session.endpointText.isEmpty { showingSettings = true }
        }
        .onDisappear { session.disconnect() }
        #if DEBUG
        .sheet(isPresented: Binding(get: { diagnosticURL != nil }, set: { if !$0 { diagnosticURL = nil } })) {
            if let diagnosticURL { WebDiagnosticView(url: diagnosticURL) }
        }
        #endif
    }

    private var videoPanel: some View {
        ZStack {
            Color.black
            if let video = session.video {
                RemoteVideoView(video: video, fill: session.fillVideo)
            }
            if session.state != .playing { connectionOverlay }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: viewportLayout.primary == .video ? "video.fill" : "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewportLayout.primary == .video ? "D435i RGB" : "实时点云")
                    .font(.title3.bold())
                Text("机器人视频与点云").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(session.state == .playing ? .green : .orange).frame(width: 8, height: 8)
            Text(session.state.title).font(.subheadline)
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("连接设置")
        }.padding(20)
    }

    private var connectionOverlay: some View {
        VStack(spacing: 16) {
            if session.state.isBusy { ProgressView().controlSize(.large) }
            else { Image(systemName: session.state == .failed ? "wifi.exclamationmark" : "video.slash").font(.system(size: 44)) }
            Text(session.state.title).font(.title2.bold())
            Text(session.errorMessage ?? "连接局域网中的 D435i，查看实时彩色视频。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
            if !session.wantsConnection {
                HStack {
                    Button("连接设置") { showingSettings = true }
                    if !session.endpointText.isEmpty {
                        Button("连接视频") { session.connect() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }.padding(32)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(session.metrics.resolution)
            Text(value(session.metrics.fps, suffix: "fps"))
            Spacer()
            Button { session.showMetrics.toggle() } label: { Image(systemName: "chart.bar.xaxis") }
                .accessibilityLabel("显示连接统计")
            Button { pointCloudSession.reload() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("重新加载点云网页")
            Button { session.fillVideo.toggle() } label: {
                Image(systemName: session.fillVideo ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.accessibilityLabel(session.fillVideo ? "完整显示视频" : "填满视频区域")
            if session.wantsConnection {
                Button("重新连接") { session.connect() }
                Button("断开", role: .destructive) { session.disconnect() }
            } else {
                Button("连接") {
                    if session.endpointText.isEmpty { showingSettings = true } else { session.connect() }
                }.buttonStyle(.borderedProminent)
            }
        }.font(.subheadline.monospacedDigit()).padding(20)
    }

    private var metricsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                metric("接收码率", value(session.metrics.mbps, suffix: "Mbps"))
                metric("往返时间", value(session.metrics.rttMS, suffix: "ms"))
                metric("抖动", value(session.metrics.jitterMS, suffix: "ms"))
                metric("区间丢包", value(session.metrics.lossPercent, suffix: "%"))
                metric("重连次数", "\(session.reconnectCount)")
            }
            Text("解码 \(session.metrics.decoded) 帧 · 丢弃 \(session.metrics.dropped) 帧 · \(session.metrics.transport) · \(session.metrics.decoder)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            #if DEBUG
            if let endpoint = try? StreamEndpoint(session.endpointText) {
                Button("打开网页诊断") {
                    session.disconnect()
                    diagnosticURL = endpoint.previewURL
                }.font(.caption)
            }
            #endif
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit())
        }
    }
    private func value(_ number: Double?, suffix: String) -> String {
        guard let number, number.isFinite else { return "— \(suffix)" }
        return String(format: "%.1f %@", number, suffix)
    }
}
#Preview(windowStyle: .automatic) { ContentView() }
