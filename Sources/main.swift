import CoreWLAN
import Network
import Cocoa
import CoreLocation
import IOKit.ps
import ServiceManagement

// MARK: - Style

extension NSColor {
    convenience init(hex: UInt32, a: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
}

enum Style {
    static let accent = NSColor(hex: 0x5EEAD4)          // aurora teal
    static let accent2 = NSColor(hex: 0xA78BFA)         // aurora violet
    static let primary = NSColor.white
    static let secondary = NSColor.white.withAlphaComponent(0.72)
    static let tertiary = NSColor.white.withAlphaComponent(0.45)
    static let radius: CGFloat = 26

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, rounded: Bool = false) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let d = f.fontDescriptor.withDesign(.rounded) else { return f }
        return NSFont(descriptor: d, size: size) ?? f
    }
}

@discardableResult
func text(_ s: String, _ p: NSPoint, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSSize {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern, .shadow: shadow])
    a.draw(at: p)
    return a.size()
}

func measure(_ s: String, _ font: NSFont, kern: CGFloat = 0) -> NSSize {
    NSAttributedString(string: s, attributes: [.font: font, .kern: kern]).size()
}

func symbol(_ name: String, in r: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
            colors: [NSColor]? = nil, multicolor: Bool = false) {
    var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if multicolor { cfg = cfg.applying(.preferringMulticolor()) }
    if let colors { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: colors)) }
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    let rect = NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
let ru = Locale(identifier: "ru_RU")

// MARK: - Data sources

final class SystemStats {
    private var prev: [UInt32]?
    private(set) var cpu: Double = 0

    func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        if let p = prev {
            let d = zip(t, p).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            if total > 0 { cpu = (total - d[2]) / total }
        }
        prev = t
    }

    func battery() -> (pct: Int, charging: Bool, plugged: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Int((Double(cur) / Double(max(mx, 1)) * 100).rounded()), charging, plugged)
        }
        return nil
    }
}

final class WeatherService: NSObject, CLLocationManagerDelegate {
    var temp: Double?, feels: Double?, wind: Double?, tmax: Double?, tmin: Double?
    var code: Int?
    var city: String? { didSet { UserDefaults.standard.set(city, forKey: "city") } }
    var status = "Определяю место…"
    var onChange: (() -> Void)?

    private let lm = CLLocationManager()
    private var coord: (Double, Double)? {
        didSet { if let c = coord { UserDefaults.standard.set([c.0, c.1], forKey: "coord") } }
    }

    func start() {
        city = UserDefaults.standard.string(forKey: "city")
        if let c = UserDefaults.standard.array(forKey: "coord") as? [Double], c.count == 2 { coord = (c[0], c[1]); fetch() }
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        if UserDefaults.standard.bool(forKey: "manualCity") { return }
        lm.requestWhenInUseAuthorization()
        lm.requestLocation()
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.fetch() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .denied, .restricted:
            if coord == nil { status = "Нет доступа к геопозиции.\nУкажите город в меню ▦"; onChange?() }
        case .notDetermined: break
        default: m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, !UserDefaults.standard.bool(forKey: "manualCity") else { return }
        coord = (l.coordinate.latitude, l.coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(l, preferredLocale: ru) { [weak self] p, _ in
            if let name = p?.first?.locality { self?.city = name; self?.onChange?() }
        }
        fetch()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if coord == nil { status = "Не удалось узнать место.\nУкажите город в меню ▦"; onChange?() }
    }

    func setCity(_ name: String) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1"), .init(name: "language", value: "ru")]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            guard let self, let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = (j["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
                DispatchQueue.main.async { self?.status = "Город «\(name)» не найден"; self?.onChange?() }
                return
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: "manualCity")
                self.city = r["name"] as? String ?? name
                self.coord = (lat, lon)
                self.fetch()
            }
        }.resume()
    }

    func useAutoLocation() {
        UserDefaults.standard.set(false, forKey: "manualCity")
        lm.requestWhenInUseAuthorization(); lm.requestLocation()
    }

    func fetch() {
        guard let (lat, lon) = coord else { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", lat)),
            .init(name: "longitude", value: String(format: "%.3f", lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "wind_speed_unit", value: "ms"), .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, err in
            guard let self else { return }
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = j["current"] as? [String: Any] else {
                DispatchQueue.main.async { if self.temp == nil { self.status = "Нет связи с сервером погоды" }; self.onChange?() }
                return
            }
            let daily = j["daily"] as? [String: Any]
            DispatchQueue.main.async {
                self.temp = cur["temperature_2m"] as? Double
                self.feels = cur["apparent_temperature"] as? Double
                self.code = cur["weather_code"] as? Int
                self.wind = cur["wind_speed_10m"] as? Double
                self.tmax = (daily?["temperature_2m_max"] as? [Double])?.first
                self.tmin = (daily?["temperature_2m_min"] as? [Double])?.first
                self.onChange?()
            }
        }.resume()
    }
}

func deg(_ v: Double?) -> String {
    guard let v else { return "–" }
    let r = Int(v.rounded())
    return (r < 0 ? "−\(-r)" : "\(r)") + "°"
}

var isNight: Bool { let h = Calendar.current.component(.hour, from: Date()); return h < 6 || h >= 18 }

func weatherInfo(_ code: Int?) -> (label: String, symbol: String) {
    let n = isNight
    switch code ?? -1 {
    case 0: return ("Ясно", n ? "moon.stars.fill" : "sun.max.fill")
    case 1, 2: return ("Переменная облачность", n ? "cloud.moon.fill" : "cloud.sun.fill")
    case 3: return ("Пасмурно", "cloud.fill")
    case 45, 48: return ("Туман", "cloud.fog.fill")
    case 51...67, 80...82: return ("Дождь", "cloud.rain.fill")
    case 71...77, 85, 86: return ("Снег", "cloud.snow.fill")
    case 95...99: return ("Гроза", "cloud.bolt.rain.fill")
    default: return ("—", "cloud.fill")
    }
}

// MARK: - Widget views

class WidgetView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    var pad: CGFloat { 20 }
}

final class ClockView: WidgetView {
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 150)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let now = Date()
        let f = DateFormatter(); f.locale = ru
        f.dateFormat = "HH:mm"
        text(f.string(from: now), NSPoint(x: pad - 3, y: 6), Style.font(76, .thin), Style.primary, kern: -2)
        f.dateFormat = "EEEE, d MMMM"
        text(cap(f.string(from: now)), NSPoint(x: pad, y: 104), Style.font(16, .medium), Style.secondary)

        // right column: week number + year progress ring
        let cal = Calendar(identifier: .iso8601)
        let week = cal.component(.weekOfYear, from: now)
        let year = cal.component(.year, from: now)
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let progress = now.timeIntervalSince(start) / end.timeIntervalSince(start)

        let c = NSPoint(x: bounds.width - pad - 34, y: 58)
        ring(center: c, radius: 30, width: 6, value: progress, colors: [Style.accent2, Style.accent])
        let pct = "\(Int((progress * 100).rounded()))%"
        let ps = measure(pct, Style.font(15, .semibold, rounded: true))
        text(pct, NSPoint(x: c.x - ps.width / 2, y: c.y - ps.height / 2), Style.font(15, .semibold, rounded: true), Style.primary)
        let lbl = "неделя \(week)"
        let ls = measure(lbl, Style.font(12, .medium))
        text(lbl, NSPoint(x: c.x - ls.width / 2, y: 104), Style.font(12, .medium), Style.tertiary)
    }
}

func ring(center c: NSPoint, radius: CGFloat, width: CGFloat, value: Double, colors: [NSColor]) {
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor.white.withAlphaComponent(0.14).setStroke(); track.stroke()
    let v = max(0.001, min(1, value))
    // flipped view: angles go clockwise from 3 o'clock; start at 12 o'clock
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: radius, startAngle: -90, endAngle: -90 + 360 * CGFloat(v), clockwise: false)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let outline = arc.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.addPath(outline); ctx.clip()
        let g = NSGradient(colors: colors)!
        g.draw(in: NSRect(x: c.x - radius - width, y: c.y - radius - width, width: 2 * (radius + width), height: 2 * (radius + width)), angle: 45)
    }
    NSGraphicsContext.restoreGraphicsState()
}

final class WeatherView: WidgetView {
    let w: WeatherService
    init(_ w: WeatherService) { self.w = w; super.init(frame: NSRect(x: 0, y: 0, width: 171, height: 171)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 16
        guard w.temp != nil else {
            symbol("location.slash", in: NSRect(x: p, y: p, width: 22, height: 22), size: 16, colors: [Style.secondary])
            var y: CGFloat = 50
            for line in w.status.split(separator: "\n") {
                let s = String(line)
                text(s, NSPoint(x: p, y: y), Style.font(12, .medium), Style.secondary); y += 18
            }
            return
        }
        let info = weatherInfo(w.code)
        let city = w.city ?? "Погода"
        symbol("location.fill", in: NSRect(x: p - 2, y: p + 1, width: 14, height: 14), size: 9, colors: [Style.primary])
        text(city, NSPoint(x: p + 13, y: p - 1), Style.font(14, .semibold), Style.primary)
        text(deg(w.temp), NSPoint(x: p - 2, y: 30), Style.font(52, .light), Style.primary, kern: -1)
        symbol(info.symbol, in: NSRect(x: p - 1, y: 102, width: 24, height: 24), size: 17, multicolor: true)
        text(info.label, NSPoint(x: p, y: 124), Style.font(12, .semibold), Style.primary)
        text("↑\(deg(w.tmax))  ↓\(deg(w.tmin))", NSPoint(x: p, y: 142), Style.font(12, .medium), Style.secondary)
    }
}

final class StatusView: WidgetView {
    let sys: SystemStats
    init(_ s: SystemStats) { sys = s; super.init(frame: NSRect(x: 0, y: 0, width: 171, height: 171)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 16
        text("Система", NSPoint(x: p, y: p - 1), Style.font(14, .semibold), Style.primary)

        let bat = sys.battery()
        let bpct = Double(bat?.pct ?? 100) / 100
        let low = (bat?.pct ?? 100) <= 20 && !(bat?.plugged ?? true)
        let batColors = low ? [NSColor(hex: 0xFF6B6B), NSColor(hex: 0xFFA94D)] : [NSColor(hex: 0x34D399), NSColor(hex: 0xA3E635)]
        let c1 = NSPoint(x: 46, y: 84), c2 = NSPoint(x: 125, y: 84)
        ring(center: c1, radius: 27, width: 7, value: bpct, colors: batColors)
        symbol(bat?.charging == true ? "bolt.fill" : "battery.100", in: NSRect(x: c1.x - 12, y: c1.y - 12, width: 24, height: 24),
               size: 15, weight: .semibold, colors: [Style.primary])
        ring(center: c2, radius: 27, width: 7, value: sys.cpu, colors: [Style.accent2, Style.accent])
        symbol("cpu", in: NSRect(x: c2.x - 12, y: c2.y - 12, width: 24, height: 24), size: 15, weight: .semibold, colors: [Style.primary])

        func label(_ big: String, _ small: String, _ x: CGFloat) {
            let bf = Style.font(15, .semibold, rounded: true), sf = Style.font(11, .medium)
            let bs = measure(big, bf), ss = measure(small, sf)
            text(big, NSPoint(x: x - bs.width / 2, y: 120), bf, Style.primary)
            text(small, NSPoint(x: x - ss.width / 2, y: 140), sf, Style.tertiary)
        }
        label(bat.map { "\($0.pct)%" } ?? "AC", bat?.charging == true ? "заряжается" : "батарея", c1.x)
        label("\(Int((sys.cpu * 100).rounded()))%", "процессор", c2.x)
    }
}

final class CalendarView: WidgetView {
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 190)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        var cal = Calendar(identifier: .gregorian); cal.locale = ru; cal.firstWeekday = 2
        let now = Date()
        let f = DateFormatter(); f.locale = ru

        // left: weekday + big day number
        f.dateFormat = "EEEE"
        text(f.string(from: now).uppercased(), NSPoint(x: pad, y: 18), Style.font(11, .bold), Style.accent, kern: 0.4)
        let day = cal.component(.day, from: now)
        text("\(day)", NSPoint(x: pad - 3, y: 32), Style.font(64, .light), Style.primary, kern: -2)
        f.dateFormat = "LLLL"
        text(cap(f.string(from: now)), NSPoint(x: pad, y: 118), Style.font(15, .semibold), Style.primary)
        f.dateFormat = "yyyy"
        text(f.string(from: now), NSPoint(x: pad, y: 138), Style.font(13, .medium), Style.tertiary)

        // right: month grid
        let cw: CGFloat = 27, ch: CGFloat = 23
        let gx = bounds.width - pad - 7 * cw, gy: CGFloat = 18
        let wd = ["П", "В", "С", "Ч", "П", "С", "В"]
        for (i, d) in wd.enumerated() {
            let s = measure(d, Style.font(11, .bold))
            text(d, NSPoint(x: gx + CGFloat(i) * cw + (cw - s.width) / 2, y: gy), Style.font(11, .bold),
                 i >= 5 ? Style.tertiary : Style.secondary)
        }
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let count = cal.range(of: .day, in: .month, for: now)!.count
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        for d in 1...count {
            let i = d - 1 + lead
            let x = gx + CGFloat(i % 7) * cw, y = gy + 22 + CGFloat(i / 7) * ch
            let font = Style.font(12, d == day ? .bold : .medium, rounded: true)
            let s = "\(d)", sz = measure(s, font)
            if d == day {
                let dot = NSRect(x: x + cw / 2 - 11, y: y + sz.height / 2 - 11, width: 22, height: 22)
                NSGradient(colors: [Style.accent2, Style.accent])!.draw(in: NSBezierPath(ovalIn: dot), angle: 45)
            }
            let col: NSColor = d == day ? NSColor(hex: 0x0B1020) : (i % 7 >= 5 ? Style.tertiary : Style.primary)
            text(s, NSPoint(x: x + (cw - sz.width) / 2, y: y), font, col)
        }
    }
}

// MARK: - Network


final class NetStats {
    private(set) var down: Double = 0, up: Double = 0          // bytes per second
    private(set) var latency: Double?                          // ms
    private(set) var latencies: [Double] = []                  // recent, for sparkline + jitter
    private(set) var rssi: Int?
    private(set) var measured = false
    private var prev: [String: (UInt32, UInt32)] = [:]
    private var prevTime: Date?
    private let q = DispatchQueue(label: "net.latency")

    var jitter: Double? {
        guard latencies.count >= 3 else { return nil }
        let d = zip(latencies.dropFirst(), latencies).map { abs($0 - $1) }
        return d.reduce(0, +) / Double(d.count)
    }

    func sampleTraffic() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        var cur: [String: (UInt32, UInt32)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let data = i.ifa_data else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let now = Date()
        if let t = prevTime {
            let dt = now.timeIntervalSince(t)
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (k, v) in cur { if let p = prev[k] { rx += UInt64(v.0 &- p.0); tx += UInt64(v.1 &- p.1) } }
            if dt > 0 { down = Double(rx) / dt; up = Double(tx) / dt }
        }
        prev = cur; prevTime = now
        rssi = CWWiFiClient.shared().interface()?.rssiValue()
        if rssi == 0 { rssi = nil }
    }

    /// TCP handshake time to Cloudflare DNS — a ping that needs no root.
    func measureLatency(_ done: @escaping () -> Void) {
        let start = Date()
        let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        var finished = false
        let finish: (Double?) -> Void = { [weak self] ms in
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async {
                guard let self else { return }
                self.measured = true
                self.latency = ms
                if let ms { self.latencies.append(ms); if self.latencies.count > 30 { self.latencies.removeFirst() } }
                done()
            }
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(Date().timeIntervalSince(start) * 1000)
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

// MARK: - External SSD

func cString<T>(_ t: T) -> String {
    withUnsafeBytes(of: t) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

final class DiskStats {
    let path: String
    let label: String
    private(set) var mounted = false
    private(set) var free: Int64 = 0, total: Int64 = 0
    private(set) var readBps: Double = 0, writeBps: Double = 0
    private(set) var interconnect: String?
    private var prev: (UInt64, UInt64, Date)?

    init(path: String, label: String) { self.path = path; self.label = label }

    func sample() {
        var st = statfs()
        guard statfs(path, &st) == 0, cString(st.f_mntonname) == path else {
            mounted = false; prev = nil; readBps = 0; writeBps = 0; return
        }
        mounted = true
        free = Int64(st.f_bavail) * Int64(st.f_bsize)
        total = Int64(st.f_blocks) * Int64(st.f_bsize)
        let bsd = cString(st.f_mntfromname).replacingOccurrences(of: "/dev/", with: "")
        guard let (r, w, ic) = DiskStats.ioCounters(bsd: bsd) else { return }
        interconnect = ic
        let now = Date()
        if let p = prev {
            let dt = now.timeIntervalSince(p.2)
            if dt > 0 { readBps = Double(r &- p.0) / dt; writeBps = Double(w &- p.1) / dt }
        }
        prev = (r, w, now)
    }

    /// Walks from the volume up to the physical disk's IOBlockStorageDriver and reads its byte counters.
    static func ioCounters(bsd: String) -> (UInt64, UInt64, String?)? {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard media != 0 else { return nil }
        var interconnect: String?
        if let pc = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Protocol Characteristics" as CFString,
                                                    kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any] {
            interconnect = pc["Physical Interconnect"] as? String
        }
        var entry = media
        while true {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                defer { IOObjectRelease(entry) }
                guard let s = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { return nil }
                let r = (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                let w = (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                return (r, w, interconnect)
            }
        }
    }
}

// MARK: - Git

struct RepoInfo {
    let name: String, branch: String
    let changed: Int, ahead: Int, behind: Int
    let lastActivity: Date
}

final class GitStats {
    let roots: [String]
    private(set) var repos: [RepoInfo] = []
    private(set) var note: String? = "Сканирую проекты…"
    private var busy = false

    init(roots: [String]) { self.roots = roots }

    func refresh(_ done: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var paths: [String] = []
            var missing = true
            for root in self.roots where fm.fileExists(atPath: root) {
                missing = false
                // root/<category>/<project> and root/<project>
                for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !a.hasPrefix(".") {
                    let pa = root + "/" + a
                    if fm.fileExists(atPath: pa + "/.git") { paths.append(pa); continue }
                    for b in (try? fm.contentsOfDirectory(atPath: pa)) ?? [] where !b.hasPrefix(".") {
                        let pb = pa + "/" + b
                        if fm.fileExists(atPath: pb + "/.git") { paths.append(pb) }
                    }
                }
            }
            let infos = paths.compactMap(GitStats.inspect)
                .sorted { ($0.changed + $0.ahead > 0 ? 1 : 0, $0.lastActivity) > ($1.changed + $1.ahead > 0 ? 1 : 0, $1.lastActivity) }
            DispatchQueue.main.async {
                self.repos = infos
                self.note = missing ? "SSD KASHTAN не подключён" : (infos.isEmpty ? "Репозитории не найдены" : nil)
                self.busy = false
                done()
            }
        }
    }

    private static func git(_ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "--no-optional-locks"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private static func inspect(_ path: String) -> RepoInfo? {
        guard let out = git(["status", "--porcelain=v2", "--branch"], in: path) else { return nil }
        var branch = "?", changed = 0, ahead = 0, behind = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                ahead = Int(parts.first?.dropFirst() ?? "") ?? 0
                behind = Int(parts.last?.dropFirst() ?? "") ?? 0
            } else if !line.hasPrefix("#") { changed += 1 }
        }
        let ct = git(["log", "-1", "--format=%ct"], in: path).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let last = ct.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        return RepoInfo(name: (path as NSString).lastPathComponent, branch: branch,
                        changed: changed, ahead: ahead, behind: behind, lastActivity: last)
    }
}

// MARK: - Pomodoro

final class Pomodoro {
    enum Phase { case focus, short, long
        var minutes: Double { switch self { case .focus: 25; case .short: 5; case .long: 15 } }
        var title: String { switch self { case .focus: "Фокус"; case .short: "Перерыв"; case .long: "Длинный перерыв" } }
    }
    private(set) var phase: Phase = .focus
    private(set) var remaining: TimeInterval = 25 * 60
    private(set) var running = false
    private var end: Date?
    private var streak = 0   // focus sessions since the last long break

    var doneToday: Int {
        get {
            let d = UserDefaults.standard
            return d.string(forKey: "pomo.day") == Pomodoro.today ? d.integer(forKey: "pomo.count") : 0
        }
        set {
            UserDefaults.standard.set(Pomodoro.today, forKey: "pomo.day")
            UserDefaults.standard.set(newValue, forKey: "pomo.count")
        }
    }
    static var today: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }
    var progress: Double { 1 - remaining / (phase.minutes * 60) }

    func toggle() {
        if running { remaining = max(0, end!.timeIntervalSinceNow); running = false; end = nil }
        else { end = Date().addingTimeInterval(remaining); running = true }
    }

    func reset() { running = false; end = nil; phase = .focus; remaining = phase.minutes * 60 }

    func tick() {
        guard running, let end else { return }
        remaining = max(0, end.timeIntervalSinceNow)
        guard remaining == 0 else { return }
        running = false; self.end = nil
        NSSound(named: "Glass")?.play()
        if phase == .focus {
            doneToday += 1; streak += 1
            phase = streak % 4 == 0 ? .long : .short
        } else { phase = .focus }
        remaining = phase.minutes * 60
    }
}

// MARK: - Model training

struct TrainStatus: Decodable {
    let name: String?
    let epoch: Int?, epochs: Int?
    let step: Int?, steps: Int?
    let loss: Double?, val_loss: Double?
    let metric: String?, metric_value: Double?
    let started: Double?, updated: Double?
    let done: Bool?
    let history: [Double]?
}

final class TrainWatcher {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/train-widget/status.json")
    private(set) var status: TrainStatus?
    private var lastMod: Date?

    /// Returns true when something changed.
    func poll() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: TrainWatcher.file.path),
              let mod = attrs[.modificationDate] as? Date else {
            let had = status != nil; status = nil; lastMod = nil; return had
        }
        guard mod != lastMod else { return false }
        lastMod = mod
        status = (try? Data(contentsOf: TrainWatcher.file)).flatMap { try? JSONDecoder().decode(TrainStatus.self, from: $0) }
        return true
    }

    var isLive: Bool {
        guard let s = status, s.done != true, let u = s.updated else { return false }
        return Date().timeIntervalSince1970 - u < 120
    }

    var progress: Double? {
        guard let s = status, let e = s.epoch, let n = s.epochs, n > 0 else { return nil }
        let within = (s.steps ?? 0) > 0 ? Double(s.step ?? 0) / Double(s.steps!) : 0
        if s.done == true { return 1 }
        return min(1, (Double(e - 1) + within) / Double(n))
    }

    var eta: TimeInterval? {
        guard isLive, let p = progress, p > 0.01, let st = status?.started else { return nil }
        let elapsed = Date().timeIntervalSince1970 - st
        return elapsed / p - elapsed
    }
}

// MARK: - New widgets

func fmtRate(_ bps: Double, bits: Bool) -> String {
    let v = bits ? bps * 8 : bps
    let u = bits ? ["бит/с", "Кбит/с", "Мбит/с", "Гбит/с"] : ["Б/с", "КБ/с", "МБ/с", "ГБ/с"]
    var x = v, i = 0
    while x >= 1000 && i < u.count - 1 { x /= 1000; i += 1 }
    return (x < 10 && i > 0 ? String(format: "%.1f", x) : String(Int(x.rounded()))) + " " + u[i]
}

func fmtBytes(_ b: Int64) -> String {
    let gb = Double(b) / 1e9
    return gb >= 1000 ? String(format: "%.1f ТБ", gb / 1000) : "\(Int(gb.rounded())) ГБ"
}

func sparkline(_ vals: [Double], in r: NSRect, colors: [NSColor]) {
    guard vals.count >= 2, let lo = vals.min(), let hi = vals.max() else { return }
    let span = max(hi - lo, 1e-9)
    let path = NSBezierPath()
    for (i, v) in vals.enumerated() {
        let p = NSPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(vals.count - 1),
                        y: r.maxY - r.height * CGFloat((v - lo) / span))
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.lineWidth = 2; path.lineJoinStyle = .round; path.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.addPath(path.cgPath.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        ctx.clip()
        NSGradient(colors: colors)!.draw(in: r.insetBy(dx: -2, dy: -2), angle: 0)
    }
    NSGraphicsContext.restoreGraphicsState()
}

func bar(_ r: NSRect, value: Double, colors: [NSColor]) {
    NSColor.white.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    let f = NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * CGFloat(min(1, max(0, value)))), height: r.height)
    NSGradient(colors: colors)!.draw(in: NSBezierPath(roundedRect: f, xRadius: r.height / 2, yRadius: r.height / 2), angle: 0)
}

func header(_ title: String, _ sym: String, at p: NSPoint) {
    symbol(sym, in: NSRect(x: p.x - 2, y: p.y, width: 18, height: 18), size: 12, weight: .semibold, colors: [Style.secondary])
    text(title, NSPoint(x: p.x + 18, y: p.y - 1), Style.font(14, .semibold), Style.primary)
}

final class PomodoroView: WidgetView {
    let pomo: Pomodoro
    private var downEvent: NSEvent?
    private var dragged = false
    init(_ p: Pomodoro) { pomo = p; super.init(frame: NSRect(x: 0, y: 0, width: 171, height: 171)) }
    required init?(coder: NSCoder) { fatalError() }

    // click = start/pause, double click = reset, drag = move the widget
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        downEvent = e; dragged = false
        if e.clickCount == 2 { pomo.reset(); needsDisplay = true }
    }
    override func mouseDragged(with e: NSEvent) {
        if !dragged, let d = downEvent { dragged = true; window?.performDrag(with: d) }
    }
    override func mouseUp(with e: NSEvent) {
        if !dragged && e.clickCount == 1 { pomo.toggle(); needsDisplay = true }
    }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 16
        let focus = pomo.phase == .focus
        let colors = focus ? [NSColor(hex: 0xFF8A65), NSColor(hex: 0xF43F5E)] : [Style.accent, NSColor(hex: 0x34D399)]
        text(pomo.phase.title, NSPoint(x: p, y: p - 1), Style.font(14, .semibold), Style.primary)
        let c = NSPoint(x: bounds.midX, y: 86)
        ring(center: c, radius: 42, width: 7, value: pomo.progress, colors: colors)
        let m = Int(pomo.remaining) / 60, s = Int(pomo.remaining) % 60
        let t = String(format: "%02d:%02d", m, s)
        let tf = Style.font(22, .medium, rounded: true)
        let ts = measure(t, tf)
        text(t, NSPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2 - 4), tf, Style.primary)
        let hint = pomo.running ? "пауза — клик" : "старт — клик"
        let hf = Style.font(10, .medium), hs = measure(hint, hf)
        text(hint, NSPoint(x: c.x - hs.width / 2, y: c.y + 12), hf, Style.tertiary)
        let done = "Сегодня: \(pomo.doneToday)"
        text(done, NSPoint(x: p, y: 142), Style.font(12, .medium), Style.secondary)
        symbol(pomo.running ? "pause.fill" : "play.fill", in: NSRect(x: bounds.width - p - 16, y: p, width: 16, height: 16),
               size: 11, colors: [colors[1]])
    }
}

final class NetDiskView: WidgetView {
    let net: NetStats, disk: DiskStats
    init(_ n: NetStats, _ d: DiskStats) { net = n; disk = d; super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 171)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 18, mid = bounds.width / 2
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: mid, y: 18, width: 1, height: bounds.height - 36).fill()

        // --- internet
        header("Интернет", "network", at: NSPoint(x: p, y: p))
        let (qText, qColor): (String, NSColor) = {
            guard net.measured else { return ("Проверяю…", Style.secondary) }
            guard let l = net.latency else { return ("Нет сети", NSColor(hex: 0xFF6B6B)) }
            switch l {
            case ..<40: return ("Отличная", NSColor(hex: 0x34D399))
            case ..<90: return ("Хорошая", NSColor(hex: 0xA3E635))
            case ..<180: return ("Средняя", NSColor(hex: 0xFBBF24))
            default: return ("Слабая", NSColor(hex: 0xFF6B6B))
            }
        }()
        text(qText, NSPoint(x: p, y: 42), Style.font(20, .semibold), qColor)
        var info = net.latency.map { "\(Int($0.rounded())) мс" } ?? "—"
        if let j = net.jitter { info += " · ±\(Int(j.rounded()))" }
        text(info, NSPoint(x: p, y: 70), Style.font(12, .medium), Style.secondary)
        if let rssi = net.rssi {
            let v = rssi > -55 ? 1.0 : rssi > -67 ? 0.66 : rssi > -75 ? 0.33 : 0.05
            if let img = NSImage(systemSymbolName: "wifi", variableValue: v, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Style.primary]))) {
                img.draw(in: NSRect(x: mid - 34, y: 20, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        sparkline(net.latencies, in: NSRect(x: p, y: 92, width: mid - 2 * p, height: 22), colors: [Style.accent2, Style.accent])
        text("↓ " + fmtRate(net.down, bits: true), NSPoint(x: p, y: 122), Style.font(12, .semibold, rounded: true), Style.primary)
        text("↑ " + fmtRate(net.up, bits: true), NSPoint(x: p, y: 140), Style.font(12, .semibold, rounded: true), Style.secondary)

        // --- SSD
        let x = mid + p
        header(disk.label, "externaldrive.fill", at: NSPoint(x: x, y: p))
        guard disk.mounted else {
            text("Не подключён", NSPoint(x: x, y: 42), Style.font(20, .semibold), Style.tertiary)
            text("Подключите диск —", NSPoint(x: x, y: 74), Style.font(12, .medium), Style.tertiary)
            text("данные появятся сами", NSPoint(x: x, y: 92), Style.font(12, .medium), Style.tertiary)
            return
        }
        text("Подключён", NSPoint(x: x, y: 42), Style.font(20, .semibold), NSColor(hex: 0x34D399))
        let ic = disk.interconnect.map { $0 == "PCI-Express" ? "PCIe" : $0 } ?? "—"
        text(ic, NSPoint(x: x, y: 70), Style.font(12, .medium), Style.secondary)
        let used = disk.total > 0 ? 1 - Double(disk.free) / Double(disk.total) : 0
        bar(NSRect(x: x, y: 96, width: mid - 2 * p, height: 6), value: used, colors: [Style.accent2, Style.accent])
        text("\(fmtBytes(disk.free)) свободно из \(fmtBytes(disk.total))", NSPoint(x: x, y: 106), Style.font(11, .medium), Style.tertiary)
        text("R " + fmtRate(disk.readBps, bits: false), NSPoint(x: x, y: 122), Style.font(12, .semibold, rounded: true), Style.primary)
        text("W " + fmtRate(disk.writeBps, bits: false), NSPoint(x: x, y: 140), Style.font(12, .semibold, rounded: true), Style.secondary)
    }
}

final class GitView: WidgetView {
    let git: GitStats
    static let rows = 6
    init(_ g: GitStats) { git = g; super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 214)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 18
        header("Git", "arrow.triangle.branch", at: NSPoint(x: p, y: p))
        let dirty = git.repos.filter { $0.changed + $0.ahead > 0 }.count
        if !git.repos.isEmpty {
            let s = dirty == 0 ? "всё закоммичено" : "\(dirty) требуют внимания"
            let f = Style.font(12, .medium), w = measure(s, f).width
            text(s, NSPoint(x: bounds.width - p - w, y: p), f, dirty == 0 ? NSColor(hex: 0x34D399) : NSColor(hex: 0xFBBF24))
        }
        if let note = git.note {
            text(note, NSPoint(x: p, y: 52), Style.font(14, .medium), Style.tertiary)
            return
        }
        for (i, repo) in git.repos.prefix(GitView.rows).enumerated() {
            let y = 48 + CGFloat(i) * 26
            let color: NSColor = repo.changed > 0 ? NSColor(hex: 0xFBBF24) : repo.ahead > 0 ? NSColor(hex: 0x60A5FA) : NSColor(hex: 0x34D399)
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: p, y: y + 6, width: 8, height: 8)).fill()
            let nf = Style.font(13, .semibold)
            let nw = min(measure(repo.name, nf).width, 150)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: p + 16, y: y, width: 150, height: 22).clip()
            text(repo.name, NSPoint(x: p + 16, y: y), nf, Style.primary)
            NSGraphicsContext.restoreGraphicsState()
            text(repo.branch, NSPoint(x: p + 24 + nw, y: y + 1), Style.font(12, .medium), Style.tertiary)
            var right: [String] = []
            if repo.changed > 0 { right.append("✎\(repo.changed)") }
            if repo.ahead > 0 { right.append("↑\(repo.ahead)") }
            if repo.behind > 0 { right.append("↓\(repo.behind)") }
            let rs = right.isEmpty ? "✓" : right.joined(separator: "  ")
            let rf = Style.font(12, .semibold, rounded: true), rw = measure(rs, rf).width
            text(rs, NSPoint(x: bounds.width - p - rw, y: y + 1), rf, right.isEmpty ? Style.tertiary : Style.primary)
        }
    }
}

final class TrainView: WidgetView {
    let tw: TrainWatcher
    init(_ t: TrainWatcher) { tw = t; super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 150)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let p: CGFloat = 18
        header("Обучение", "brain", at: NSPoint(x: p, y: p))
        guard let s = tw.status else {
            text("Нет активного обучения", NSPoint(x: p, y: 50), Style.font(16, .semibold), Style.tertiary)
            text("Добавьте train_widget.py в цикл обучения —", NSPoint(x: p, y: 78), Style.font(12, .medium), Style.tertiary)
            text("прогресс появится здесь", NSPoint(x: p, y: 96), Style.font(12, .medium), Style.tertiary)
            return
        }
        let live = tw.isLive
        let state = s.done == true ? "готово ✓" : live ? "идёт" : "остановлено"
        let sf = Style.font(12, .medium), sw = measure(state, sf).width
        text(state, NSPoint(x: bounds.width - p - sw, y: p), sf,
             s.done == true ? NSColor(hex: 0x34D399) : live ? Style.accent : NSColor(hex: 0xFBBF24))

        let c = NSPoint(x: p + 40, y: 88)
        let prog = tw.progress ?? 0
        ring(center: c, radius: 36, width: 7, value: prog, colors: [Style.accent2, Style.accent])
        let pt = "\(Int((prog * 100).rounded()))%", pf = Style.font(17, .semibold, rounded: true), ps = measure(pt, pf)
        text(pt, NSPoint(x: c.x - ps.width / 2, y: c.y - ps.height / 2), pf, Style.primary)

        let x = p + 96
        text(s.name ?? "модель", NSPoint(x: x, y: 44), Style.font(15, .semibold), Style.primary)
        var line = ""
        if let e = s.epoch, let n = s.epochs { line = "Эпоха \(e)/\(n)" }
        if let eta = tw.eta {
            let m = Int(eta / 60)
            line += (line.isEmpty ? "" : " · ") + (m >= 60 ? "~\(m / 60) ч \(m % 60) мин" : "~\(max(m, 1)) мин")
        }
        text(line, NSPoint(x: x, y: 66), Style.font(12, .medium), Style.secondary)
        var metrics: [String] = []
        if let l = s.loss { metrics.append(String(format: "loss %.4f", l)) }
        if let v = s.val_loss { metrics.append(String(format: "val %.4f", v)) }
        if let m = s.metric, let mv = s.metric_value { metrics.append(String(format: "%@ %.3f", m, mv)) }
        text(metrics.joined(separator: "  "), NSPoint(x: x, y: 84), Style.font(12, .semibold, rounded: true), Style.primary)
        sparkline(s.history ?? [], in: NSRect(x: x, y: 106, width: bounds.width - x - p, height: 26),
                  colors: [Style.accent, Style.accent2])
    }
}

// MARK: - Glass windows

/// Self-drawn translucency (tint + sheen + hairline). No system blur, so nothing
/// flashes opaque while switching Spaces.
enum Glass: Int { case clear = 0, medium, frosted
    var tint: CGFloat { [0.12, 0.26, 0.44][rawValue] }
    var title: String { ["Почти прозрачное", "Полупрозрачное", "Плотное"][rawValue] }
}

final class WidgetWindow: NSWindow {
    let key: String
    private let tintLayer = CALayer()

    init(view: WidgetView, key: String, defaultOrigin: NSPoint) {
        self.key = key
        let size = view.frame.size
        super.init(contentRect: NSRect(origin: defaultOrigin, size: size), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let l = root.layer!
        l.cornerRadius = Style.radius
        l.cornerCurve = .continuous
        l.masksToBounds = true

        tintLayer.frame = root.bounds
        tintLayer.backgroundColor = NSColor(hex: 0x0B1220).cgColor
        l.addSublayer(tintLayer)

        let sheen = CAGradientLayer()
        sheen.frame = root.bounds
        sheen.colors = [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0.02).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        sheen.locations = [0, 0.45, 1]
        sheen.startPoint = CGPoint(x: 0, y: 1); sheen.endPoint = CGPoint(x: 0.9, y: 0)
        l.addSublayer(sheen)

        let border = CAGradientLayer()   // brighter top edge, fading down
        border.frame = root.bounds
        border.colors = [NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.white.withAlphaComponent(0.10).cgColor]
        border.startPoint = CGPoint(x: 0.5, y: 1); border.endPoint = CGPoint(x: 0.5, y: 0)
        let mask = CAShapeLayer()
        let outer = CGPath(roundedRect: root.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Style.radius - 0.5,
                           cornerHeight: Style.radius - 0.5, transform: nil)
        mask.path = outer.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        border.mask = mask
        l.addSublayer(border)

        view.frame = root.bounds
        root.addSubview(view)
        contentView = root

        if let p = UserDefaults.standard.array(forKey: "pos.\(key)") as? [Double], p.count == 2 {
            setFrameOrigin(NSPoint(x: p[0], y: p[1]))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    @objc private func moved() { UserDefaults.standard.set([frame.origin.x, frame.origin.y], forKey: "pos.\(key)") }

    var widget: NSView? { contentView?.subviews.last }
    func apply(_ g: Glass) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tintLayer.opacity = Float(g.tint)
        CATransaction.commit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sys = SystemStats()
    let weather = WeatherService()
    let net = NetStats()
    let disk = DiskStats(path: "/Volumes/KASHTAN", label: "SSD KASHTAN")
    let gitStats = GitStats(roots: ["/Volumes/KASHTAN/projects"])
    let pomo = Pomodoro()
    let train = TrainWatcher()
    var widgets: [(title: String, window: WidgetWindow)] = []
    var statusItem: NSStatusItem!
    var tickCount = 0
    var glass: Glass {
        get { Glass(rawValue: UserDefaults.standard.object(forKey: "glass") as? Int ?? 1) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "glass") }
    }

    /// Two columns on the right; the outer one keeps the original four widgets.
    func defaultOrigins() -> [String: NSPoint] {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let gap: CGFloat = 14, w: CGFloat = 356
        let x1 = vf.maxX - 24 - w, x2 = x1 - gap - w
        var o: [String: NSPoint] = [:]
        var y = vf.maxY - 24 - 150
        o["clock"] = NSPoint(x: x1, y: y)
        y -= gap + 171
        o["weather"] = NSPoint(x: x1, y: y); o["status"] = NSPoint(x: x1 + 171 + gap, y: y)
        y -= gap + 190
        o["calendar"] = NSPoint(x: x1, y: y)
        y -= gap + 171
        o["pomodoro"] = NSPoint(x: x1, y: y)
        var y2 = vf.maxY - 24 - 171
        o["netdisk"] = NSPoint(x: x2, y: y2)
        y2 -= gap + 214
        o["git"] = NSPoint(x: x2, y: y2)
        y2 -= gap + 150
        o["train"] = NSPoint(x: x2, y: y2)
        return o
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        sys.sampleCPU(); net.sampleTraffic(); disk.sample(); _ = train.poll()
        let origins = defaultOrigins()
        let views: [(String, String, WidgetView)] = [
            ("Часы", "clock", ClockView()), ("Погода", "weather", WeatherView(weather)),
            ("Система", "status", StatusView(sys)), ("Календарь", "calendar", CalendarView()),
            ("Помодоро", "pomodoro", PomodoroView(pomo)), ("Сеть и SSD", "netdisk", NetDiskView(net, disk)),
            ("Git", "git", GitView(gitStats)), ("Обучение", "train", TrainView(train)),
        ]
        for (title, key, v) in views {
            let win = WidgetWindow(view: v, key: key, defaultOrigin: origins[key]!)
            win.apply(glass)
            if !UserDefaults.standard.bool(forKey: "hidden.\(key)") { win.orderFrontRegardless() }
            widgets.append((title, win))
        }
        weather.onChange = { [weak self] in self?.redraw("weather") }
        weather.start()
        gitStats.refresh { [weak self] in self?.redraw("git") }
        net.measureLatency { [weak self] in self?.redraw("netdisk") }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Виджеты")
        refreshMenu()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func redraw(_ key: String) { widgets.first { $0.window.key == key }?.window.widget?.needsDisplay = true }

    func tick() {
        tickCount += 1
        if Calendar.current.component(.second, from: Date()) == 0 { redraw("clock") }
        pomo.tick(); redraw("pomodoro")
        if tickCount % 2 == 0 {
            sys.sampleCPU(); redraw("status")
            net.sampleTraffic(); disk.sample(); redraw("netdisk")
        }
        if tickCount % 10 == 0 { net.measureLatency { [weak self] in self?.redraw("netdisk") } }
        if tickCount % 5 == 0, train.poll() || train.isLive { redraw("train") }
        if tickCount % 60 == 0 {
            redraw("calendar"); redraw("weather"); redraw("train")
            gitStats.refresh { [weak self] in self?.redraw("git") }
        }
    }

    @objc func toggleWidget(_ item: NSMenuItem) {
        let w = widgets[item.tag].window
        let hide = w.isVisible
        hide ? w.orderOut(nil) : w.orderFrontRegardless()
        UserDefaults.standard.set(hide, forKey: "hidden.\(w.key)")
        refreshMenu()
    }

    @objc func setGlass(_ item: NSMenuItem) {
        glass = Glass(rawValue: item.tag) ?? .medium
        widgets.forEach { $0.window.apply(glass) }
        refreshMenu()
    }

    @objc func askCity() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Город для погоды"
        a.informativeText = "Например: Алматы, Астана, Москва"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = weather.city ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "Сохранить"); a.addButton(withTitle: "Отмена")
        if a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { weather.setCity(field.stringValue) }
    }

    @objc func autoLocation() { weather.useAutoLocation() }
    @objc func refreshGit() { gitStats.refresh { [weak self] in self?.redraw("git") } }
    @objc func resetPomodoro() { pomo.reset(); redraw("pomodoro") }

    @objc func resetPositions() {
        let o = defaultOrigins()
        for (_, w) in widgets { if let p = o[w.key] { w.setFrameOrigin(p) } }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Не получилось изменить автозапуск"
            a.informativeText = error.localizedDescription; a.runModal()
        }
        refreshMenu()
    }

    func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, w) in widgets.enumerated() {
            let it = NSMenuItem(title: w.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            it.tag = i; it.target = self; it.state = w.window.isVisible ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let glassItem = NSMenuItem(title: "Прозрачность", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for g in [Glass.clear, .medium, .frosted] {
            let it = NSMenuItem(title: g.title, action: #selector(setGlass(_:)), keyEquivalent: "")
            it.tag = g.rawValue; it.target = self; it.state = g == glass ? .on : .off
            sub.addItem(it)
        }
        glassItem.submenu = sub
        menu.addItem(glassItem)
        @discardableResult func item(_ t: String, _ s: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; menu.addItem(i); return i
        }
        item("Сбросить помодоро", #selector(resetPomodoro))
        item("Обновить Git", #selector(refreshGit))
        item("Указать город…", #selector(askCity))
        item("Определять место автоматически", #selector(autoLocation))
        item("Вернуть виджеты на место", #selector(resetPositions))
        menu.addItem(.separator())
        item("Запускать при входе", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
