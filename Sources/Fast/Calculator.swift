import Foundation

/// What the field works out from the words, as a launcher's calculator
/// does: a sum, a percentage, a unit or a currency in another, the time
/// somewhere else, a day counted to or from, a number in another base.
/// Each answer is a question and its answer, each with a line under it,
/// drawn side by side (CalcCard; on iPhone, AnswerPlate over the field's
/// rows). Nothing typed leaves the device: currencies
/// come from rates fetched a few times a day, with no words in the asking.
enum Calc {
    enum Kind: Equatable {
        case calculation, numberBase, units, currency, time, date
        case color(UInt32)
    }

    struct Answer: Equatable {
        /// The question as it is read, "100 USD", and a line under it.
        let question: String
        let questionNote: String
        /// The answer, "€91.45", and a line under it.
        let result: String
        let resultNote: String
        /// What Return copies.
        let copy: String
        /// The reading that produced the answer, independent of its labels.
        var kind: Kind = .calculation
    }

    /// The words' answer, or nil when they aren't a question the field can
    /// work out. The last one is kept: a card is drawn more often than the
    /// words change. It is kept by the words trimmed, so the words and the
    /// same words with a space after them are one question, not two.
    @MainActor
    static func answer(_ text: String, now: Date = Date(), rates: Rates? = nil) -> Answer? {
        // The app's own rates, or a test's, each kept apart.
        let rates = rates ?? Rates.shared
        let words = text.trimmingCharacters(in: .whitespaces)
        // And by the minute: the time somewhere and the days to a day are
        // the moment's, and words typed again later are asked again.
        let minute = Int(now.timeIntervalSince1970 / 60)
        if let last, last.text == words, last.source == ObjectIdentifier(rates), last.rates == rates.version,
           last.minute == minute { return last.answer }
        var answer: Answer?
        if words.count >= 2, words.count <= 120, asks(words) {
            answer = color(words) ?? percent(words) ?? math(words) ?? base(words) ?? units(words)
                ?? money(words, rates: rates) ?? time(words, now: now) ?? date(words, now: now)
        }
        last = (words, ObjectIdentifier(rates), rates.version, minute, answer)
        return answer
    }

    /// Whether the words could be a question at all, before any of the
    /// readings below is tried: most of what is typed into the field is an
    /// address or words to search, and every key of it came through here.
    /// Every reading needs a digit but three: pi in a sum ("pi*2"), the
    /// time somewhere, begun or ended with its word ("time in tokyo",
    /// "tokyo time"), and days counted to a day by its name ("days until
    /// christmas"). A currency's sign is let through too, for an amount
    /// begun with it.
    static func asks(_ words: String) -> Bool {
        if words.hasPrefix("#") { return true }
        if words.contains(where: { $0.isNumber || signs.contains($0) }) { return true }
        let lower = words.lowercased()
        if lower.contains("pi") || lower.contains("π") || lower.contains("√") { return true }
        if lower.hasSuffix(" time") { return true }
        if split(lower).contains(where: { named($0.0) && named($0.1) }) { return true }
        return timeLeads.contains { lower.hasPrefix($0) } || dayLeads.contains { lower.hasPrefix($0) }
    }

    /// A currency asked about with no amount, "btc" or "euros", known
    /// without the rates: one side of "btc to usd".
    static func named(_ words: String) -> Bool {
        let key = words.trimmingCharacters(in: .whitespaces)
        return asked.contains(key.uppercased()) || names[key] != nil || (key.hasSuffix("s") && names[String(key.dropLast())] != nil)
    }

    /// The signs an amount is written with.
    static let signs: Set<Character> = ["$", "€", "£", "¥", "₽", "₴", "₸", "₹", "₩", "₺", "₪"]

    @MainActor private static var last: (text: String, source: ObjectIdentifier, rates: Int, minute: Int, answer: Answer?)?

    /// An explicit CSS hex color, never a bare word or an address fragment.
    static func color(_ words: String) -> Answer? {
        guard words.hasPrefix("#") else { return nil }
        var digits = String(words.dropFirst())
        guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count == 3 { digits = digits.map { String(repeating: String($0), count: 2) }.joined() }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        let hex = "#" + digits.uppercased()
        let rgb = "RGB \((value >> 16) & 255), \((value >> 8) & 255), \(value & 255)"
        return Answer(question: hex, questionNote: "HEX", result: rgb, resultNote: "RGB", copy: hex, kind: .color(value))
    }

    // MARK: numbers

    /// A number as the card shows it: grouped, and only as many places as
    /// say something.
    static func shown(_ value: Double, places: Int? = nil) -> String {
        let size = abs(value)
        let places = places ?? (size == 0 || size >= 1000 ? 2 : size >= 1 ? 4 : 8)
        return decimal(places).string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Grouped, en_US, with at most so many places: made once for each
    /// count of places, not for every number shown. A formatter only read
    /// from is safe on any thread.
    static func decimal(_ places: Int) -> NumberFormatter {
        decimals.indices.contains(places) ? decimals[places] : decimalFormat(places)
    }

    private static let decimals: [NumberFormatter] = (0 ... 10).map(decimalFormat)

    private static func decimalFormat(_ places: Int) -> NumberFormatter {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .decimal
        format.usesGroupingSeparator = true
        format.minimumFractionDigits = 0
        format.maximumFractionDigits = places
        return format
    }

    /// A number in words, the line under a sum's answer: the number as the
    /// card shows it. Spelled from the Double, 100 + 10% was one hundred
    /// ten point thirteen zeros and a one, every digit the Double keeps: a
    /// spelling formatter takes no limit on places.
    static func spelled(_ shown: String) -> String {
        let number = NSDecimalNumber(string: shown.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US"))
        guard number != .notANumber, abs(number.doubleValue) < 1e15 else { return "" }
        let words = spelling.string(from: number) ?? ""
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let spelling: NumberFormatter = {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .spellOut
        return format
    }()

    /// "12", "1,200.5", "1.5k", "2m": a number as it is typed.
    static func number(_ text: String) -> Double? {
        var words = text.lowercased().replacingOccurrences(of: " ", with: "")
        var scale = 1.0
        if let last = words.last, "km".contains(last), words.count > 1, words.dropLast().last?.isNumber == true {
            scale = last == "k" ? 1_000 : 1_000_000
            words.removeLast()
        }
        guard let digits = digits(words), let value = Double(digits) else { return nil }
        return value * scale
    }

    /// A number's digits as typed, read the one way they can be: commas
    /// that group thousands ("1,200.5") or lakhs ("1,23,456") taken out,
    /// and a comma that can't group, "1,5" or "3,14", read as the decimal
    /// point it is in much of the world, as is the comma after points
    /// that group ("1.234,56"). Taking every comma out read those as 15
    /// and 314. Nil for digits read no way at all ("1,2,3", ",5").
    static func digits(_ text: String) -> String? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }
        guard text.contains(",") else { return text }
        func reads(_ part: Substring, _ pattern: String) -> Bool { part.range(of: pattern, options: .regularExpression) != nil }
        let thousands = #"^[0-9]{1,3}(,[0-9]{3})+$"#, lakhs = #"^[0-9]{1,2}(,[0-9]{2})*,[0-9]{3}$"#
        // "1,200.5", "1,23,456": commas that group, then a point or none.
        let points = text.split(separator: ".", omittingEmptySubsequences: false)
        if points.count <= 2, points.count == 1 || !points[1].contains(","),
           reads(points[0], thousands) || reads(points[0], lakhs) {
            return text.replacingOccurrences(of: ",", with: "")
        }
        // "1,5", "1.234,56": one comma, the decimal point, after any points
        // that group.
        let halves = text.split(separator: ",", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty, !halves[1].contains("."),
              !halves[0].contains(".") || reads(halves[0], #"^[0-9]{1,3}(\.[0-9]{3})+$"#) else { return nil }
        return halves[0].replacingOccurrences(of: ".", with: "") + "." + halves[1]
    }

    /// The words split at a joining word, "to", "in", "as", tried from the
    /// last one back, so "5 in in cm" reads as five inches. Found in the
    /// words themselves, case aside: a lowercased copy's places aren't the
    /// words' own once a letter lowercases longer, "İ" to "i̇", and cutting
    /// the words there crashed.
    static func split(_ words: String) -> [(String, String)] {
        let joins = [" to ", " in ", " into ", " as ", " -> ", " → ", " = "]
        var out: [(String, String)] = []
        for join in joins {
            var search = words.startIndex ..< words.endIndex
            while let found = words.range(of: join, options: [.backwards, .caseInsensitive], range: search) {
                let left = String(words[..<found.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(words[found.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty { out.append((left, right)) }
                search = words.startIndex ..< found.lowerBound
            }
        }
        return out
    }

    // MARK: sums

    /// 2400*12, sqrt(2)*pi: what Sum works out, with its answer in words.
    static func math(_ words: String) -> Answer? {
        guard let sum = Sum.answer(words) else { return nil }
        let question = words.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .replacingOccurrences(of: "  ", with: " ")
        return Answer(question: question.trimmingCharacters(in: .whitespaces), questionNote: "Sum",
                      result: sum.shown, resultNote: spelled(sum.shown),
                      copy: sum.shown.replacingOccurrences(of: ",", with: ""))
    }

    /// "20% of 80", "80 + 15%", "80 - 15%", "15% off 80".
    static func percent(_ words: String) -> Answer? {
        // Every reading has a percent sign.
        guard words.contains("%") else { return nil }
        let lower = words.lowercased()
        func match(_ regex: NSRegularExpression) -> [Double]? {
            guard let found = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
            return (1 ..< found.numberOfRanges).compactMap { Range(found.range(at: $0), in: lower).flatMap { Calc.number(String(lower[$0])) } }
        }
        func answer(_ question: String, _ value: Double) -> Answer {
            Answer(question: question, questionNote: "Percentage", result: shown(value), resultNote: spelled(shown(value)),
                   copy: shown(value).replacingOccurrences(of: ",", with: ""))
        }
        if let n = match(percents[0]), n.count == 2 {
            return answer("\(shown(n[0]))% of \(shown(n[1]))", n[0] / 100 * n[1])
        }
        if let n = match(percents[1]), n.count == 2 {
            return answer("\(shown(n[1])) − \(shown(n[0]))%", n[1] * (1 - n[0] / 100))
        }
        if let n = match(percents[2]), n.count == 2 {
            let adding = lower.contains("+")
            return answer("\(shown(n[0])) \(adding ? "+" : "−") \(shown(n[1]))%", n[0] * (1 + (adding ? 1 : -1) * n[1] / 100))
        }
        return nil
    }

    /// The three readings of a percentage, made once.
    private static let percents: [NSRegularExpression] = {
        // Any digits, points and commas: Calc.number reads them, or not.
        let number = #"([0-9][0-9.,]*)"#
        return [number + #"\s*%\s*of\s*"# + number, number + #"\s*%\s*off\s*"# + number,
                number + #"\s*([+-])\s*"# + number + #"\s*%"#]
            .map { try! NSRegularExpression(pattern: "^" + $0 + "$") }
    }()

    /// "255 in hex", "0xff in decimal", "0b1010", "10 to binary".
    static func base(_ words: String) -> Answer? {
        let lower = words.lowercased()
        let names: [String: (Int, String)] = [
            "hex": (16, "Hexadecimal"), "hexadecimal": (16, "Hexadecimal"), "decimal": (10, "Decimal"), "dec": (10, "Decimal"),
            "binary": (2, "Binary"), "bin": (2, "Binary"), "octal": (8, "Octal"), "oct": (8, "Octal"),
        ]
        func read(_ text: String) -> (Int, Int)? {
            if text.hasPrefix("0x"), let value = Int(text.dropFirst(2), radix: 16) { return (value, 16) }
            if text.hasPrefix("0b"), let value = Int(text.dropFirst(2), radix: 2) { return (value, 2) }
            if text.hasPrefix("0o"), let value = Int(text.dropFirst(2), radix: 8) { return (value, 8) }
            if text.allSatisfy(\.isNumber), let value = Int(text) { return (value, 10) }
            return nil
        }
        func said(_ value: Int, _ base: Int) -> String {
            switch base {
            case 16: return "0x" + String(value, radix: 16).uppercased()
            case 2: return "0b" + String(value, radix: 2)
            case 8: return "0o" + String(value, radix: 8)
            default: return shown(Double(value), places: 0)
            }
        }
        let title = [16: "Hexadecimal", 2: "Binary", 8: "Octal", 10: "Decimal"]
        for (left, right) in split(lower) {
            guard let (value, from) = read(left), let (to, name) = names[right], to != from else { continue }
            let result = said(value, to)
            return Answer(question: said(value, from), questionNote: title[from] ?? "", result: result, resultNote: name, copy: result, kind: .numberBase)
        }
        // A number written in another base, on its own: in decimal.
        if lower.hasPrefix("0x") || lower.hasPrefix("0b"), let (value, from) = read(lower), from != 10 {
            let result = said(value, 10)
            return Answer(question: said(value, from), questionNote: title[from] ?? "", result: result, resultNote: "Decimal",
                          copy: result.replacingOccurrences(of: ",", with: ""), kind: .numberBase)
        }
        return nil
    }

    // MARK: units

    struct UnitName {
        let words: [String]
        let symbol: String
        let name: String
        let unit: Dimension
    }

    /// Every unit the field knows by the words typed for it, the first
    /// one shown.
    static let unitNames: [UnitName] = {
        let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
        let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
        let rows: [([String], String, String, Dimension)] = [
            (["mm", "millimeter", "millimeters", "millimetre", "millimetres"], "mm", "Millimeters", UnitLength.millimeters),
            (["cm", "centimeter", "centimeters", "centimetre", "centimetres"], "cm", "Centimeters", UnitLength.centimeters),
            (["m", "meter", "meters", "metre", "metres"], "m", "Meters", UnitLength.meters),
            (["km", "kilometer", "kilometers", "kilometre", "kilometres"], "km", "Kilometers", UnitLength.kilometers),
            (["in", "inch", "inches", "\""], "in", "Inches", UnitLength.inches),
            (["ft", "foot", "feet", "'"], "ft", "Feet", UnitLength.feet),
            (["yd", "yard", "yards"], "yd", "Yards", UnitLength.yards),
            (["mi", "mile", "miles"], "mi", "Miles", UnitLength.miles),
            (["nmi", "nautical mile", "nautical miles"], "nmi", "Nautical Miles", UnitLength.nauticalMiles),
            (["mg", "milligram", "milligrams"], "mg", "Milligrams", UnitMass.milligrams),
            (["g", "gram", "grams", "gramme", "grammes"], "g", "Grams", UnitMass.grams),
            (["kg", "kilogram", "kilograms", "kilo", "kilos"], "kg", "Kilograms", UnitMass.kilograms),
            (["t", "tonne", "tonnes", "ton", "tons"], "t", "Tonnes", UnitMass.metricTons),
            (["oz", "ounce", "ounces"], "oz", "Ounces", UnitMass.ounces),
            (["lb", "lbs", "pound", "pounds"], "lb", "Pounds", UnitMass.pounds),
            (["st", "stone", "stones"], "st", "Stones", UnitMass.stones),
            (["c", "°c", "celsius", "degc", "degrees celsius", "°"], "°C", "Celsius", UnitTemperature.celsius),
            (["f", "°f", "fahrenheit", "degf", "degrees fahrenheit"], "°F", "Fahrenheit", UnitTemperature.fahrenheit),
            (["k", "kelvin", "kelvins"], "K", "Kelvin", UnitTemperature.kelvin),
            (["ml", "milliliter", "milliliters", "millilitre", "millilitres"], "ml", "Milliliters", UnitVolume.milliliters),
            (["l", "liter", "liters", "litre", "litres"], "l", "Liters", UnitVolume.liters),
            (["gal", "gallon", "gallons"], "gal", "Gallons", UnitVolume.gallons),
            (["qt", "quart", "quarts"], "qt", "Quarts", UnitVolume.quarts),
            (["pt", "pint", "pints"], "pt", "Pints", UnitVolume.pints),
            (["cup", "cups"], "cups", "Cups", UnitVolume.cups),
            (["fl oz", "floz", "fluid ounce", "fluid ounces"], "fl oz", "Fluid Ounces", UnitVolume.fluidOunces),
            (["tbsp", "tablespoon", "tablespoons"], "tbsp", "Tablespoons", UnitVolume.tablespoons),
            (["tsp", "teaspoon", "teaspoons"], "tsp", "Teaspoons", UnitVolume.teaspoons),
            (["m2", "m²", "sqm", "sq m", "square meter", "square meters", "square metres"], "m²", "Square Meters", UnitArea.squareMeters),
            (["km2", "km²", "sq km", "square kilometer", "square kilometers"], "km²", "Square Kilometers", UnitArea.squareKilometers),
            (["ft2", "ft²", "sqft", "sq ft", "square foot", "square feet"], "ft²", "Square Feet", UnitArea.squareFeet),
            (["mi2", "mi²", "sq mi", "square mile", "square miles"], "mi²", "Square Miles", UnitArea.squareMiles),
            (["acre", "acres", "ac"], "ac", "Acres", UnitArea.acres),
            (["ha", "hectare", "hectares"], "ha", "Hectares", UnitArea.hectares),
            (["km/h", "kmh", "kph"], "km/h", "Kilometers per Hour", UnitSpeed.kilometersPerHour),
            (["mph", "miles per hour"], "mph", "Miles per Hour", UnitSpeed.milesPerHour),
            (["m/s", "meters per second"], "m/s", "Meters per Second", UnitSpeed.metersPerSecond),
            (["kn", "knot", "knots"], "kn", "Knots", UnitSpeed.knots),
            (["b", "byte", "bytes"], "B", "Bytes", UnitInformationStorage.bytes),
            (["kb", "kilobyte", "kilobytes"], "KB", "Kilobytes", UnitInformationStorage.kilobytes),
            (["mb", "megabyte", "megabytes"], "MB", "Megabytes", UnitInformationStorage.megabytes),
            (["gb", "gigabyte", "gigabytes"], "GB", "Gigabytes", UnitInformationStorage.gigabytes),
            (["tb", "terabyte", "terabytes"], "TB", "Terabytes", UnitInformationStorage.terabytes),
            (["kib", "kibibyte", "kibibytes"], "KiB", "Kibibytes", UnitInformationStorage.kibibytes),
            (["mib", "mebibyte", "mebibytes"], "MiB", "Mebibytes", UnitInformationStorage.mebibytes),
            (["gib", "gibibyte", "gibibytes"], "GiB", "Gibibytes", UnitInformationStorage.gibibytes),
            (["bit", "bits"], "bit", "Bits", UnitInformationStorage.bits),
            (["ms", "millisecond", "milliseconds"], "ms", "Milliseconds", UnitDuration.milliseconds),
            (["s", "sec", "secs", "second", "seconds"], "s", "Seconds", UnitDuration.seconds),
            (["min", "mins", "minute", "minutes"], "min", "Minutes", UnitDuration.minutes),
            (["h", "hr", "hrs", "hour", "hours"], "h", "Hours", UnitDuration.hours),
            (["d", "day", "days"], "d", "Days", day),
            (["wk", "week", "weeks"], "wk", "Weeks", week),
        ]
        return rows.map { UnitName(words: $0.0, symbol: $0.1, name: $0.2, unit: $0.3) }
    }()

    static func unit(_ words: String) -> UnitName? {
        let key = words.lowercased().replacingOccurrences(of: "degrees ", with: "").trimmingCharacters(in: .whitespaces)
        return unitNames.first { $0.words.contains(key) }
            ?? (key.hasPrefix("degrees") ? nil : unitNames.first { $0.words.contains(words.lowercased().trimmingCharacters(in: .whitespaces)) })
    }

    /// "5 km to mi", "72f in c", "1.5 gb as mb": a number and its unit, and
    /// the unit it is asked in, of the same kind.
    static func units(_ words: String) -> Answer? {
        for (left, right) in split(words) {
            guard let to = unit(right), let (value, from) = amount(left) else { continue }
            // Of one kind: the same base unit, meters, kilograms, seconds.
            guard type(of: from.unit).baseUnit().symbol == type(of: to.unit).baseUnit().symbol, from.symbol != to.symbol else { continue }
            let result = Measurement(value: value, unit: from.unit).converted(to: to.unit).value
            let answer = shown(result) + (to.symbol.hasPrefix("°") ? "" : " ") + to.symbol
            return Answer(question: shown(value) + (from.symbol.hasPrefix("°") ? "" : " ") + from.symbol, questionNote: from.name,
                          result: answer, resultNote: to.name, copy: answer.replacingOccurrences(of: ",", with: ""), kind: .units)
        }
        return nil
    }

    /// "5 km", "5km", "72°f": a number and a unit.
    static func amount(_ words: String) -> (Double, UnitName)? {
        let text = words.trimmingCharacters(in: .whitespaces)
        guard let first = text.firstIndex(where: { !($0.isNumber || $0 == "." || $0 == ",") }), first > text.startIndex,
              let value = number(String(text[..<first])), let named = unit(String(text[first...])) else { return nil }
        return (value, named)
    }

    // MARK: money

    /// Currencies by what people type for them: their sign, their name in
    /// English, whole or more than one, and the codes of the ones people
    /// ask about, in any case.
    /// The rates know hundreds of other codes, and many are words, TOP,
    /// ALL, LINK, TIME, PRO: "top 10" is a search. Those count only in
    /// capitals and asked into another currency (`tickers`), "100 LINK in
    /// usd".
    @MainActor
    static func currency(_ words: String, rates: Rates, tickers: Bool = false) -> String? {
        let trimmed = words.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "$€£¥₽₴₸₹₩₺"))))
        let key = trimmed.lowercased()
        guard !key.isEmpty else { return nil }
        let signs: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₽": "RUB", "₴": "UAH", "₸": "KZT", "₹": "INR", "₩": "KRW", "₺": "TRY"]
        if let code = signs[key] { return code }
        if let code = names[key] ?? (key.hasSuffix("s") ? names[String(key.dropLast())] : nil) { return code }
        let code = key.uppercased()
        guard code.count >= 3, code.count <= 5, code.allSatisfy(\.isLetter), rates.knows(code) else { return nil }
        if asked.contains(code) { return code }
        return tickers && trimmed == code ? code : nil
    }

    /// Currencies by their English names, each whole: "euro" and "euros",
    /// never "europe".
    private static let names: [String: String] = [
        "dollar": "USD", "buck": "USD", "euro": "EUR", "pound": "GBP", "quid": "GBP", "sterling": "GBP", "yen": "JPY",
        "yuan": "CNY", "renminbi": "CNY", "rmb": "CNY", "rupee": "INR", "ruble": "RUB", "rouble": "RUB", "franc": "CHF", "won": "KRW",
        "lira": "TRY", "hryvnia": "UAH", "hryvna": "UAH", "tenge": "KZT", "shekel": "ILS", "zloty": "PLN", "dirham": "AED",
        "bitcoin": "BTC", "ether": "ETH", "ethereum": "ETH", "solana": "SOL",
        "tether": "USDT", "usd coin": "USDC", "satoshi": "SAT", "sat": "SAT", "sri lankan rupee": "LKR",
    ]

    /// The codes people ask about, read in any case: the main currencies
    /// of the world, and the coins the card names. None is a word typed
    /// to search for something else.
    static let asked: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "CNY", "CHF", "CAD", "AUD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RON",
        "TRY", "RUB", "UAH", "KZT", "BYN", "INR", "KRW", "HKD", "SGD", "THB", "IDR", "MYR", "VND", "AED", "SAR", "ILS", "BRL",
        "MXN", "ARS", "ZAR", "EGP", "LKR", "BTC", "ETH", "SOL", "USDT", "USDC", "SAT",
    ]

    /// "$100", "100 usd", "100$", "1.5k eur": an amount and its currency.
    @MainActor
    static func money(amount words: String, rates: Rates, tickers: Bool = false) -> (Double, String)? {
        let text = words.trimmingCharacters(in: .whitespaces)
        if let first = text.first, !first.isNumber, let start = text.firstIndex(where: \.isNumber),
           let code = currency(String(text[..<start]), rates: rates, tickers: tickers), let value = number(String(text[start...])) {
            return (value, code)
        }
        guard let end = text.lastIndex(where: { $0.isNumber || $0 == "." || $0 == "," }) else { return nil }
        var cut = text.index(after: end)
        // "1.5k eur": the k is the number's.
        if cut < text.endIndex, "kKmM".contains(text[cut]), text.index(after: cut) == text.endIndex || text[text.index(after: cut)] == " " {
            cut = text.index(after: cut)
        }
        guard let value = number(String(text[..<cut])), let code = currency(String(text[cut...]), rates: rates, tickers: tickers) else { return nil }
        return (value, code)
    }

    /// "100 usd in eur", "$50 to rub", "100 dollars in euros", one of a
    /// currency with no amount, "btc to usd", and an amount alone, "€40",
    /// in the currency of the Mac's region.
    @MainActor
    static func money(_ words: String, rates: Rates) -> Answer? {
        var asked: (Double, String, String)?
        for (left, right) in split(words) {
            if let (value, from) = money(amount: left, rates: rates, tickers: true), let to = currency(right, rates: rates, tickers: true), to != from {
                asked = (value, from, to)
                break
            }
        }
        // "btc to usd": one of it, as a search engine reads it.
        if asked == nil {
            for (left, right) in split(words) {
                if let from = currency(left, rates: rates, tickers: true), let to = currency(right, rates: rates, tickers: true), to != from {
                    asked = (1, from, to)
                    break
                }
            }
        }
        if asked == nil, let (value, from) = money(amount: words, rates: rates),
           words.rangeOfCharacter(from: .letters) != nil || words.rangeOfCharacter(from: CharacterSet(charactersIn: "$€£¥₽₴₸₹₩₺")) != nil {
            let home = Locale.current.currency?.identifier ?? "USD"
            asked = (value, from, from == home ? (home == "USD" ? "EUR" : "USD") : home)
        }
        guard let (value, from, to) = asked else { return nil }
        rates.warm()
        let question = said(value, from)
        guard let result = rates.convert(value, from: from, to: to) else {
            return Answer(question: question, questionNote: name(from), result: "…", resultNote: rates.failed ? "Rates unavailable" : "Getting rates", copy: "", kind: .currency)
        }
        let answer = said(result, to)
        return Answer(question: question, questionNote: name(from), result: answer,
                      resultNote: name(to) + rates.age, copy: shown(result, places: crypto(to) ? 8 : 2).replacingOccurrences(of: ",", with: ""), kind: .currency)
    }

    static let cryptos: [String: String] = ["BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "USDT": "Tether", "USDC": "USD Coin",
                                            "XRP": "XRP", "DOGE": "Dogecoin", "TON": "Toncoin", "LTC": "Litecoin", "SAT": "Bitcoin satoshis"]
    static func crypto(_ code: String) -> Bool { cryptos[code] != nil }

    static func name(_ code: String) -> String {
        cryptos[code] ?? Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
    }

    /// An amount as its currency writes it: "$1,204.50", "€91.45", "0.0015 BTC".
    static func said(_ value: Double, _ code: String) -> String {
        if code == "SAT" { return shown(value, places: 8) + " sats" }
        if crypto(code) { return shown(value, places: value >= 1 ? 4 : 8) + " " + code }
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .currency
        format.currencyCode = code
        // The sign its own country writes, where English only has letters.
        let signs = ["RUB": "₽", "UAH": "₴", "KZT": "₸", "TRY": "₺", "ILS": "₪", "INR": "₹", "KRW": "₩", "CNY": "¥", "AED": "AED ", "CHF": "CHF "]
        if let sign = signs[code] { format.currencySymbol = sign }
        let small = code == "JPY" || code == "KRW"
        format.maximumFractionDigits = small ? 0 : 2
        format.minimumFractionDigits = small ? 0 : 2
        let said = format.string(from: NSNumber(value: value)) ?? "\(shown(value)) \(code)"
        return said.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: time

    /// Places by the words people type for them: a city in the Mac's own
    /// list of zones, a zone's letters, and a few names it doesn't know.
    static func zone(_ words: String) -> (TimeZone, String)? {
        let key = words.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let named: [String: (String, String)] = [
            "sf": ("America/Los_Angeles", "San Francisco"), "san francisco": ("America/Los_Angeles", "San Francisco"),
            "la": ("America/Los_Angeles", "Los Angeles"), "seattle": ("America/Los_Angeles", "Seattle"),
            "nyc": ("America/New_York", "New York"), "ny": ("America/New_York", "New York"), "boston": ("America/New_York", "Boston"),
            "miami": ("America/New_York", "Miami"), "washington": ("America/New_York", "Washington"), "austin": ("America/Chicago", "Austin"),
            "dallas": ("America/Chicago", "Dallas"), "beijing": ("Asia/Shanghai", "Beijing"), "mumbai": ("Asia/Kolkata", "Mumbai"),
            "delhi": ("Asia/Kolkata", "Delhi"), "bangalore": ("Asia/Kolkata", "Bangalore"), "india": ("Asia/Kolkata", "India"),
            "japan": ("Asia/Tokyo", "Japan"), "china": ("Asia/Shanghai", "China"), "uk": ("Europe/London", "UK"),
            "germany": ("Europe/Berlin", "Germany"), "france": ("Europe/Paris", "France"), "spain": ("Europe/Madrid", "Spain"),
            "italy": ("Europe/Rome", "Italy"), "russia": ("Europe/Moscow", "Moscow"), "israel": ("Asia/Jerusalem", "Israel"),
            "tel aviv": ("Asia/Jerusalem", "Tel Aviv"), "bali": ("Asia/Makassar", "Bali"), "st petersburg": ("Europe/Moscow", "St Petersburg"),
            "saint petersburg": ("Europe/Moscow", "St Petersburg"), "kiev": ("Europe/Kyiv", "Kyiv"),
            "msk": ("Europe/Moscow", "Moscow"),
            "utc": ("UTC", "UTC"), "gmt": ("GMT", "GMT"),
            "pt": ("America/Los_Angeles", "Pacific Time"), "pst": ("America/Los_Angeles", "Pacific Time"), "pdt": ("America/Los_Angeles", "Pacific Time"),
            "et": ("America/New_York", "Eastern Time"), "est": ("America/New_York", "Eastern Time"), "edt": ("America/New_York", "Eastern Time"),
            "ct": ("America/Chicago", "Central Time"), "cst": ("America/Chicago", "Central Time"), "cdt": ("America/Chicago", "Central Time"),
            "mt": ("America/Denver", "Mountain Time"), "mst": ("America/Denver", "Mountain Time"), "mdt": ("America/Denver", "Mountain Time"),
            "cet": ("Europe/Paris", "Central Europe"), "cest": ("Europe/Paris", "Central Europe"), "bst": ("Europe/London", "London"),
            "ist": ("Asia/Kolkata", "India"), "jst": ("Asia/Tokyo", "Tokyo"), "aest": ("Australia/Sydney", "Sydney"), "hkt": ("Asia/Hong_Kong", "Hong Kong"),
            "sgt": ("Asia/Singapore", "Singapore"), "eet": ("Europe/Athens", "Eastern Europe"),
        ]
        if let (id, name) = named[key], let zone = TimeZone(identifier: id) { return (zone, name) }
        if key == "local" || key == "here" || key == "me" { return (.current, "Here") }
        let city = key.replacingOccurrences(of: " ", with: "_")
        if let id = zones[city], let zone = TimeZone(identifier: id) {
            return (zone, id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
        }
        return nil
    }

    /// The Mac's zones by their city, lower case: "tokyo", "new_york".
    static let zones: [String: String] = {
        var out: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let city = id.split(separator: "/").last else { continue }
            out[city.lowercased()] = id
        }
        return out
    }()

    /// "3pm", "15:30", "9:05 am": a time of day.
    static func clock(_ words: String) -> (Int, Int)? {
        let key = words.lowercased().replacingOccurrences(of: " ", with: "")
        guard let found = clockPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let hourRange = Range(found.range(at: 1), in: key), var hour = Int(key[hourRange]) else { return nil }
        let minute = Range(found.range(at: 2), in: key).flatMap { Int(key[$0]) } ?? 0
        let half = Range(found.range(at: 3), in: key).map { String(key[$0]) }
        guard minute < 60 else { return nil }
        if let half {
            guard (1 ... 12).contains(hour) else { return nil }
            if half.hasPrefix("p"), hour != 12 { hour += 12 }
            if half.hasPrefix("a"), hour == 12 { hour = 0 }
        } else {
            // "3" alone is a number, not a time: a time without am or pm
            // needs its minutes.
            guard found.range(at: 2).location != NSNotFound, hour < 24 else { return nil }
        }
        return (hour, minute)
    }

    private static let clockPattern = try! NSRegularExpression(pattern: #"^(\d{1,2})(?::(\d{2}))?(am|pm|a|p)?$"#)

    /// What the time somewhere is asked with, before the place.
    static let timeLeads = ["time in ", "now in ", "time at ", "current time in ", "what time is it in "]

    /// "time in tokyo", "tokyo time", "now in london", "what time is it in paris",
    /// "3pm london in sf", "15:00 msk to pst", "3pm in tokyo".
    static func time(_ words: String, now: Date) -> Answer? {
        let lower = words.lowercased().trimmingCharacters(in: .whitespaces)
        // Now, somewhere.
        for lead in timeLeads {
            if lower.hasPrefix(lead), let (zone, name) = zone(String(lower.dropFirst(lead.count))) {
                return present(in: zone, name, at: now)
            }
        }
        if lower.hasSuffix(" time"), let (zone, name) = zone(String(lower.dropLast(5))) { return present(in: zone, name, at: now) }
        // A time of day somewhere, somewhere else.
        for (left, right) in split(lower) {
            guard let (to, toName) = zone(right) else { continue }
            let parts = left.split(separator: " ", maxSplits: 1).map(String.init)
            var from: (TimeZone, String) = (.current, "Here")
            var clockWords = left
            if parts.count == 2, let (zone, name) = zone(parts[1]), clock(parts[0]) != nil {
                from = (zone, name)
                clockWords = parts[0]
            } else if let last = left.lastIndex(of: " "), let (zone, name) = zone(String(left[left.index(after: last)...])),
                      clock(String(left[..<last])) != nil {
                from = (zone, name)
                clockWords = String(left[..<last])
            }
            guard let (hour, minute) = clock(clockWords) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = from.0
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.hour = hour
            day.minute = minute
            guard let moment = calendar.date(from: day) else { continue }
            return Answer(question: said(moment, in: from.0), questionNote: note(moment, in: from.0, from.1),
                          result: said(moment, in: to), resultNote: note(moment, in: to, toName), copy: said(moment, in: to), kind: .time)
        }
        return nil
    }

    private static func present(in zone: TimeZone, _ name: String, at now: Date) -> Answer {
        Answer(question: said(now, in: .current), questionNote: note(now, in: .current, "Here"),
               result: said(now, in: zone), resultNote: note(now, in: zone, name), copy: said(now, in: zone), kind: .time)
    }

    static func said(_ date: Date, in zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.timeZone = zone
        format.dateFormat = "h:mm a"
        return format.string(from: date)
    }

    /// "Tokyo · Sat, Sep 26 · UTC+9".
    static func note(_ date: Date, in zone: TimeZone, _ name: String) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.timeZone = zone
        format.dateFormat = "EEE, MMM d"
        let seconds = zone.secondsFromGMT(for: date)
        let hours = seconds / 3600, minutes = abs(seconds % 3600) / 60
        let offset = "UTC" + (seconds >= 0 ? "+" : "−") + "\(abs(hours))" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
        return [name, format.string(from: date), offset].joined(separator: " · ")
    }

    // MARK: days

    /// Days people count to by name.
    static func holiday(_ words: String, after now: Date) -> Date? {
        let named: [String: (Int, Int)] = [
            "christmas": (12, 25), "xmas": (12, 25), "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1),
            "halloween": (10, 31), "valentine's day": (2, 14), "valentines day": (2, 14), "valentines": (2, 14),
        ]
        guard let (month, day) = named[words] else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        var parts = calendar.dateComponents([.year], from: today)
        parts.month = month
        parts.day = day
        guard let date = calendar.date(from: parts) else { return nil }
        return date < today ? calendar.date(byAdding: .year, value: 1, to: date) : date
    }

    /// A day in the words, "dec 25", "march 3 2027", "next friday".
    static func day(_ words: String, after now: Date) -> Date? {
        if let named = holiday(words, after: now) { return named }
        guard let detector = dates,
              let found = detector.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
              found.range.length == (words as NSString).length, let date = found.date else { return nil }
        return Calendar(identifier: .gregorian).startOfDay(for: date)
    }

    private static let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// What counting the days to a day is asked with, before the day.
    static let dayLeads = ["days until ", "days till ", "days to ", "how many days until ", "weeks until ", "weeks till "]

    /// "days until christmas", "weeks until dec 25", "days until new year",
    /// "in 3 weeks", "10 days ago", "today + 45 days", "90 days from now".
    static func date(_ words: String, now: Date) -> Answer? {
        let lower = words.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        let spans: [(String, Calendar.Component, Int, String)] = [
            ("day", .day, 1, "Days"), ("week", .day, 7, "Weeks"), ("month", .month, 1, "Months"), ("year", .year, 1, "Years"),
        ]
        // Counting to a day.
        for lead in dayLeads where lower.hasPrefix(lead) {
            guard let target = day(String(lower.dropFirst(lead.count)), after: now) else { return nil }
            let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
            let weeks = lead.contains("week")
            let result = weeks ? shown(Double(days) / 7, places: 1) + (days == 7 ? " week" : " weeks")
                               : "\(shown(Double(days), places: 0)) " + (abs(days) == 1 ? "day" : "days")
            return Answer(question: "Today", questionNote: dated(today), result: result, resultNote: "Until " + dated(target),
                          copy: weeks ? shown(Double(days) / 7, places: 1) : String(days), kind: .date)
        }
        // A day some way off: each way has a count in digits.
        guard lower.contains(where: \.isNumber) else { return nil }
        for (regex, sign) in offs {
            guard let found = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let countRange = Range(found.range(at: 1), in: lower), let count = Int(lower[countRange]),
                  let unitRange = Range(found.range(at: 2), in: lower),
                  let span = spans.first(where: { lower[unitRange].hasPrefix($0.0) }) else { continue }
            // A count of weeks past Int.max / 7 overflowed (a crash), and one
            // that came to Int.max exactly is NSDateComponentUndefined to
            // Calendar, which added nothing: the answer was today.
            let (units, overflow) = count.multipliedReportingOverflow(by: span.2)
            guard !overflow, units != NSDateComponentUndefined,
                  let target = calendar.date(byAdding: span.1, value: sign * units, to: today),
                  writable(target, in: calendar) else { continue }
            let format = datedWeekday
            let label = "\(count) " + (count == 1 ? String(span.3.dropLast()).lowercased() : span.3.lowercased())
            return Answer(question: sign > 0 ? "Today + " + label : "Today − " + label, questionNote: dated(today),
                          result: dated(target, year: true), resultNote: format.string(from: target), copy: dated(target, year: true), kind: .date)
        }
        return nil
    }

    /// Whether a day some way off can be the answer: one "MMM d, yyyy"
    /// writes right. It writes no era, so before year 1 the year was wrong
    /// (975 BC came out as 0975, and 1 BC as 0001, the same as AD 1), and
    /// from about ten million years on it wrote nothing at all.
    static func writable(_ day: Date, in calendar: Calendar) -> Bool {
        calendar.component(.era, from: day) == 1 && !dated(day, year: true).isEmpty
    }

    /// The ways a day some way off is said, and which way from today.
    private static let offs: [(NSRegularExpression, Int)] = {
        let number = #"(\d+)"#
        let unit = #"([a-z]+)"#
        let patterns: [(String, Int)] = [
            ("^in " + number + " " + unit + "$", 1),
            ("^" + number + " " + unit + " (?:from now|from today|later)$", 1), ("^" + number + " " + unit + " ago$", -1),
            (#"^(?:today|now) \+ "# + number + " " + unit + "$", 1), (#"^(?:today|now) - "# + number + " " + unit + "$", -1),
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    static func dated(_ date: Date, year: Bool = false) -> String {
        (year ? datedYear : datedShort).string(from: date)
    }

    /// An en_US day in the Mac's own zone, made once for each way of
    /// writing it.
    private static let datedYear = dateFormat("MMM d, yyyy")
    private static let datedShort = dateFormat("EEE, MMM d")
    private static let datedWeekday = dateFormat("EEEE")

    private static func dateFormat(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        // The zone the Mac is in when the day is written, not when this was
        // made: it is made once.
        format.timeZone = .autoupdatingCurrent
        format.dateFormat = pattern
        return format
    }
}

// MARK: - rates

/// What one US dollar buys of every currency, fiat and crypto, from
/// Coinbase's public rates: one asking with nothing of yours in it, kept on
/// this Mac and asked again once it is three hours old.
@MainActor
final class Rates {
    static let shared = Rates()

    /// Bumped when new rates come, so a card worked out before them is
    /// worked out again.
    private(set) var version = 0
    private(set) var failed = false
    private var perDollar: [String: Double] = [:]
    private var fetched: Date?
    private var asking = false
    /// After an asking that failed, not before this: a minute, then twice
    /// as long each time it fails again, up to a quarter of an hour. The
    /// card stays up while it is offline, and every drawing of it asks.
    private(set) var retryAt: Date?
    private var failures = 0
    /// How the rates are asked for: the network, or a test's own.
    var fetch: () async -> Data? = {
        var request = URLRequest(url: Rates.source, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
        return data
    }
    /// Told when rates come: the field asks its question again.
    var came: (() -> Void)?

    private static let key = "calc.rates"
    private static let fresh: TimeInterval = 3 * 3600
    private static let source = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!

    /// Where the rates are kept between launches: the Mac's settings, the
    /// iPhone's defaults (this file is the iPhone field's too).
    #if os(macOS)
    private static var kept: UserDefaults { Store.settings }
    #else
    private static var kept: UserDefaults { .standard }
    #endif

    init(kept: Bool = true) {
        if kept, let kept = Self.kept.dictionary(forKey: Self.key), let rates = kept["rates"] as? [String: Double],
           let when = kept["at"] as? Double {
            perDollar = rates
            fetched = Date(timeIntervalSince1970: when)
        }
    }

    func knows(_ code: String) -> Bool { code == "USD" || (code == "SAT" ? perDollar["BTC"] != nil : perDollar[code] != nil) }

    func convert(_ value: Double, from: String, to: String) -> Double? {
        // A satoshi is a Bitcoin unit, never a separate market quote or USD peg.
        func rate(_ code: String) -> Double? {
            if code == "USD" { return 1 }
            if code == "SAT" { return perDollar["BTC"].map { $0 * 100_000_000 } }
            return perDollar[code]
        }
        let a = rate(from), b = rate(to)
        guard let a, let b, a.isFinite, b.isFinite, a > 0, b > 0 else { return nil }
        let result = value / a * b
        return result.isFinite ? result : nil
    }

    /// How old the rates are, when it matters: " · 5h ago".
    var age: String {
        guard let fetched else { return "" }
        let hours = Int(Date().timeIntervalSince(fetched) / 3600)
        return hours >= 6 ? " · \(hours < 48 ? "\(hours)h" : "\(hours / 24)d") ago" : ""
    }

    /// Asks for rates when there are none or they are old, once at a time,
    /// and not again soon after one that failed. The card is told only
    /// when what it says changes: new rates, or "Getting rates" become
    /// "Rates unavailable", once.
    @discardableResult
    func warm(at now: Date = Date()) -> Task<Void, Never>? {
        guard !asking, fetched.map({ now.timeIntervalSince($0) > Self.fresh }) ?? true,
              retryAt.map({ now >= $0 }) ?? true else { return nil }
        asking = true
        return Task {
            let parsed = await fetch().flatMap(Self.parse)
            asking = false
            guard let parsed, !parsed.isEmpty else {
                failures += 1
                retryAt = now.addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 15 * 60))
                let was = failed
                failed = perDollar.isEmpty
                if failed != was {
                    version += 1
                    came?()
                }
                return
            }
            failures = 0
            retryAt = nil
            perDollar = parsed
            fetched = Date()
            failed = false
            version += 1
            Self.kept.set(["rates": parsed, "at": Date().timeIntervalSince1970], forKey: Self.key)
            came?()
        }
    }

    static func parse(_ data: Data) -> [String: Double]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = (json["data"] as? [String: Any])?["rates"] as? [String: String] else { return nil }
        return rates.compactMapValues(Double.init)
    }

    /// Rates set by hand, for tests.
    func set(_ rates: [String: Double]) {
        perDollar = rates
        fetched = Date()
        version += 1
    }
}

// MARK: - a sum

/// Arithmetic as it is typed: 2400*12, (3+4)/2, 15% of nothing, 2^10,
/// sqrt(2)*pi.
/// Only when the words are a sum and nothing else, at least one operator
/// between two numbers, so an address or a year is never taken for one.
enum Sum {
    static func answer(_ text: String) -> (value: Double, shown: String)? {
        // A root and pi by their names, as one sign each.
        let words = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "sqrt", with: "√").replacingOccurrences(of: "pi", with: "π")
        guard words.count >= 2, words.count <= 120,
              words.allSatisfy({ "0123456789.,+-*/×÷x^%()√π ".contains($0) }),
              words.contains(where: { $0.isNumber || $0 == "π" }),
              words.range(of: #"[0-9)%π]\s*[-+*/×÷x^]\s*[-(0-9√π]"#, options: .regularExpression) != nil
                || words.range(of: #"^√\s*[(0-9π]"#, options: .regularExpression) != nil
                || words.range(of: #"^[0-9.]+\s*π$"#, options: .regularExpression) != nil
        else { return nil }
        // "0x10" is sixteen in hex (Calc.base reads it), not nought times
        // ten: an x right after a 0 that starts a number begins a hex
        // number. Spaced, "0 x 10" stays a sum.
        guard words.range(of: #"(^|[^0-9.,])0x[0-9]"#, options: .regularExpression) == nil else { return nil }
        var parser = Parser(Array(words.replacingOccurrences(of: " ", with: "")))
        guard let value = parser.expression(), parser.done, value.isFinite else { return nil }
        return (value, shown(value))
    }

    static func shown(_ value: Double) -> String {
        Calc.decimal(abs(value) < 1 ? 10 : 6).string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let chars: [Character]
        var at = 0
        init(_ chars: [Character]) { self.chars = chars }
        var done: Bool { at == chars.count }
        func peek() -> Character? { at < chars.count ? chars[at] : nil }
        mutating func eat(_ set: String) -> Character? {
            guard let next = peek(), set.contains(next) else { return nil }
            at += 1
            return next
        }
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = eat("+-") {
                guard let right = term() else { return nil }
                value = op == "+" ? value + right : value - right
            }
            return value
        }
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while true {
                if let op = eat("*/×÷x") {
                    guard let right = power() else { return nil }
                    value = (op == "/" || op == "÷") ? value / right : value * right
                } else if let next = peek(), next == "π" || next == "√" {
                    // 2π, 3√2: side by side is times.
                    guard let right = power() else { return nil }
                    value *= right
                } else {
                    return value
                }
            }
        }
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if eat("^") != nil {
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }
        mutating func unary() -> Double? {
            if eat("-") != nil { return unary().map { -$0 } }
            if eat("+") != nil { return unary() }
            if eat("√") != nil { return unary().flatMap { $0 >= 0 ? sqrt($0) : nil } }
            guard var value = primary() else { return nil }
            while eat("%") != nil { value /= 100 }
            return value
        }
        mutating func primary() -> Double? {
            if eat("π") != nil { return .pi }
            if eat("(") != nil {
                guard let inside = expression(), eat(")") != nil else { return nil }
                return inside
            }
            var typed = ""
            while let next = peek(), next.isNumber || next == "." || next == "," {
                typed.append(next)
                at += 1
            }
            return Calc.digits(typed).flatMap { Double($0) }
        }
    }
}
