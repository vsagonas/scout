import Foundation

/// Finds video-call links (Zoom, Meet, Teams, Webex) in an event's URL, location and notes.
enum MeetingLink {
    struct Link: Equatable {
        let url: URL
        let service: String
    }

    static func service(for url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if url.scheme == "zoommtg" || isHost("zoom.us") || isHost("zoom.com") || isHost("zoomgov.com") { return "Zoom" }
        if host == "meet.google.com" { return "Google Meet" }
        if isHost("teams.microsoft.com") || isHost("teams.live.com") { return "Teams" }
        if isHost("webex.com") { return "Webex" }
        return nil
    }

    static func find(in texts: [String?]) -> Link? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                if let url = match.url, let name = service(for: url) { return Link(url: url, service: name) }
            }
            // zoommtg:// links are not always recognised as links by the detector.
            if let r = text.range(of: #"zoommtg://[^\s<>"']+"#, options: .regularExpression), let url = URL(string: String(text[r])) {
                return Link(url: url, service: "Zoom")
            }
        }
        return nil
    }
}
