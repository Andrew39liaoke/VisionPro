import SwiftUI

struct DualStreamViewport<Video: View, PointCloud: View>: View {
    @GestureState private var dragTranslation: CGSize = .zero
    let layout: ViewportLayoutState
    private let video: Video
    private let pointCloud: PointCloud

    init(
        layout: ViewportLayoutState,
        @ViewBuilder video: () -> Video,
        @ViewBuilder pointCloud: () -> PointCloud
    ) {
        self.layout = layout
        self.video = video()
        self.pointCloud = pointCloud()
    }

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let inset: CGFloat = 18
            let pipWidth = min(max(container.width * 0.28, 220), 340)
            let pipHeight = min(pipWidth * 9 / 16, container.height * 0.4)
            let pipSize = CGSize(width: pipWidth, height: pipHeight)
            let fullCenter = CGPoint(x: container.width / 2, y: container.height / 2)
            let pipCenter = layout.pipCenter(
                in: container,
                pipSize: pipSize,
                inset: inset,
                drag: dragTranslation
            )

            ZStack {
                panel(
                    video,
                    title: "实时视频",
                    isPrimary: layout.primary == .video,
                    container: container,
                    pipSize: pipSize,
                    fullCenter: fullCenter,
                    pipCenter: pipCenter
                )

                panel(
                    pointCloud,
                    title: "实时点云",
                    isPrimary: layout.primary == .pointCloud,
                    container: container,
                    pipSize: pipSize,
                    fullCenter: fullCenter,
                    pipCenter: pipCenter
                )

                Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .frame(width: pipWidth, height: pipHeight)
                .position(pipCenter)
                .zIndex(3)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            if hypot(value.translation.width, value.translation.height) < 8 {
                                layout.swap()
                            } else {
                                layout.movePip(
                                    by: value.translation,
                                    in: container,
                                    pipSize: pipSize,
                                    inset: inset
                                )
                            }
                        }
                )
                .disabled(layout.isSwapping)

                Button(action: layout.swap) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .position(
                    x: pipCenter.x + pipWidth / 2 - 32,
                    y: pipCenter.y - pipHeight / 2 + 32
                )
                .zIndex(4)
                .disabled(layout.isSwapping)
                .accessibilityLabel(layout.primary == .video ? "将点云切换为主视图" : "将视频切换为主视图")
            }
            .animation(.smooth(duration: 0.35), value: layout.primary)
            .clipped()
        }
    }

    private func panel<Content: View>(
        _ content: Content,
        title: String,
        isPrimary: Bool,
        container: CGSize,
        pipSize: CGSize,
        fullCenter: CGPoint,
        pipCenter: CGPoint
    ) -> some View {
        content
            .frame(
                width: isPrimary ? container.width : pipSize.width,
                height: isPrimary ? container.height : pipSize.height
            )
            .overlay(alignment: .topLeading) {
                if !isPrimary {
                    Label(title, systemImage: "hand.draw")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isPrimary ? 18 : 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isPrimary ? 18 : 14, style: .continuous)
                    .strokeBorder(.white.opacity(isPrimary ? 0.08 : 0.35), lineWidth: isPrimary ? 1 : 1.5)
            }
            .shadow(color: .black.opacity(isPrimary ? 0 : 0.35), radius: 18, y: 8)
            .position(isPrimary ? fullCenter : pipCenter)
            .zIndex(isPrimary ? 0 : 2)
            .allowsHitTesting(isPrimary)
    }
}
