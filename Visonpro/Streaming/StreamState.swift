import Foundation

enum StreamState: Equatable {
    case idle, requesting, negotiating, connecting, playing, paused
    case retrying(seconds: Int)
    case failed

    var title: String {
        switch self {
        case .idle: "未连接"
        case .requesting: "正在连接视频主机"
        case .negotiating: "正在协商视频"
        case .connecting: "等待首帧"
        case .playing: "实时播放"
        case .paused: "已暂停"
        case .retrying(let seconds): "\(seconds) 秒后重新连接"
        case .failed: "连接失败"
        }
    }
    var isBusy: Bool {
        switch self {
        case .requesting, .negotiating, .connecting, .retrying: true
        default: false
        }
    }
}
