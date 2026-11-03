// Crepuscule - ScannedCode.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

/// A machine-readable code payload, decoded into the thing it actually describes.
public struct ScannedCode: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        public var title: String?
        public var start: Date?
        public var end: Date?
        public var allDay = false
        public var location: String?
        public var notes: String?
        public var url: URL?
    }

    public enum Kind: Equatable, Sendable {
        case url(URL)
        case email(address: String, subject: String?, body: String?)
        case sms(number: String, body: String?)
        case phone(String)
        case wifi(ssid: String, password: String?, security: String?, hidden: Bool)
        case location(latitude: Double, longitude: Double, label: String?)
        /// `vCard` is always a vCard 3.0 document, MECARD payloads are converted.
        case contact(name: String?, vCard: String)
        case event(Event)
        case product(String)
        case text(String)
    }

    public let raw: String
    public let kind: Kind

    public init(_ raw: String) {
        self.raw = raw
        self.kind = Self.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The URL that performs the code's natural action, when one exists.
    public var actionURL: URL? {
        switch kind {
        case .url(let url): return url
        case .email(let address, let subject, let body):
            var query: [String] = []
            if let subject, !subject.isEmpty { query.append("subject=" + Self.encode(subject)) }
            if let body, !body.isEmpty { query.append("body=" + Self.encode(body)) }
            return URL(string: "mailto:" + Self.encode(address, keeping: "@+") + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
        case .sms(let number, let body):
            let target = Self.encode(Self.dialable(number), keeping: "+")
            if let body, !body.isEmpty { return URL(string: "sms:\(target)&body=" + Self.encode(body)) }
            return URL(string: "sms:" + target)
        case .phone(let number):
            return URL(string: "tel:" + Self.encode(Self.dialable(number), keeping: "+*#,;"))
        case .location(let lat, let lon, let label):
            var s = "https://maps.apple.com/?ll=\(lat),\(lon)"
            if let label, !label.isEmpty { s += "&q=" + Self.encode(label) }
            return URL(string: s)
        case .event(let e): return e.url
        case .wifi, .contact, .product, .text: return nil
        }
    }

    public var title: String {
        switch kind {
        case .url(let url):
            if let host = url.host(percentEncoded: false), !host.isEmpty {
                return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (url.path().count > 1 ? url.path(percentEncoded: false) : "")
            }
            return raw
        case .email(let address, _, _): return address
        case .sms(let number, _): return number
        case .phone(let number): return number
        case .wifi(let ssid, _, _, _): return ssid
        case .location(let lat, let lon, let label): return label ?? String(format: "%.5f, %.5f", lat, lon)
        case .contact(let name, _): return name ?? "Contact"
        case .event(let e): return e.title ?? "Event"
        case .product(let digits): return digits
        case .text(let text): return text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Secondary line: what the tap will do, plus any extra content.
    public var subtitle: String? {
        switch kind {
        case .url(let url): return url.scheme.map { ["http", "https"].contains($0.lowercased()) } == true ? "Open in Safari" : "Open link"
        case .email(_, let subject, let body): return Self.join("Send email", subject ?? body)
        case .sms(_, let body): return Self.join("Send message", body)
        case .phone: return "Call"
        case .wifi(_, let password, _, _): return password?.isEmpty == false ? "Wi-Fi · Copy password" : "Wi-Fi network"
        case .location: return "Open in Maps"
        case .contact: return "Add to Contacts"
        case .event(let e):
            guard let start = e.start else { return "Add to Calendar" }
            return Self.join("Add to Calendar", start.formatted(date: .abbreviated, time: e.allDay ? .omitted : .shortened))
        case .product: return "Barcode · Copy"
        case .text: return "Copy text"
        }
    }

    public var systemImage: String {
        switch kind {
        case .url: return "safari"
        case .email: return "envelope"
        case .sms: return "message"
        case .phone: return "phone"
        case .wifi: return "wifi"
        case .location: return "mappin.and.ellipse"
        case .contact: return "person.crop.circle.badge.plus"
        case .event: return "calendar.badge.plus"
        case .product: return "barcode"
        case .text: return "doc.on.doc"
        }
    }

    // MARK: - Parsing

    static func parse(_ s: String) -> Kind {
        guard !s.isEmpty else { return .text(s) }
        let upper = s.uppercased()
        func has(_ prefix: String) -> Bool { upper.hasPrefix(prefix) }

        if has("MATMSG:") {
            let f = fields(String(s.dropFirst(7)))
            if let to = f["TO"], !to.isEmpty { return .email(address: to, subject: f["SUB"], body: f["BODY"]) }
        }
        if has("MAILTO:"), let c = URLComponents(string: s) {
            let address = c.path.removingPercentEncoding ?? c.path
            let q = c.queryItems ?? []
            func item(_ n: String) -> String? { q.first { $0.name.lowercased() == n }?.value }
            if !address.isEmpty || item("to") != nil {
                return .email(address: address.isEmpty ? item("to")! : address, subject: item("subject"), body: item("body"))
            }
        }
        if has("SMTP:") {
            let p = s.dropFirst(5).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if let to = p.first, !to.isEmpty { return .email(address: to, subject: p.count > 1 ? p[1] : nil, body: p.count > 2 ? p[2] : nil) }
        }
        if has("SMSTO:") || has("MMSTO:") {
            let p = s.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let n = p.first, !n.isEmpty { return .sms(number: n, body: p.count > 1 ? p[1] : nil) }
        }
        if has("SMS:") || has("MMS:") {
            var rest = String(s.dropFirst(4))
            var body: String?
            if let q = rest.firstIndex(where: { $0 == "?" || $0 == "&" }) {
                let query = rest[rest.index(after: q)...]
                for pair in query.split(separator: "&") where pair.lowercased().hasPrefix("body=") {
                    body = String(pair.dropFirst(5)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                }
                rest = String(rest[..<q])
            } else if let colon = rest.firstIndex(of: ":") {
                body = String(rest[rest.index(after: colon)...])
                rest = String(rest[..<colon])
            }
            let number = rest.removingPercentEncoding ?? rest
            if !number.isEmpty { return .sms(number: number, body: body?.isEmpty == true ? nil : body) }
        }
        if has("TEL:") {
            let n = String(s.dropFirst(4)).removingPercentEncoding ?? String(s.dropFirst(4))
            if !n.isEmpty { return .phone(n) }
        }
        if has("WIFI:") {
            let f = fields(String(s.dropFirst(5)))
            if let ssid = f["S"], !ssid.isEmpty {
                let security = f["T"].flatMap { $0.isEmpty || $0.lowercased() == "nopass" ? nil : $0 }
                return .wifi(ssid: ssid, password: f["P"].flatMap { $0.isEmpty ? nil : $0 }, security: security, hidden: f["H"]?.lowercased() == "true")
            }
        }
        if has("GEO:") {
            var rest = String(s.dropFirst(4))
            var label: String?
            if let q = rest.firstIndex(of: "?") {
                for pair in rest[rest.index(after: q)...].split(separator: "&") where pair.lowercased().hasPrefix("q=") {
                    label = String(pair.dropFirst(2)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                }
                rest = String(rest[..<q])
            }
            let nums = rest.split(separator: ";").first?.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
            if nums.count >= 2, abs(nums[0]) <= 90, abs(nums[1]) <= 180 {
                if let l = label, let open = l.firstIndex(of: "("), l.hasSuffix(")") { label = String(l[l.index(after: open)..<l.index(before: l.endIndex)]) }
                return .location(latitude: nums[0], longitude: nums[1], label: label?.isEmpty == true ? nil : label)
            }
        }
        if has("BEGIN:VCARD") {
            let props = properties(s)
            let name = props.first { $0.name == "FN" }?.value ?? props.first { $0.name == "N" }.map { vCardName($0.value) }
            return .contact(name: name?.isEmpty == true ? nil : name, vCard: s)
        }
        if has("MECARD:") {
            let f = fieldLists(String(s.dropFirst(7)))
            return .contact(name: mecardName(f["N"]?.first), vCard: mecardToVCard(f))
        }
        if has("BEGIN:VCALENDAR") || has("BEGIN:VEVENT") {
            return .event(event(s))
        }
        if let url = webURL(s) { return .url(url) }
        if s.count >= 8, s.count <= 14, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber) { return .product(s) }
        return .text(s)
    }

    private static func webURL(_ s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme.first?.isLetter == true {
            if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? url : nil }
            // Bare "host:port" style strings aren't links.
            if Int(s.dropFirst(scheme.count + 1).prefix(while: \.isNumber)) != nil, !s.dropFirst(scheme.count + 1).hasPrefix("/") { return nil }
            return url
        }
        if s.lowercased().hasPrefix("www."), let url = URL(string: "https://" + s), url.host?.contains(".") == true { return url }
        return nil
    }

    // MARK: MECARD-style "KEY:value;KEY:value;;"

    /// Splits `KEY:value;` fields, honouring backslash escapes. Repeated keys are all kept.
    static func fieldLists(_ s: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var key = "", value = "", inKey = true, escaped = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty { out[k, default: []].append(value) }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if escaped { if inKey { key.append(ch) } else { value.append(ch) }; escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case ";": flush()
            case ":" where inKey: inKey = false
            default: if inKey { key.append(ch) } else { value.append(ch) }
            }
        }
        if !key.isEmpty || !value.isEmpty { flush() }
        return out
    }

    static func fields(_ s: String) -> [String: String] {
        fieldLists(s).compactMapValues(\.first)
    }

    private static func mecardName(_ n: String?) -> String? {
        guard let n, !n.isEmpty else { return nil }
        let parts = n.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : n
    }

    private static func mecardToVCard(_ f: [String: [String]]) -> String {
        func esc(_ v: String) -> String {
            v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if let n = f["N"]?.first, !n.isEmpty {
            let parts = n.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            lines.append("N:" + esc(parts[0]) + ";" + (parts.count > 1 ? esc(parts[1]) : "") + ";;;")
            lines.append("FN:" + esc(mecardName(n) ?? n))
        }
        if let v = f["SOUND"]?.first, !v.isEmpty { lines.append("X-PHONETIC-LAST-NAME:" + esc(v)) }
        if let v = f["NICKNAME"]?.first, !v.isEmpty { lines.append("NICKNAME:" + esc(v)) }
        if let v = f["ORG"]?.first, !v.isEmpty { lines.append("ORG:" + esc(v)) }
        if let v = f["TITLE"]?.first, !v.isEmpty { lines.append("TITLE:" + esc(v)) }
        for v in f["TEL"] ?? [] where !v.isEmpty { lines.append("TEL;TYPE=CELL:" + esc(v)) }
        for v in f["TEL-AV"] ?? [] where !v.isEmpty { lines.append("TEL;TYPE=VIDEO:" + esc(v)) }
        for v in f["EMAIL"] ?? [] where !v.isEmpty { lines.append("EMAIL;TYPE=INTERNET:" + esc(v)) }
        for v in f["ADR"] ?? [] where !v.isEmpty {
            // MECARD ADR is comma-separated: PO box, extended, street, city, region, postal code, country.
            let p = v.split(separator: ",", omittingEmptySubsequences: false).map { esc($0.trimmingCharacters(in: .whitespaces)) }
            lines.append("ADR:" + (p.count == 7 ? p.joined(separator: ";") : ";;" + esc(v) + ";;;;"))
        }
        for v in f["URL"] ?? [] where !v.isEmpty { lines.append("URL:" + v) }
        if let v = f["BDAY"]?.first, v.count == 8 { lines.append("BDAY:\(v.prefix(4))-\(v.dropFirst(4).prefix(2))-\(v.suffix(2))") }
        if let v = f["NOTE"]?.first, !v.isEmpty { lines.append("NOTE:" + esc(v)) }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: vCard / iCalendar content lines

    struct Property { var name: String; var params: [String: String]; var value: String }

    static func properties(_ s: String) -> [Property] {
        var unfolded: [String] = []
        for line in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            if let first = line.first, first == " " || first == "\t", !unfolded.isEmpty { unfolded[unfolded.count - 1] += line.dropFirst() }
            else { unfolded.append(String(line)) }
        }
        return unfolded.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let head = line[..<colon].split(separator: ";").map(String.init)
            guard let rawName = head.first else { return nil }
            var params: [String: String] = [:]
            for p in head.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                params[kv[0].uppercased()] = kv.count > 1 ? kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : ""
            }
            // Drop vCard group prefixes like "item1.TEL".
            let name = rawName.split(separator: ".").last.map { $0.uppercased() } ?? rawName.uppercased()
            return Property(name: name, params: params, value: String(line[line.index(after: colon)...]))
        }
    }

    static func unescapeText(_ v: String) -> String {
        var out = "", escaped = false
        for ch in v {
            if escaped { out.append(ch == "n" || ch == "N" ? "\n" : ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    private static func vCardName(_ n: String) -> String {
        let p = n.split(separator: ";", omittingEmptySubsequences: false).map { unescapeText(String($0)) }
        return [p.count > 3 ? p[3] : "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "", p.first ?? "", p.count > 4 ? p[4] : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func event(_ s: String) -> Event {
        var e = Event()
        var inEvent = !s.uppercased().hasPrefix("BEGIN:VCALENDAR")
        for p in properties(s) {
            if p.name == "BEGIN", p.value.uppercased() == "VEVENT" { inEvent = true; continue }
            if p.name == "END", p.value.uppercased() == "VEVENT" { break }
            guard inEvent else { continue }
            switch p.name {
            case "SUMMARY": e.title = unescapeText(p.value)
            case "LOCATION": e.location = unescapeText(p.value)
            case "DESCRIPTION": e.notes = unescapeText(p.value)
            case "URL": e.url = URL(string: p.value)
            case "DTSTART":
                if let (d, allDay) = date(p.value, params: p.params) { e.start = d; e.allDay = allDay }
            case "DTEND":
                e.end = date(p.value, params: p.params)?.0
            default: break
            }
        }
        if e.allDay, let start = e.start, let end = e.end, end > start {
            // iCalendar all-day DTEND is exclusive.
            e.end = Calendar(identifier: .gregorian).date(byAdding: .second, value: -1, to: end)
        }
        return e
    }

    static func date(_ value: String, params: [String: String]) -> (Date, Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if params["VALUE"]?.uppercased() == "DATE" || (v.count == 8 && v.allSatisfy(\.isNumber)) {
            f.timeZone = .current
            f.dateFormat = "yyyyMMdd"
            return f.date(from: String(v.prefix(8))).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let d = f.date(from: v) { return (d, false) }
            f.dateFormat = "yyyyMMdd'T'HHmm'Z'"
            return f.date(from: v).map { ($0, false) }
        }
        f.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if let d = f.date(from: v) { return (d, false) }
        f.dateFormat = "yyyyMMdd'T'HHmm"
        return f.date(from: v).map { ($0, false) }
    }

    // MARK: Helpers

    private static func encode(_ s: String, keeping extra: String = "") -> String {
        var allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        allowed.formUnion(CharacterSet(charactersIn: extra))
        // `alphanumerics` covers non-ASCII letters; restrict to ASCII so they get percent-encoded.
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0x21)!...Unicode.Scalar(0x7E)!))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func dialable(_ n: String) -> String {
        n.filter { $0.isNumber || "+*#,;".contains($0) }
    }

    private static func join(_ a: String, _ b: String?) -> String {
        guard let b = b?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !b.isEmpty else { return a }
        return a + " · " + b
    }
}
