import Foundation

public struct ICEServer: Sendable, Equatable {
    public let url: String
    public let username: String?
    public let credential: String?
}

public enum ICELinkParser {
    public static func parse(_ header: String?) throws -> [ICEServer] {
        guard let header, !header.isEmpty else { return [] }
        return try split(header, separator: ",").compactMap { entry in
            let fields = split(entry, separator: ";")
            guard let target = fields.first else { return nil }
            var attributes: [String: String] = [:]
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                attributes[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = unquote(pair[1])
            }
            guard attributes["rel"]?.split(separator: " ").contains("ice-server") == true else { return nil }
            guard target.hasPrefix("<"), target.hasSuffix(">") else {
                throw StreamError.invalidResponse("ICE Link 地址格式错误")
            }
            let url = String(target.dropFirst().dropLast())
            guard ["stun:", "stuns:", "turn:", "turns:"].contains(where: { url.lowercased().hasPrefix($0) }),
                  attributes["credential-type"] == nil || attributes["credential-type"] == "password" else {
                throw StreamError.invalidResponse("不支持的 ICE server 配置")
            }
            return ICEServer(url: url, username: attributes["username"], credential: attributes["credential"])
        }
    }

    // A comma or semicolon inside quotes / URI brackets is not a delimiter.
    private static func split(_ value: String, separator: Character) -> [String] {
        var result: [String] = [], current = ""
        var quoted = false, escaped = false, bracketed = false
        for char in value {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\", quoted { escaped = true; current.append(char); continue }
            if char == "\"" { quoted.toggle() }
            if !quoted, char == "<" { bracketed = true }
            if !quoted, char == ">" { bracketed = false }
            if char == separator, !quoted, !bracketed {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
            } else { current.append(char) }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private static func unquote(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = "", escaped = false
        for char in value.dropFirst().dropLast() {
            if escaped { result.append(char); escaped = false }
            else if char == "\\" { escaped = true }
            else { result.append(char) }
        }
        return result
    }
}

public struct ICECandidate: Sendable, Equatable {
    public let sdp: String
    public let mLineIndex: Int
    public let mid: String?
    public init(sdp: String, mLineIndex: Int, mid: String?) {
        self.sdp = sdp; self.mLineIndex = mLineIndex; self.mid = mid
    }
}

public enum SDPFragmentBuilder {
    private struct Section {
        var media: String
        var mid: String?
        var ufrag: String?
        var password: String?
    }

    public static func build(offer: String, candidates: [ICECandidate]) throws -> String {
        var sections: [Section] = []
        var sessionUfrag: String?, sessionPassword: String?
        for raw in offer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { sections.append(Section(media: line)) }
            else if line.hasPrefix("a=mid:"), !sections.isEmpty { sections[sections.count - 1].mid = String(line.dropFirst(6)) }
            else if line.hasPrefix("a=ice-ufrag:") {
                let value = String(line.dropFirst(12))
                if sections.isEmpty { sessionUfrag = value } else { sections[sections.count - 1].ufrag = value }
            } else if line.hasPrefix("a=ice-pwd:") {
                let value = String(line.dropFirst(10))
                if sections.isEmpty { sessionPassword = value } else { sections[sections.count - 1].password = value }
            }
        }
        var groups: [Int: [ICECandidate]] = [:]
        for candidate in candidates {
            let index = candidate.mid.flatMap { mid in sections.firstIndex { $0.mid == mid } } ?? candidate.mLineIndex
            guard sections.indices.contains(index), candidate.sdp.hasPrefix("candidate:"),
                  candidate.sdp.rangeOfCharacter(from: .newlines) == nil else {
                throw StreamError.invalidResponse("ICE candidate 与 SDP 不匹配")
            }
            groups[index, default: []].append(candidate)
        }
        var lines: [String] = []
        for index in groups.keys.sorted() {
            let section = sections[index]
            guard let mid = section.mid, let ufrag = section.ufrag ?? sessionUfrag,
                  let password = section.password ?? sessionPassword else {
                throw StreamError.invalidResponse("SDP 缺少 ICE 参数")
            }
            lines += [section.media, "a=mid:\(mid)", "a=ice-ufrag:\(ufrag)", "a=ice-pwd:\(password)"]
            lines += groups[index, default: []].map { "a=\($0.sdp)" }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
