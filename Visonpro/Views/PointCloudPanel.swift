import SwiftUI

struct PointCloudPanel: View {
    let session: PointCloudPageSession

    var body: some View {
        ZStack {
            Color.black
            if let url = session.pageURL {
                WebPointCloudView(url: url, reloadID: session.reloadID)
            } else {
                ContentUnavailableView(
                    "未配置点云网页",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("请在连接设置中填写点云网页地址。")
                )
            }
        }
    }
}
