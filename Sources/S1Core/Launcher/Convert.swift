import Synchronization
import Foundation

/// "100 usd to idr", "5 km in mi", "70f to c", "2 gb mb" — units via
/// Foundation `Measurement`, currencies via ECB reference rates (`FX`).
public enum Convert {
    public struct Query: Equatable, Sendable {
        public var amount: Double
        public var from: String
        public var to: String
    }

    public static func parse(_ s: String) -> Query? {
        let q = s.lowercased().replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let re = /^([0-9]*\.?[0-9]+)?\s*([a-z°$€£¥]+)\s+(?:to|in|into|->|=|ke)?\s*([a-z°$€£¥]+)$/
        guard let m = try? re.wholeMatch(in: q) else {
            // "100usd to idr" / "70f to c" — number glued to the unit.
            let glued = /^([0-9]*\.?[0-9]+)([a-z°$€£¥]+)\s+(?:to|in|into|->|=|ke)\s+([a-z°$€£¥]+)$/
            guard let g = try? glued.wholeMatch(in: q) else { return nil }
            return Query(amount: Double(g.1) ?? 1, from: String(g.2), to: String(g.3))
        }
        return Query(amount: m.1.flatMap { Double($0) } ?? 1, from: String(m.2), to: String(m.3))
    }

    // MARK: units

    static let units: [String: (kind: String, unit: Dimension)] = {
        var u: [String: (String, Dimension)] = [:]
        func add(_ kind: String, _ d: Dimension, _ names: String...) { names.forEach { u[$0] = (kind, d) } }
        add("len", UnitLength.meters, "m", "meter", "meters", "metre", "metres", "meter")
        add("len", UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add("len", UnitLength.centimeters, "cm", "centimeter", "centimeters")
        add("len", UnitLength.millimeters, "mm", "millimeter", "millimeters")
        add("len", UnitLength.miles, "mi", "mile", "miles")
        add("len", UnitLength.feet, "ft", "foot", "feet")
        add("len", UnitLength.inches, "in", "inch", "inches")
        add("len", UnitLength.yards, "yd", "yard", "yards")
        add("mass", UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add("mass", UnitMass.grams, "g", "gram", "grams")
        add("mass", UnitMass.milligrams, "mg")
        add("mass", UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add("mass", UnitMass.ounces, "oz", "ounce", "ounces")
        add("temp", UnitTemperature.celsius, "c", "°c", "celsius")
        add("temp", UnitTemperature.fahrenheit, "f", "°f", "fahrenheit")
        add("temp", UnitTemperature.kelvin, "k", "kelvin")
        add("vol", UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add("vol", UnitVolume.milliliters, "ml")
        add("vol", UnitVolume.gallons, "gal", "gallon", "gallons")
        add("vol", UnitVolume.cups, "cup", "cups")
        add("vol", UnitVolume.fluidOunces, "floz")
        add("speed", UnitSpeed.kilometersPerHour, "kph", "kmh")
        add("speed", UnitSpeed.milesPerHour, "mph")
        add("speed", UnitSpeed.metersPerSecond, "mps")
        add("data", UnitInformationStorage.bytes, "b", "byte", "bytes")
        add("data", UnitInformationStorage.kilobytes, "kb")
        add("data", UnitInformationStorage.megabytes, "mb")
        add("data", UnitInformationStorage.gigabytes, "gb")
        add("data", UnitInformationStorage.terabytes, "tb")
        add("time", UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add("time", UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add("time", UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        return u
    }()

    // MARK: user extensions (~/.s1/convert.json)

    /// Aliases the user adds on top of the shipped tables — the file is a
    /// plain object so "editable conversions" needs no code change:
    ///   { "units": { "kms": "km", "click": "km" },
    ///     "currencies": { "dolar": "usd", "bucks": "usd" } }
    /// A unit alias must point at an existing unit name; a currency alias
    /// at a known ISO code. `s1 doctor` flags entries that resolve nowhere.
    public struct Extensions: Codable, Sendable {
        public var units: [String: String]?
        public var currencies: [String: String]?
        public init(units: [String: String]? = nil, currencies: [String: String]? = nil) {
            self.units = units; self.currencies = currencies
        }
    }

    public static var extensionsPath: URL {
        URL(fileURLWithPath: S1Home.path + "/convert.json")
    }

    /// mtime-checked cache — the launcher calls this per keystroke, so the
    /// file is only re-read when it actually changed on disk.
    private static let extCache = Mutex<(mtime: Date?, ext: Extensions)?>(nil)

    public static func extensions() -> Extensions {
        let p = extensionsPath.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if let c = extCache.withLock({ $0 }), c.mtime == mtime { return c.ext }
        let ext = (try? Data(contentsOf: extensionsPath))
            .flatMap { try? JSONDecoder().decode(Extensions.self, from: $0) }
            ?? Extensions()
        extCache.withLock { $0 = (mtime, ext) }
        return ext
    }

    /// Drop the cached parse — call after writing convert.json so the next
    /// lookup sees the new aliases without an app restart.
    public static func reloadExtensions() {
        extCache.withLock { $0 = nil }
    }

    /// Unit lookup: builtin table first, then a user alias resolving to a
    /// builtin name (aliases of aliases are not followed — one hop only).
    /// `ext` overrides the file load — tests inject their own aliases.
    static func unitEntry(_ token: String, ext: Extensions? = nil)
        -> (kind: String, unit: Dimension)? {
        if let u = units[token] { return u }
        guard let target = (ext ?? extensions()).units?[token] else { return nil }
        return units[target]
    }

    /// Entries that resolve nowhere — doctor findings.
    public static func validateExtensions(_ ext: Extensions) -> [String] {
        var issues: [String] = []
        for (alias, target) in ext.units ?? [:] where units[target] == nil {
            issues.append("unit alias '\(alias)' -> '\(target)': no such unit "
                + "(pick an existing name, e.g. km, mi, kg, lb, c, f, l, gal, mb, h)")
        }
        for (alias, target) in ext.currencies ?? [:] where !FX.known.contains(target.uppercased()) {
            issues.append("currency alias '\(alias)' -> '\(target)': unknown ISO code")
        }
        return issues
    }

    public static func units(_ q: Query, ext: Extensions? = nil) -> Double? {
        guard let a = unitEntry(q.from, ext: ext),
              let b = unitEntry(q.to, ext: ext), a.kind == b.kind else { return nil }
        return Measurement(value: q.amount, unit: a.unit).converted(to: b.unit).value
    }

    // MARK: currencies

    static let aliases: [String: String] = [
        "$": "USD", "dollar": "USD", "dollars": "USD", "€": "EUR", "euro": "EUR", "euros": "EUR",
        "£": "GBP", "pound sterling": "GBP", "¥": "JPY", "yen": "JPY", "rupiah": "IDR", "rp": "IDR",
        "ringgit": "MYR", "baht": "THB", "won": "KRW", "yuan": "CNY", "rmb": "CNY", "rupee": "INR",
        "rupees": "INR", "peso": "PHP", "pesos": "PHP", "franc": "CHF",
    ]

    public static func currency(_ token: String, ext: Extensions? = nil) -> String? {
        if let a = aliases[token] { return a }
        if let a = (ext ?? extensions()).currencies?[token], FX.known.contains(a.uppercased()) {
            return a.uppercased()
        }
        let up = token.uppercased()
        return FX.known.contains(up) ? up : nil
    }

    public static func money(_ q: Query, rates: FX.Rates) -> Double? {
        guard let f = currency(q.from), let t = currency(q.to), f != t,
              let rf = rates.rate(f), let rt = rates.rate(t) else { return nil }
        return q.amount / rf * rt
    }

    public static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) >= 100 ? 2 : abs(v) >= 1 ? 4 : 6
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// The launcher row for a conversion, or nil. `rates` nil + a currency
    /// pair = nothing yet (the app refreshes rates and re-searches).
    public static func item(_ s: String, rates: FX.Rates?) -> LauncherItem? {
        guard let q = parse(s) else { return nil }
        let amt = format(q.amount)
        if let v = units(q), let a = unitEntry(q.from), let b = unitEntry(q.to) {
            let fu = MeasurementFormatter(), raw = format(v)
            fu.unitOptions = .providedUnit
            return LauncherItem(kind: .calc, title: "\(amt) \(fu.string(from: a.unit)) = \(raw) \(fu.string(from: b.unit))",
                                subtitle: "Unit conversion · Enter copies \(raw)", payload: raw.replacingOccurrences(of: ",", with: ""))
        }
        if let rates, let v = money(q, rates: rates), let f = currency(q.from), let t = currency(q.to) {
            let raw = format(v)
            return LauncherItem(kind: .calc, title: "\(amt) \(f) = \(raw) \(t)",
                                subtitle: "ECB reference rate \(rates.date) via frankfurter.dev · Enter copies",
                                payload: raw.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
}

/// ECB daily reference rates via Frankfurter (open source, no key), cached
/// in ~/.s1/fx.json for 12 h. No query text is sent — only "latest rates".
public enum FX {
    public struct Rates: Codable, Sendable, Equatable {
        public var base: String
        public var date: String
        public var rates: [String: Double]
        public var fetched: Date?
        public func rate(_ code: String) -> Double? { code == base ? 1 : rates[code] }
    }

    public static let known: Set<String> = [
        "AUD", "BGN", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS",
        "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB",
        "TRY", "USD", "ZAR",
    ]
    public static var path: URL { URL(fileURLWithPath: S1Home.path + "/fx.json") }
    public static let url = URL(string: "https://api.frankfurter.dev/v1/latest")!

    public static func cached() -> Rates? {
        guard let d = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Rates.self, from: d)
    }

    public static func isStale(_ r: Rates?, now: Date = Date()) -> Bool {
        guard let f = r?.fetched else { return true }
        return now.timeIntervalSince(f) > 12 * 3600
    }

    public static func refresh() async -> Rates? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              var r = try? JSONDecoder().decode(Rates.self, from: d) else { return cached() }
        r.fetched = Date()
        S1Home.ensurePrivate()
        try? JSONEncoder().encode(r).write(to: path, options: .atomic)
        return r
    }
}

/// Spotlight-index file search (`mdfind`, argv — no shell), home folder.
public enum FileSearch {
    public static func predicate(_ q: String) -> String? {
        let clean = q.filter { !"'\"\\*".contains($0) }.trimmingCharacters(in: .whitespaces)
        guard clean.count >= 2 else { return nil }
        return "kMDItemDisplayName == '*\(clean)*'cd && kMDItemContentType != 'com.apple.application-bundle'"
    }

    public static func search(_ q: String, limit: Int = 6) async -> [String] {
        guard let pred = predicate(q) else { return [] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", NSHomeDirectory(), pred]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: []); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
                let data = ((try? out.fileHandleForReading.readToEnd()) ?? Data())
                p.waitUntilExit()
                let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                    .filter { !$0.contains("/Library/") && !$0.contains("/.") }
                    .sorted { $0.count < $1.count }
                cont.resume(returning: Array(paths.prefix(limit)))
            }
        }
    }
}
