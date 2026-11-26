import Foundation
import Testing
@testable import Fast

// What the field's calculator reads the words as, and what it answers.
@MainActor
struct CalcTests {
    /// Rates of the tests' own, set once and never asked for, with codes
    /// that are words too, as Coinbase's rates have them. Not the app's:
    /// other suites set those, and tests run side by side.
    static let rates: Rates = {
        let rates = Rates(kept: false)
        rates.set(["EUR": 0.9, "RUB": 90, "GBP": 0.8, "JPY": 150, "BTC": 0.00001,
                   "TOP": 2.4, "LINK": 0.05, "ALL": 90, "TIME": 1, "PRO": 1, "AMD": 390])
        return rates
    }()

    /// Sep 25 2026, noon in London.
    let noon = Date(timeIntervalSince1970: 1_790_334_000)

    func answer(_ words: String) -> Calc.Answer? { Calc.answer(words, now: noon, rates: Self.rates) }

    @Test func answerKindsFollowTheirReading() {
        let cases: [(String, Calc.Kind)] = [
            ("10*4", .calculation), ("20% of 80", .calculation),
            ("255 in hex", .numberBase), ("0xff", .numberBase),
            ("10 inches in cm", .units), ("10 pounds in kg", .units),
            ("100 usd in eur", .currency), ("10 pounds in eur", .currency),
            ("time in tokyo", .time), ("3pm london in sf", .time),
            ("in 3 weeks", .date), ("days until christmas", .date),
        ]
        for (words, kind) in cases { #expect(answer(words)?.kind == kind, "\(words)") }
    }

    @Test func hexColorsShowTheirRGBAndCopyTheNormalizedHex() {
        for words in ["#A78BFA", "#a78bfa", " #a78bfa "] {
            let color = answer(words)
            #expect(color?.kind == .color(0xA78BFA))
            #expect(color?.result == "RGB 167, 139, 250")
            #expect(color?.copy == "#A78BFA")
        }
        #expect(answer("#abc")?.copy == "#AABBCC")
        #expect(answer("#fff")?.kind == .color(0xFFFFFF))
        #expect(answer("#000000")?.result == "RGB 0, 0, 0")
        for words in ["#12", "#1234", "#12345g", "#a78bfa text", "#12345678", "a78bfa", "#１２３", "https://example.test/#abc"] {
            #expect(answer(words) == nil, "\(words)")
        }
    }

    @Test func currencyKeepsItsMarkWhileRatesAreUnavailable() async {
        let rates = Rates(kept: false)
        rates.fetch = { nil }
        await rates.warm(at: Date())?.value
        let value = Calc.answer("100 dollars in euros", now: noon, rates: rates)
        #expect(value?.kind == .currency)
        #expect(value?.resultNote == "Rates unavailable")
        #expect(value?.copy.isEmpty == true)
    }

    @Test func answerArtworkDecodesAsTemplateImages() {
        for name in ["calculator.operations", "banknote", "ruler", "clock.circle", "calendar", "number"] {
            let image = Glyphs.art(name)
            #expect(image != nil, "\(name)")
            #expect(image?.isTemplate == true, "\(name)")
        }
    }

    /// The line under an answer says the number the card shows, not every
    /// digit a Double keeps of it.
    @Test func theLineUnderAnAnswerSpellsTheNumberShown() {
        #expect(answer("100 + 10%")?.result == "110")
        #expect(answer("100 + 10%")?.resultNote == "One hundred ten")
        #expect(answer("0.1+0.2")?.result == "0.3")
        #expect(answer("0.1+0.2")?.resultNote == "Zero point three")
        #expect(answer("1.005*1000")?.result == "1,005")
        #expect(answer("1.005*1000")?.resultNote == "One thousand five")
        #expect(answer("5 - 7")?.resultNote == "Minus two")
        #expect(answer("1/4")?.resultNote == "Zero point two five")
    }

    @Test func sumsAndPercentages() {
        #expect(answer("2400*12")?.result == "28,800")
        #expect(answer("2400*12")?.copy == "28800")
        #expect(answer("2400*12")?.resultNote == "Twenty-eight thousand eight hundred")
        #expect(answer("sqrt(16)")?.result == "4")
        #expect(answer("2pi")?.result == "6.283185")
        #expect(answer("20% of 80")?.result == "16")
        #expect(answer("80 + 15%")?.result == "92")
        #expect(answer("15% off 80")?.result == "68")
        #expect(answer("255 in hex")?.result == "0xFF")
        #expect(answer("0xff")?.result == "255")
    }

    /// A hex number written with only the digits 0 to 9 is still a hex
    /// number: "0x10" was read as 0 × 10, so the field answered 0.
    @Test func aHexNumberInDecimalDigitsIsNotASum() {
        #expect(answer("0x10")?.result == "16")
        #expect(answer("0x10")?.kind == .numberBase)
        #expect(answer("0x400")?.result == "1,024")
        #expect(answer("0x400")?.copy == "1024")
        #expect(answer("0x10+1") == nil)
        // A sum with an x for times is still one.
        #expect(answer("10x10")?.result == "100")
        #expect(answer("1.0x10")?.result == "10")
        #expect(answer("0 x 10")?.result == "0")
    }

    /// A comma groups thousands, or lakhs, only where it can. One that
    /// can't is the decimal point it is in much of the world: "1,5" and
    /// "3,14" were fifteen and 314, so 1,5 kg was 33 pounds. Digits that
    /// read no way at all have no answer rather than a wrong one.
    @Test func aCommaThatCantGroupIsADecimalPoint() {
        #expect(answer("1,5+1")?.result == "2.5")
        #expect(answer("3,14*2")?.result == "6.28")
        #expect(answer("1,5 kg in lb")?.result == "3.3069 lb")
        #expect(answer("0,5 l in ml")?.result == "500 ml")
        #expect(answer("12,5% of 200")?.result == "25")
        #expect(answer("1.234,56*2")?.result == "2,469.12")
        #expect(answer("1.234,56 + 10%")?.result == "1,358.02")
        #expect(answer("1,000,000/2")?.result == "500,000")
        #expect(answer("1,234.5*2")?.result == "2,469")
        #expect(answer("1,23,456+1")?.result == "123,457")
        #expect(answer("1,500 kg in g")?.result == "1,500,000 g")
        #expect(answer("1,2,3+1") == nil)
        #expect(answer(",5+1") == nil)
        #expect(answer("1,234.5,6+1") == nil)
    }

    @Test func units() {
        #expect(answer("5 km to mi")?.result == "3.1069 mi")
        #expect(answer("72f in c")?.result == "22.2222°C")
        #expect(answer("100 c to f")?.result == "212°F")
        #expect(answer("1.5 gb in mb")?.result == "1,500 MB")
        #expect(answer("5 in in cm")?.result == "12.7 cm")
        #expect(answer("10 pounds in kg")?.result == "4.5359 kg")
        #expect(answer("3 days in hours")?.result == "72 h")
        // Not of one kind: not an answer.
        #expect(answer("5 km to kg") == nil)
        #expect(answer("5 KM TO MI")?.result == "3.1069 mi")
    }

    /// "İ" lowercases longer, "i̇": the words are cut at their own places,
    /// not a lowercased copy's, which crashed in 0.0.3 on typed and selected
    /// words alike.
    @Test func lettersThatLowercaseLonger() {
        #expect(Calc.split("İİ to x").map { [$0.0, $0.1] } == [["İİ", "x"]])
        #expect(Calc.split("İstanbul in summer").map { [$0.0, $0.1] } == [["İstanbul", "summer"]])
        #expect(answer("İİ to x") == nil)
    }

    @Test func money() {
        #expect(answer("100 usd in eur")?.result == "€90.00")
        #expect(answer("100 usd in eur")?.questionNote == "US Dollar")
        #expect(answer("$50 to rub")?.result == "₽4,500.00")
        #expect(answer("100 dollars in rubles")?.result == "₽9,000.00")
        #expect(answer("1.5k eur to usd")?.result == "$1,666.67")
        #expect(answer("10 pounds in eur")?.result == "€11.25")
        #expect(answer("1 btc in usd")?.result == "$100,000.00")
        #expect(answer("btc to usd")?.result == "$100,000.00")
        #expect(answer("BTC in USD")?.questionNote == "Bitcoin")
        #expect(answer("euros to rub")?.result == answer("1 eur to rub")?.result)
        #expect(answer("€40") != nil)
    }

    @Test func cryptoStablecoinsSatoshisAndSriLankanRupees() {
        let rates = Rates(kept: false)
        // Deliberately off the dollar peg: stablecoins use their real quote.
        rates.set(["BTC": 0.00001, "ETH": 0.0005, "USDT": 1.01, "USDC": 0.99, "LKR": 300])
        func converted(_ words: String) -> Calc.Answer? { Calc.answer(words, now: noon, rates: rates) }
        #expect(converted("1 bitcoin in sats")?.result == "100,000,000 sats")
        #expect(converted("1000 satoshis to btc")?.copy == "0.00001")
        #expect(converted("100 sats to usd")?.copy == "0.1")
        #expect(converted("1 usd to sats")?.copy == "1000")
        #expect(converted("100 usd to lkr")?.copy == "30000")
        #expect(converted("300 sri lankan rupees in usd")?.copy == "1")
        #expect(converted("100 usd in tether")?.copy == "101")
        #expect(converted("100 usd to usd coin")?.copy == "99")
        #expect(converted("1 ethereum in usd")?.copy == "2000")
        #expect(converted("1 BTC in ETH")?.copy == "50")
        #expect(converted("100 usd in usdt")?.copy != "100")
    }

    @Test func satoshisNeverInventRatesOrTreatInvalidQuotesAsMoney() async {
        let rates = Rates(kept: false)
        rates.fetch = { nil }
        await rates.warm()?.value
        let missing = Calc.answer("100 sats in usd", now: noon, rates: rates)
        #expect(missing?.resultNote == "Rates unavailable")
        #expect(missing?.copy.isEmpty == true)
        for invalid in [0.0, -1.0, Double.infinity, Double.nan] {
            rates.set(["BTC": invalid, "LKR": invalid])
            #expect(rates.convert(1, from: "USD", to: "SAT") == nil)
            #expect(rates.convert(1, from: "LKR", to: "USD") == nil)
        }
    }

    /// A code that is a word too is a currency only in capitals and asked
    /// into another; an amount alone needs a sign, a name or a code people
    /// ask about.
    @Test func wordsAreNotCurrencies() {
        for words in ["top 10", "link 2", "all 5", "time 3", "pro 20", "amd 9950", "europe 2", "bucket 5", "10 top",
                      "100 link in usd", "100 LINK"] {
            #expect(answer(words) == nil, "\(words)")
        }
        for words in ["100 usd", "€40", "100 eur in usd", "0.5 btc", "20 euros", "5 bucks", "100 LINK in usd", "1000 AMD to usd"] {
            #expect(answer(words) != nil, "\(words)")
        }
        #expect(answer("100 LINK in usd")?.result == "$2,000.00")
    }

    /// A question asked again a minute on is worked out again: the time
    /// somewhere is the moment's.
    @Test func theTimeIsTheMoments() {
        #expect(Calc.answer("time in tokyo", now: noon, rates: Self.rates)?.result == "8:00 PM")
        #expect(Calc.answer("time in tokyo", now: noon.addingTimeInterval(3600), rates: Self.rates)?.result == "9:00 PM")
    }

    /// Offline, rates are asked for again only after a wait that grows, and
    /// the card is told once, when "Getting rates" becomes "unavailable".
    @Test func failedRatesWaitBeforeAskingAgain() async {
        let rates = Rates(kept: false)
        var asked = 0, told = 0
        rates.fetch = {
            asked += 1
            return nil
        }
        rates.came = { told += 1 }
        let start = Date(timeIntervalSince1970: 1_790_334_000)
        await rates.warm(at: start)?.value
        #expect(asked == 1 && told == 1 && rates.failed)
        let version = rates.version
        #expect(rates.warm(at: start.addingTimeInterval(1)) == nil)
        #expect(rates.warm(at: start.addingTimeInterval(59)) == nil)
        await rates.warm(at: start.addingTimeInterval(61))?.value
        #expect(asked == 2 && told == 1 && rates.version == version)
        #expect(rates.retryAt == start.addingTimeInterval(61 + 120))
        for _ in 0 ..< 6 { await rates.warm(at: rates.retryAt!)?.value }
        let last = rates.retryAt!
        await rates.warm(at: last)?.value
        #expect(rates.retryAt == last.addingTimeInterval(900))
        #expect(asked == 9 && told == 1)
        rates.fetch = { #"{"data":{"rates":{"EUR":"0.9"}}}"#.data(using: .utf8) }
        await rates.warm(at: last.addingTimeInterval(900))?.value
        #expect(told == 2 && !rates.failed && rates.retryAt == nil && rates.convert(10, from: "USD", to: "EUR") == 9)
    }

    @Test func timeElsewhere() {
        #expect(answer("time in tokyo")?.result == "8:00 PM")
        #expect(answer("tokyo time")?.resultNote.hasPrefix("Tokyo · Fri, Sep 25 · UTC+9") == true)
        #expect(answer("3pm london in sf")?.result == "7:00 AM")
        #expect(answer("15:00 msk to pst")?.result == "5:00 AM")
    }

    @Test func days() {
        #expect(answer("days until christmas")?.result == "91 days")
        #expect(answer("in 3 weeks")?.result == "Oct 16, 2026")
        #expect(answer("10 days ago")?.result == "Sep 15, 2026")
        #expect(answer("days until new year")?.result == "98 days")
    }

    /// A day some way off is answered when it can be written right, past
    /// the year 9999 too. Before year 1 the year came out without its era,
    /// from ten million years on as nothing, and a count that made the
    /// product reach Int.max answered today, or crashed the field past it.
    @Test func aDayTooFarOffHasNoAnswer() {
        #expect(answer("2025 years ago")?.result == "Sep 25, 0001")
        #expect(answer("in 7974 years")?.result == "Sep 25, 10000")
        #expect(answer("2026 years ago") == nil)
        #expect(answer("3000 years ago") == nil)
        #expect(answer("in 10000000 years") == nil)
        #expect(answer("in 1317624576693539401 weeks") == nil)
        #expect(answer("in 1317624576693539402 weeks") == nil)
    }

    /// Words that can't be a question aren't read as one at all, and every
    /// kind of question still gets past the first look.
    @Test func onlyWhatCouldBeAQuestionIsRead() {
        for words in ["github", "how to cook rice", "news.ycombinator.com", "swift concurrency", "in the morning", "time",
                      "tokyo", "claude code", "days", "weather tomorrow", "now what", "how to cook rice", "usd", "ways to save euros"] {
            #expect(!Calc.asks(words), "\(words)")
            #expect(answer(words) == nil, "\(words)")
        }
        for words in ["2400*12", "20% of 80", "5 km to mi", "100 usd in eur", "€40", "$50 to rub", "255 in hex", "0xff",
                      "time in tokyo", "tokyo time", "3pm london in sf", "days until christmas",
                      "days until new year", "in 3 weeks", "10 days ago", "pi*2", "sqrt(pi)", "2pi", "btc to usd", "euros in dollars"] {
            #expect(Calc.asks(words), "\(words)")
            #expect(answer(words) != nil, "\(words)")
        }
    }

    /// The field's words with a space after them are the same question.
    @Test func aTrailingSpaceIsTheSameQuestion() {
        #expect(answer("5 km to mi ")?.result == "3.1069 mi")
        #expect(answer("5 km to mi")?.result == "3.1069 mi")
    }

    @Test func wordsThatAreNotQuestions() {
        for words in ["github", "2024", "10.0.0.1", "localhost:3000", "how to cook rice", "3 in a row", "5 km",
                      "in the morning", "time", "tokyo", "iphone 15 to 16", "v2-alpha", "12"] {
            #expect(answer(words) == nil, "\(words)")
        }
    }
}
