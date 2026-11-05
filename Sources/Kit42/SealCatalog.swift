import Foundation

/// Catalogue of stamp and seal templates by region and purpose. Generic company, personal and office stamps only:
/// no state emblems, and no notary, court, customs, police or medical-prescription seals.
///
/// Every text on a stamp is a field the user can edit; the template gives an example. Fields: `key`, English label
/// (translated in Kit42/Strings.swift) and example text.
public enum SealCategory: Int, CaseIterable {
    case cis, europe, uk, turkey, americas, hongKong, china, japan, korea, southAsia, middleEast, latinAmerica,
         office, dates, personal

    public var title: String {
        switch self {
        case .cis: return L("Russia and CIS")
        case .europe: return L("Europe")
        case .uk: return L("United Kingdom and Ireland")
        case .turkey: return L("Turkey")
        case .americas: return L("USA and Canada")
        case .hongKong: return L("Hong Kong and Taiwan")
        case .china: return L("Mainland China")
        case .japan: return L("Japan")
        case .korea: return L("Korea")
        case .southAsia: return L("India and South Asia")
        case .middleEast: return L("Middle East")
        case .latinAmerica: return L("Latin America")
        case .office: return L("Office stamps")
        case .dates: return L("Date and registration stamps")
        case .personal: return L("Personal stamps")
        }
    }
}

public struct SealField {
    public let key: String
    public let label: String
    public let example: String
    public let multiline: Bool
}

/// Families of layouts the renderer knows (SealGenerator); each template is one family with its options.
enum SealLayout {
    enum Ring { case solid, thick, thin, dotted, rope, serrated, stars }
    enum Edge { case full, topBottom, top }
    enum Centre { case lines, star, vertical, grid, initials }
    struct Round {
        var ring: Ring = .solid
        var double = true
        var edge: Edge = .full
        var inner = false            // second, smaller ring of text ("inner" field)
        var centre: Centre = .lines
        var font = "HelveticaNeue-CondensedBold"
        var centreFont = "HelveticaNeue-Bold"
        var small = false            // small round chop: one ring, larger letters
    }
    enum Frame { case none, single, double, rounded, thick }
    enum Row {
        case text(String, font: String, size: CGFloat, upper: Bool)
        case space(CGFloat)
        case line(CGFloat)           // signature line, fraction of the width
        case divider
    }
    struct Rect {
        var rows: [Row]
        var frame: Frame = .none
        var left = false
        var width: CGFloat = 1300
    }
    struct Word {
        var frame: Frame = .double
        var rounded = true
        var font = "HelveticaNeue-CondensedBlack"
    }
    enum Shape { case square, round, oval }
    struct Grid {
        var shape: Shape = .square
        var font = "STSongti-SC-Black"
        var frame: CGFloat = 26
        var perColumn: Int? = nil
    }
    case round(Round), oval(Round), rect(Rect), word(Word), grid(Grid), dater(String), table, triangle
}

public struct SealTemplate {
    public let id: String
    public let category: SealCategory
    let titleRow: [String]
    public let fields: [SealField]
    public let ink: InkColor
    let layout: SealLayout

    public var title: String { L(titleRow[0]) }

    /// Tilt range in radians: rectangular stamps are aligned by eye along the text, round ones are not.
    var tilt: ClosedRange<CGFloat> {
        switch layout {
        case .rect, .table: return 0.005...0.035
        case .word: return 0.02...0.12
        default: return 0.035...0.14
        }
    }

    public func example(_ key: String) -> String { fields.first { $0.key == key }?.example ?? "" }
}

extension SealTemplate {
    public static let all: [SealTemplate] = {
        Localization.register(rows: SealCatalog.templates.map(\.titleRow))
        return SealCatalog.templates
    }()

    public static func named(_ id: String) -> SealTemplate? { all.first { $0.id == id } }
}

enum SealCatalog {
    // Fonts
    static let cond = "HelveticaNeue-CondensedBold", sans = "HelveticaNeue-Bold", medium = "HelveticaNeue-Medium"
    static let serif = "TimesNewRomanPS-BoldMT", black = "HelveticaNeue-CondensedBlack", mono = "Courier-Bold"
    static let song = "STSongti-SC-Black", songTC = "STSongti-TC-Bold", mincho = "HiraMinProN-W6"
    static let hangul = "AppleMyungjo", hangulSans = "AppleSDGothicNeo-Bold", arabic = "GeezaPro-Bold", hebrew = "ArialHebrew-Bold"

    // Field helpers
    static func f(_ key: String, _ label: String, _ example: String, multiline: Bool = false) -> SealField {
        SealField(key: key, label: label, example: example, multiline: multiline)
    }
    static func edge(_ s: String) -> SealField { f("edge", "Text around the edge", s) }
    static func top(_ s: String) -> SealField { f("edge", "Text around the top", s) }
    static func bottom(_ s: String) -> SealField { f("bottom", "Text around the bottom", s) }
    static func inner(_ s: String) -> SealField { f("inner", "Inner ring (optional)", s) }
    static func centre(_ s: String) -> SealField { f("centre", "Centre text", s, multiline: true) }
    static func name(_ s: String) -> SealField { f("name", "Company name", s) }
    static func lines(_ s: String) -> SealField { f("lines", "Address lines", s, multiline: true) }
    static func numbers(_ s: String) -> SealField { f("numbers", "Registration numbers", s, multiline: true) }
    static func word(_ s: String) -> SealField { f("word", "Main word", s) }
    static func date(_ s: String = "") -> SealField { f("date", "Date or note (empty: today)", s) }
    static func caption(_ s: String) -> SealField { f("caption", "Caption", s) }
    static func toprow(_ s: String) -> SealField { f("top", "Top line (optional)", s) }
    static func chars(_ s: String) -> SealField { f("chars", "Characters", s) }

    // Row helpers
    static func t(_ key: String, _ size: CGFloat, _ font: String = medium, upper: Bool = false) -> SealLayout.Row {
        .text(key, font: font, size: size, upper: upper)
    }

    static func round(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, _ fields: [SealField],
                      _ r: SealLayout.Round = .init()) -> SealTemplate {
        SealTemplate(id: id, category: c, titleRow: title, fields: fields, ink: ink, layout: .round(r))
    }
    static func oval(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, _ fields: [SealField],
                     _ r: SealLayout.Round = .init(edge: .topBottom)) -> SealTemplate {
        SealTemplate(id: id, category: c, titleRow: title, fields: fields, ink: ink, layout: .oval(r))
    }
    static func rect(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, _ fields: [SealField],
                     _ rows: [SealLayout.Row], frame: SealLayout.Frame = .none, left: Bool = false, width: CGFloat = 1300) -> SealTemplate {
        SealTemplate(id: id, category: c, titleRow: title, fields: fields, ink: ink,
                     layout: .rect(.init(rows: rows, frame: frame, left: left, width: width)))
    }
    static func word(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, _ w: String, top: String = "",
                     date: String = "", _ style: SealLayout.Word = .init()) -> SealTemplate {
        SealTemplate(id: id, category: c, titleRow: title, fields: [toprow(top), word(w), Self.date(date)], ink: ink, layout: .word(style))
    }
    static func grid(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, _ example: String,
                     _ g: SealLayout.Grid = .init()) -> SealTemplate {
        SealTemplate(id: id, category: c, titleRow: title, fields: [chars(example)], ink: ink, layout: .grid(g))
    }

    // Standard rectangular company stamp: bold name, address lines, registration numbers.
    static func company(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, name n: String, lines l: String,
                        numbers num: String, frame: SealLayout.Frame = .none, left: Bool = false, upper: Bool = false) -> SealTemplate {
        rect(id, c, title, ink, [name(n), lines(l), numbers(num)],
             [t("name", 92, sans, upper: upper), t("lines", 62), t("numbers", 52)], frame: frame, left: left)
    }

    // "For and on behalf of … Authorised Signature" chops.
    static func behalf(_ id: String, _ c: SealCategory, _ title: [String], _ ink: InkColor, top tp: String, name n: String,
                       local: String?, caption cap: String, frame: SealLayout.Frame = .none) -> SealTemplate {
        var fields = [toprow(tp), name(n)]
        var rows: [SealLayout.Row] = [t("top", 50), t("name", 84, sans, upper: true)]
        if let local { fields.append(f("local", "Name in local script", local)); rows.append(t("local", 74, songTC)) }
        fields.append(caption(cap))
        rows += [.space(150), .line(0.62), t("caption", 48)]
        return rect(id, c, title, ink, fields, rows, frame: frame)
    }

    static let templates: [SealTemplate] = [
        // MARK: Russia and CIS
        round("ru.ooo", .cis, ["Round seal with registration ring", "Круглая печать с кольцом ОГРН/ИНН", "Sicil halkalı yuvarlak mühür"], .violet,
              [edge("ООО «РОМАШКА» * г. МОСКВА *"), inner("ОГРН 1234567890123 * ИНН 7700000000"), centre("ДЛЯ\nДОКУМЕНТОВ")],
              .init(inner: true)),
        round("ru.simple", .cis, ["Round company seal", "Круглая печать организации", "Yuvarlak şirket mührü"], .blue,
              [edge("ОБЩЕСТВО С ОГРАНИЧЕННОЙ ОТВЕТСТВЕННОСТЬЮ * МОСКВА *"), centre("«РОМАШКА»\nИНН 7700000000")], .init(double: false)),
        round("ru.ip", .cis, ["Sole proprietor seal", "Печать ИП", "Şahıs işletmesi mührü"], .blue,
              [edge("ИНДИВИДУАЛЬНЫЙ ПРЕДПРИНИМАТЕЛЬ * г. КАЗАНЬ *"), inner("ОГРНИП 312345678901234"), centre("ИВАНОВ\nИВАН\nИВАНОВИЧ")],
              .init(inner: true)),
        round("ru.stars", .cis, ["Round seal with star border", "Круглая печать с каймой из звёзд", "Yıldız kenarlı yuvarlak mühür"], .violet,
              [edge("ООО «ВЕКТОР» * САНКТ-ПЕТЕРБУРГ *"), centre("ДЛЯ\nСЧЕТОВ")], .init(ring: .stars)),
        round("ru.rope", .cis, ["Round seal with rope border", "Круглая печать с витой каймой", "Burgu kenarlı yuvarlak mühür"], .blue,
              [edge("АО «СЕВЕР» * НОВОСИБИРСК *"), centre("ОТДЕЛ\nКАДРОВ")], .init(ring: .rope)),
        round("ru.dotted", .cis, ["Round seal with dotted ring", "Круглая печать с точечным кольцом", "Noktalı halkalı yuvarlak mühür"], .violet,
              [edge("ООО «ЗАРЯ» * ЕКАТЕРИНБУРГ *"), inner("ИНН 6600000000 * КПП 660001001"), centre("БУХГАЛТЕРИЯ")],
              .init(ring: .dotted, inner: true)),
        round("ru.small", .cis, ["Small round stamp", "Малая круглая печать", "Küçük yuvarlak kaşe"], .blue,
              [edge("ООО «РОМАШКА» * МОСКВА *"), centre("ДЛЯ\nПАКЕТОВ")], .init(double: false, small: true)),
        oval("ru.oval", .cis, ["Oval stamp", "Овальный штамп", "Oval kaşe"], .violet,
             [top("ООО «РОМАШКА»"), bottom("г. МОСКВА"), centre("ДЛЯ\nДОКУМЕНТОВ")]),
        rect("ru.corner", .cis, ["Corner stamp", "Угловой штамп", "Antet kaşesi"], .blue,
             [name("ООО «РОМАШКА»"), lines("125009, г. Москва, ул. Тверская, д. 1\nтел. +7 495 000-00-00"),
              numbers("ИНН 7700000000 / КПП 770001001"), f("ref", "Reference line", "Исх. № ______ от «___» ________ 20__ г.")],
             [t("name", 80, sans, upper: true), t("lines", 50), t("numbers", 48), .space(20), t("ref", 48)]),
        rect("ru.copy", .cis, ["“Certified copy” stamp", "Штамп «Копия верна»", "“Aslı gibidir” kaşesi (RU)"], .blue,
             [word("КОПИЯ ВЕРНА"), f("position", "Position", "Генеральный директор"),
              f("sign", "Signature line", "________________ / И. И. Иванов /"), date("«___» ____________ 20__ г.")],
             [t("word", 96, sans), t("position", 54), t("sign", 54), t("date", 54)], left: true),
        rect("ru.incoming", .cis, ["Incoming document stamp", "Штамп входящего документа", "Gelen evrak kaşesi (RU)"], .blue,
             [name("ООО «РОМАШКА»"), word("ВХОДЯЩИЙ № ________"), date("«___» ____________ 20__ г.")],
             [t("name", 54, sans, upper: true), t("word", 74, sans), t("date", 60)], frame: .single),
        rect("ru.approve", .cis, ["“Approved” block", "Гриф «Утверждаю»", "“Onaylıyorum” bloğu"], .blue,
             [word("УТВЕРЖДАЮ"), f("position", "Position", "Генеральный директор\nООО «РОМАШКА»", multiline: true),
              f("sign", "Signature line", "____________ И. И. Иванов"), date("«___» ____________ 20__ г.")],
             [t("word", 80, sans), t("position", 56), t("sign", 56), t("date", 56)], left: true),
        rect("ru.agreed", .cis, ["“Agreed” block", "Гриф «Согласовано»", "“Mutabık kalındı” bloğu"], .blue,
             [word("СОГЛАСОВАНО"), f("position", "Position", "Главный бухгалтер", multiline: true),
              f("sign", "Signature line", "____________ П. П. Петров"), date("«___» ____________ 20__ г.")],
             [t("word", 80, sans), t("position", 56), t("sign", 56), t("date", 56)], left: true),
        word("ru.paid", .cis, ["“Paid” stamp (Russian)", "Штамп «Оплачено»", "“Ödendi” kaşesi (RU)"], .blue, "ОПЛАЧЕНО", top: "ООО «РОМАШКА»"),
        word("ru.received", .cis, ["“Received” stamp (Russian)", "Штамп «Получено»", "“Teslim alındı” kaşesi (RU)"], .violet, "ПОЛУЧЕНО", top: "ООО «РОМАШКА»"),
        SealTemplate(id: "ru.qc", category: .cis, titleRow: ["Quality control stamp", "Штамп ОТК", "Kalite kontrol kaşesi"],
                     fields: [word("ОТК"), f("number", "Number", "5")], ink: .violet, layout: .triangle),
        round("kz.round", .cis, ["Kazakhstan round seal (two languages)", "Круглая печать Казахстана (два языка)", "Kazakistan yuvarlak mühür (iki dil)"], .blue,
              [top("«ҮЛГІ» ЖШС * АЛМАТЫ"), bottom("ТОО «ОБРАЗЕЦ» * АЛМАТЫ"), centre("БСН\n123456789012")], .init(edge: .topBottom)),
        round("ua.round", .cis, ["Ukraine round seal", "Круглая печать Украины", "Ukrayna yuvarlak mühür"], .blue,
              [edge("ТОВАРИСТВО З ОБМЕЖЕНОЮ ВІДПОВІДАЛЬНІСТЮ «ЗРАЗОК»"), inner("ІДЕНТИФІКАЦІЙНИЙ КОД 12345678"), centre("м. КИЇВ")],
              .init(inner: true)),
        round("by.round", .cis, ["Belarus round seal", "Круглая печать Беларуси", "Belarus yuvarlak mühür"], .blue,
              [edge("ОБЩЕСТВО С ОГРАНИЧЕННОЙ ОТВЕТСТВЕННОСТЬЮ «ОБРАЗЕЦ»"), centre("УНП\n190000000\nг. МИНСК")]),

        // MARK: Europe
        company("de.firm", .europe, ["Company stamp (Germany)", "Штамп компании (Германия)", "Şirket kaşesi (Almanya)"], .blue,
                name: "Musterfirma GmbH", lines: "Hauptstraße 1\n10115 Berlin", numbers: "USt-IdNr. DE123456789", frame: .rounded),
        company("de.firm.plain", .europe, ["Company stamp, left aligned (Germany)", "Штамп компании, по левому краю (Германия)", "Sola hizalı şirket kaşesi (Almanya)"], .blue,
                name: "Muster & Söhne KG", lines: "Bahnhofstr. 12 · 80335 München\nTel. 089 123456", numbers: "HRA 12345 · Amtsgericht München", left: true),
        rect("de.eingang", .europe, ["“Received” date stamp (Germany)", "Штамп «Получено» с датой (Германия)", "Tarihli “Alındı” kaşesi (Almanya)"], .blue,
             [name("Musterfirma GmbH"), word("EINGANG"), date(), f("by", "Handled by", "Bearb.: ________")],
             [t("name", 52, sans), t("word", 96, black), t("date", 70, mono), t("by", 48)], frame: .double),
        company("at.firm", .europe, ["Company stamp (Austria)", "Штамп компании (Австрия)", "Şirket kaşesi (Avusturya)"], .blue,
                name: "Beispiel GmbH", lines: "Ringstraße 5, 1010 Wien", numbers: "FN 123456a · UID ATU12345678", frame: .single),
        company("ch.firm", .europe, ["Company stamp (Switzerland)", "Штамп компании (Швейцария)", "Şirket kaşesi (İsviçre)"], .black,
                name: "Muster AG", lines: "Bahnhofstrasse 10\n8001 Zürich", numbers: "UID CHE-123.456.789 MWST"),
        company("fr.tampon", .europe, ["Company stamp (France)", "Штамп компании (Франция)", "Şirket kaşesi (Fransa)"], .blue,
                name: "EXEMPLE SARL", lines: "12 rue de la Paix\n75002 Paris", numbers: "SIRET 123 456 789 00012\nTVA FR12 123456789", frame: .rounded),
        word("fr.recu", .europe, ["“Reçu le” stamp (France)", "Штамп «Получено» (Франция)", "“Alındı” kaşesi (Fransa)"], .blue, "REÇU LE", top: "EXEMPLE SARL"),
        company("it.timbro", .europe, ["Company stamp (Italy)", "Штамп компании (Италия)", "Şirket kaşesi (İtalya)"], .blue,
                name: "ESEMPIO S.R.L.", lines: "Via Roma, 1 – 00100 Roma", numbers: "P.IVA 01234567890\nC.F. 01234567890", upper: true),
        round("it.round", .europe, ["Round company seal (Italy)", "Круглая печать (Италия)", "Yuvarlak şirket mührü (İtalya)"], .blue,
              [top("ESEMPIO S.R.L."), bottom("ROMA"), centre("P.IVA\n01234567890")], .init(edge: .topBottom)),
        oval("es.sello", .europe, ["Oval company stamp (Spain)", "Овальный штамп (Испания)", "Oval şirket kaşesi (İspanya)"], .blue,
             [top("EJEMPLO S.L."), bottom("MADRID"), centre("CIF B12345678")]),
        company("es.rect", .europe, ["Company stamp (Spain)", "Штамп компании (Испания)", "Şirket kaşesi (İspanya)"], .blue,
                name: "EJEMPLO S.L.", lines: "C/ Mayor, 1 · 28013 Madrid", numbers: "CIF B12345678", frame: .single, upper: true),
        company("pt.carimbo", .europe, ["Company stamp (Portugal)", "Штамп компании (Португалия)", "Şirket kaşesi (Portekiz)"], .blue,
                name: "EXEMPLO, LDA.", lines: "Rua Augusta, 1 · 1100-048 Lisboa", numbers: "NIF 501234567", frame: .rounded),
        company("pl.pieczatka", .europe, ["Company stamp (Poland)", "Штамп компании (Польша)", "Şirket kaşesi (Polonya)"], .blue,
                name: "PRZYKŁAD Sp. z o.o.", lines: "ul. Marszałkowska 1, 00-001 Warszawa", numbers: "NIP 123-456-78-90 · REGON 123456789"),
        company("cz.razitko", .europe, ["Company stamp (Czechia, Slovakia)", "Штамп компании (Чехия, Словакия)", "Şirket kaşesi (Çekya, Slovakya)"], .blue,
                name: "Příklad s.r.o.", lines: "Václavské nám. 1, 110 00 Praha 1", numbers: "IČ 12345678 · DIČ CZ12345678", frame: .single),
        company("nl.stempel", .europe, ["Company stamp (Netherlands, Belgium)", "Штамп компании (Нидерланды, Бельгия)", "Şirket kaşesi (Hollanda, Belçika)"], .blue,
                name: "Voorbeeld B.V.", lines: "Damrak 1, 1012 LG Amsterdam", numbers: "KvK 12345678 · BTW NL123456789B01"),
        company("nordic.stamp", .europe, ["Company stamp (Nordic countries)", "Штамп компании (Скандинавия)", "Şirket kaşesi (İskandinav ülkeleri)"], .black,
                name: "Exempel AB", lines: "Drottninggatan 1, 111 51 Stockholm", numbers: "Org.nr 556123-4567", left: true),
        company("gr.stamp", .europe, ["Company stamp (Greece)", "Штамп компании (Греция)", "Şirket kaşesi (Yunanistan)"], .blue,
                name: "ΠΑΡΑΔΕΙΓΜΑ Α.Ε.", lines: "Οδός Ερμού 1, 105 63 Αθήνα", numbers: "ΑΦΜ 123456789 · ΔΟΥ Α' Αθηνών", upper: true),
        round("eu.round", .europe, ["Round company seal (Europe)", "Круглая печать (Европа)", "Yuvarlak şirket mührü (Avrupa)"], .blue,
              [edge("EXAMPLE TRADING S.A. * BRUXELLES *"), centre("TVA\nBE 0123.456.789")], .init(ring: .dotted)),

        // MARK: United Kingdom and Ireland
        round("uk.common", .uk, ["Common seal (UK)", "Общая печать компании (Великобритания)", "Ortak mühür (Birleşik Krallık)"], .black,
              [edge("THE COMMON SEAL OF EXAMPLE TRADING LIMITED *"), centre("Company No.\n01234567")], .init(ring: .rope, font: serif, centreFont: serif)),
        company("uk.company", .uk, ["Company stamp (UK)", "Штамп компании (Великобритания)", "Şirket kaşesi (Birleşik Krallık)"], .blue,
                name: "Example Trading Ltd", lines: "1 High Street, London EC1A 1AA", numbers: "Registered in England No. 01234567\nVAT No. GB 123 4567 89"),
        oval("uk.received", .uk, ["Oval “Received” stamp", "Овальный штамп «Получено»", "Oval “Alındı” kaşesi"], .blue,
             [top("EXAMPLE TRADING LTD"), bottom("LONDON"), centre("RECEIVED")]),
        word("uk.paid", .uk, ["“Paid” stamp (UK)", "Штамп «Paid» (Великобритания)", "“Paid” kaşesi (Birleşik Krallık)"], .red, "PAID", top: "EXAMPLE TRADING LTD"),
        company("ie.company", .uk, ["Company stamp (Ireland)", "Штамп компании (Ирландия)", "Şirket kaşesi (İrlanda)"], .green,
                name: "Example Holdings DAC", lines: "1 Grafton Street, Dublin 2", numbers: "CRO No. 123456 · VAT IE1234567T", frame: .single),

        // MARK: Turkey
        rect("tr.kase", .turkey, ["Kaşe (company stamp)", "Каше (штамп компании)", "Şirket kaşesi"], .violet,
             [name("ÖRNEK TİCARET LTD. ŞTİ."), lines("Atatürk Cad. No: 1\nKadıköy / İSTANBUL"), numbers("Kadıköy V.D. 1234567890")],
             [t("name", 88, sans, upper: true), t("lines", 62), t("numbers", 54)]),
        rect("tr.kase.framed", .turkey, ["Framed kaşe", "Каше в рамке", "Çerçeveli kaşe"], .blue,
             [name("ÖRNEK İNŞAAT A.Ş."), lines("Cumhuriyet Mah. 1. Sok. No: 5\nÇankaya / ANKARA"), numbers("Çankaya V.D. 1234567890\nMersis No: 0123456789000015")],
             [t("name", 84, sans, upper: true), .divider, t("lines", 56), t("numbers", 50)], frame: .single),
        rect("tr.sahis", .turkey, ["Sole trader kaşe", "Каше индивидуального предпринимателя", "Şahıs şirketi kaşesi"], .blue,
             [name("AHMET YILMAZ"), lines("Örnek Ticaret\nKonak / İZMİR"), numbers("Konak V.D. 12345678901")],
             [t("name", 84, sans, upper: true), t("lines", 60), t("numbers", 52)]),
        word("tr.asli", .turkey, ["“Aslı gibidir” stamp", "Штамп «Aslı gibidir» (копия верна)", "“Aslı gibidir” kaşesi"], .blue, "ASLI GİBİDİR", top: "ÖRNEK TİCARET LTD. ŞTİ."),
        word("tr.teslim", .turkey, ["“Teslim alındı” stamp", "Штамп «Teslim alındı» (получено)", "“Teslim alındı” kaşesi"], .violet, "TESLİM ALINDI"),
        word("tr.odendi", .turkey, ["“Ödendi” stamp", "Штамп «Ödendi» (оплачено)", "“Ödendi” kaşesi"], .red, "ÖDENDİ"),
        round("tr.round", .turkey, ["Round association seal", "Круглая печать объединения", "Yuvarlak dernek mührü"], .blue,
              [top("ÖRNEK KÜLTÜR DERNEĞİ"), bottom("İSTANBUL"), centre("2026")], .init(edge: .topBottom)),

        // MARK: USA and Canada
        round("us.corporate", .americas, ["Corporate seal (USA)", "Корпоративная печать (США)", "Kurumsal mühür (ABD)"], .black,
              [top("EXAMPLE CORPORATION"), bottom("DELAWARE"), centre("CORPORATE\nSEAL\n2026")],
              .init(ring: .serrated, edge: .topBottom, font: serif, centreFont: serif)),
        round("us.corporate.plain", .americas, ["Corporate seal, plain border", "Корпоративная печать, простая кайма", "Düz kenarlı kurumsal mühür"], .black,
              [top("EXAMPLE HOLDINGS INC."), bottom("NEW YORK"), centre("SEAL\n2026")], .init(edge: .topBottom, font: serif, centreFont: serif)),
        rect("us.address", .americas, ["Address stamp", "Адресный штамп", "Adres kaşesi"], .black,
             [name("Example Company, Inc."), lines("100 Main Street, Suite 200\nSpringfield, IL 62701")],
             [t("name", 82, sans), t("lines", 62)], left: true),
        word("us.paid", .americas, ["“Paid” stamp", "Штамп «Paid»", "“Paid” kaşesi"], .red, "PAID"),
        rect("us.received", .americas, ["“Received” stamp with “By”", "Штамп «Received» с «By»", "“By” alanlı “Received” kaşesi"], .blue,
             [word("RECEIVED"), date(), f("by", "Handled by", "BY: ____________")],
             [t("word", 110, black), t("date", 70, mono), t("by", 54)], frame: .double),
        rect("us.deposit", .americas, ["“For deposit only” endorsement", "Индоссамент «For deposit only»", "“For deposit only” cirosu"], .black,
             [word("FOR DEPOSIT ONLY"), name("EXAMPLE COMPANY, INC."), f("account", "Account line", "ACCT # ____________")],
             [t("word", 74, sans), t("name", 62, medium, upper: true), t("account", 56)], frame: .single),
        round("ca.corporate", .americas, ["Corporate seal (Canada, bilingual)", "Корпоративная печать (Канада, два языка)", "Kurumsal mühür (Kanada, iki dilli)"], .black,
              [top("EXAMPLE CORPORATION"), bottom("CORPORATE SEAL · SCEAU"), centre("ONTARIO\n2026")],
              .init(ring: .serrated, edge: .topBottom, font: serif, centreFont: serif)),

        // MARK: Hong Kong and Taiwan
        behalf("hk.chop", .hongKong, ["Company chop with signature (Hong Kong)", "Чоп компании с подписью (Гонконг)", "İmzalı şirket kaşesi (Hong Kong)"], .red,
               top: "For and on behalf of", name: "EXAMPLE TRADING LIMITED", local: "例子貿易有限公司", caption: "Authorised Signature(s)"),
        behalf("hk.chop.framed", .hongKong, ["Framed company chop with signature (Hong Kong)", "Чоп компании с подписью в рамке (Гонконг)", "Çerçeveli imzalı şirket kaşesi (Hong Kong)"], .blue,
               top: "For and on behalf of", name: "EXAMPLE HOLDINGS LIMITED", local: nil, caption: "Authorized Signature(s)", frame: .single),
        behalf("hk.chop.zh", .hongKong, ["Bilingual chop with signature (Hong Kong)", "Двуязычный чоп с подписью (Гонконг)", "İki dilli imzalı kaşe (Hong Kong)"], .red,
               top: "代表 For and on behalf of", name: "EXAMPLE LIMITED", local: "例子有限公司", caption: "授權簽署 Authorised Signature(s)"),
        round("hk.round.small", .hongKong, ["Small round company chop (Hong Kong)", "Малый круглый чоп (Гонконг)", "Küçük yuvarlak şirket kaşesi (Hong Kong)"], .red,
              [edge("EXAMPLE TRADING LIMITED *"), centre("例子貿易\n有限公司")], .init(ring: .thin, double: false, centreFont: songTC, small: true)),
        round("hk.round.zh", .hongKong, ["Round chop, Chinese around (Hong Kong)", "Круглый чоп, китайский по кругу (Гонконг)", "Yuvarlak kaşe, Çince çevrede (Hong Kong)"], .red,
              [edge("例子貿易有限公司 *"), centre("EXAMPLE\nTRADING\nLIMITED")], .init(ring: .thick, double: false, font: songTC, centreFont: cond)),
        round("hk.common", .hongKong, ["Common seal (Hong Kong)", "Общая печать (Гонконг)", "Ortak mühür (Hong Kong)"], .black,
              [edge("THE COMMON SEAL OF EXAMPLE LIMITED * 例子有限公司 *"), centre("HONG KONG\n2026")], .init(ring: .rope, font: serif, centreFont: serif)),
        oval("hk.oval", .hongKong, ["Oval company chop (Hong Kong)", "Овальный чоп (Гонконг)", "Oval şirket kaşesi (Hong Kong)"], .red,
             [top("EXAMPLE TRADING LIMITED"), bottom("HONG KONG"), centre("例子貿易有限公司")], .init(edge: .topBottom, centreFont: songTC)),
        grid("tw.big", .hongKong, ["Company seal, large square (Taiwan)", "Большая квадратная печать компании (Тайвань)", "Büyük kare şirket mührü (Tayvan)"], .red,
             "範例股份有限公司", .init(shape: .square, font: songTC, frame: 30, perColumn: 4)),
        grid("tw.small", .hongKong, ["Responsible person seal, small square (Taiwan)", "Малая квадратная личная печать (Тайвань)", "Küçük kare yetkili mührü (Tayvan)"], .red,
             "王大明印", .init(shape: .square, font: songTC, frame: 22, perColumn: 2)),

        // MARK: Mainland China
        round("cn.company", .china, ["Company seal with star", "Печать компании со звездой", "Yıldızlı şirket mührü"], .red,
              [edge("示例科技有限公司")], .init(ring: .thick, double: false, edge: .top, centre: .star, font: song)),
        round("cn.contract", .china, ["Contract seal", "Печать для договоров", "Sözleşme mührü"], .red,
              [edge("示例科技有限公司"), f("bottom", "Bottom line (optional)", "合同专用章")],
              .init(ring: .thick, double: false, edge: .top, centre: .star, font: song)),
        round("cn.department", .china, ["Department seal", "Печать отдела", "Departman mührü"], .red,
              [edge("示例科技有限公司"), f("bottom", "Bottom line (optional)", "人事部")],
              .init(ring: .thick, double: false, edge: .top, centre: .star, font: song)),
        grid("cn.finance", .china, ["Finance seal, square", "Квадратная финансовая печать", "Kare finans mührü"], .red,
             "示例科技有限公司财务专用章", .init(shape: .square, font: song, frame: 26, perColumn: 4)),
        oval("cn.invoice", .china, ["Invoice seal, oval", "Овальная печать для счетов", "Oval fatura mührü"], .red,
             [top("示例科技有限公司"), f("centre", "Tax number", "91110000123456789X"), bottom("发票专用章")],
             .init(ring: .thick, double: false, edge: .topBottom, font: song, centreFont: cond)),
        grid("cn.person", .china, ["Legal representative seal, square", "Квадратная печать руководителя", "Kare yasal temsilci mührü"], .red,
             "王明之印", .init(shape: .square, font: song, frame: 20, perColumn: 2)),
        word("cn.received", .china, ["“Received” stamp (Chinese)", "Штамп «Получено» (китайский)", "“Alındı” kaşesi (Çince)"], .red, "已收讫",
             .init(frame: .double, font: song)),

        // MARK: Japan
        grid("jp.hanko", .japan, ["Personal hanko, round", "Личная печать ханко, круглая", "Kişisel hanko, yuvarlak"], .red,
             "山田", .init(shape: .round, font: mincho, frame: 26)),
        grid("jp.hanko.oval", .japan, ["Personal hanko, oval", "Личная печать ханко, овальная", "Kişisel hanko, oval"], .red,
             "佐藤", .init(shape: .oval, font: mincho, frame: 22)),
        grid("jp.kakuin", .japan, ["Company seal, square (kakuin)", "Квадратная печать компании (какуин)", "Kare şirket mührü (kakuin)"], .red,
             "株式会社見本商事之印", .init(shape: .square, font: mincho, frame: 30, perColumn: 3)),
        round("jp.maruin", .japan, ["Representative seal, round (maruin)", "Круглая печать представителя (маруин)", "Temsilci mührü, yuvarlak (maruin)"], .red,
              [edge("株式会社見本商事"), f("centre", "Centre text", "代表取締役印")],
              .init(ring: .thick, double: true, centre: .vertical, font: mincho, centreFont: mincho)),
        SealTemplate(id: "jp.date", category: .japan, titleRow: ["Date stamp (nichizuke-in)", "Датированная печать (нитидзукэ-ин)", "Tarih mührü (nichizuke-in)"],
                     fields: [f("top", "Top line (optional)", "見本商事"), date(), f("name", "Name", "山田")], ink: .red, layout: .dater(mincho)),
        SealTemplate(id: "jp.uketsuke", category: .japan, titleRow: ["“Received” date stamp (uketsuke)", "Штамп «Принято» с датой (укэцукэ)", "Tarihli “Alındı” mührü (uketsuke)"],
                     fields: [f("top", "Top line (optional)", "受付"), date(), f("name", "Name", "総務部")], ink: .red, layout: .dater(mincho)),
        rect("jp.address", .japan, ["Address stamp (Japan)", "Адресный штамп (Япония)", "Adres kaşesi (Japonya)"], .black,
             [lines("〒100-0001 東京都千代田区千代田1-1"), name("株式会社見本商事"), numbers("代表取締役　山田太郎\nTEL 03-0000-0000")],
             [t("lines", 52, mincho), t("name", 86, mincho), t("numbers", 52, mincho)], left: true),
        grid("jp.mitome", .japan, ["Small square seal (mitome)", "Малая квадратная печать (митомэ)", "Küçük kare mühür (mitome)"], .red,
             "鈴木", .init(shape: .square, font: mincho, frame: 18)),

        // MARK: Korea
        grid("kr.dojang", .korea, ["Name seal, round (dojang)", "Именная печать, круглая (доджан)", "İsim mührü, yuvarlak (dojang)"], .red,
             "김민준", .init(shape: .round, font: hangul, frame: 24)),
        grid("kr.dojang.square", .korea, ["Name seal, square (dojang)", "Именная печать, квадратная (доджан)", "İsim mührü, kare (dojang)"], .red,
             "이서연인", .init(shape: .square, font: hangul, frame: 22, perColumn: 2)),
        grid("kr.company", .korea, ["Company seal, square (jigin)", "Квадратная печать компании (чжигин)", "Kare şirket mührü (jigin)"], .red,
             "주식회사예시상사인", .init(shape: .square, font: hangul, frame: 30, perColumn: 3)),
        round("kr.round", .korea, ["Representative seal, round", "Круглая печать представителя", "Temsilci mührü, yuvarlak"], .red,
              [edge("주식회사 예시상사"), f("centre", "Centre text", "대표이사인")],
              .init(ring: .thick, double: true, centre: .vertical, font: hangulSans, centreFont: hangul)),

        // MARK: India and South Asia
        behalf("in.authorised", .southAsia, ["“For … Authorised Signatory” stamp", "Штамп «For … Authorised Signatory»", "“For … Authorised Signatory” kaşesi"], .blue,
               top: "For", name: "EXAMPLE TECHNOLOGIES PVT. LTD.", local: nil, caption: "Authorised Signatory"),
        behalf("in.proprietor", .southAsia, ["“Proprietor” stamp", "Штамп «Proprietor» (владелец)", "“Proprietor” kaşesi"], .violet,
               top: "For", name: "SHARMA TRADERS", local: nil, caption: "Proprietor"),
        round("in.round", .southAsia, ["Round company seal (India)", "Круглая печать (Индия)", "Yuvarlak şirket mührü (Hindistan)"], .blue,
              [edge("EXAMPLE TECHNOLOGIES PVT. LTD. * MUMBAI *"), centre("★")], .init(ring: .solid, centre: .lines)),
        company("in.address", .southAsia, ["Company stamp with GSTIN", "Штамп компании с GSTIN", "GSTIN'li şirket kaşesi"], .blue,
                name: "Example Technologies Pvt. Ltd.", lines: "12, M.G. Road, Bengaluru 560001", numbers: "GSTIN 29ABCDE1234F1Z5", frame: .single),
        rect("in.received", .southAsia, ["“Received” stamp with sign", "Штамп «Received» с подписью", "İmzalı “Received” kaşesi"], .blue,
             [word("RECEIVED"), date("Date: ____________"), f("sign", "Signature line", "Sign: ____________")],
             [t("word", 100, black), t("date", 56), t("sign", 56)], frame: .double),

        // MARK: Middle East
        round("ae.round", .middleEast, ["Round seal, Arabic and English", "Круглая печать, арабский и английский", "Yuvarlak mühür, Arapça ve İngilizce"], .blue,
              [top("EXAMPLE TRADING L.L.C."), bottom("DUBAI - U.A.E."), f("centre", "Name in Arabic", "مثال للتجارة\nش.ذ.م.م")],
              .init(edge: .topBottom, centreFont: arabic)),
        rect("ae.rect", .middleEast, ["Company stamp, Arabic and English", "Штамп компании, арабский и английский", "Şirket kaşesi, Arapça ve İngilizce"], .blue,
             [f("local", "Name in Arabic", "مثال للتجارة ش.ذ.م.م"), name("EXAMPLE TRADING L.L.C."), numbers("P.O. Box 12345, Dubai · TRN 100000000000003")],
             [t("local", 80, arabic), t("name", 70, sans, upper: true), t("numbers", 48)], frame: .single),
        round("sa.round", .middleEast, ["Round company seal (Saudi Arabia)", "Круглая печать (Саудовская Аравия)", "Yuvarlak şirket mührü (Suudi Arabistan)"], .green,
              [top("EXAMPLE COMPANY LTD."), bottom("C.R. 1010000000 · RIYADH"), f("centre", "Name in Arabic", "شركة مثال\nالمحدودة")],
              .init(ring: .dotted, edge: .topBottom, centreFont: arabic)),
        rect("il.stamp", .middleEast, ["Company stamp (Israel)", "Штамп компании (Израиль)", "Şirket kaşesi (İsrail)"], .blue,
             [name("דוגמה בע״מ"), lines("רחוב הרצל 1, תל אביב"), numbers("ח.פ. 512345678")],
             [t("name", 88, hebrew), t("lines", 60, hebrew), t("numbers", 56, hebrew)]),
        round("eg.round", .middleEast, ["Round company seal (Egypt)", "Круглая печать (Египет)", "Yuvarlak şirket mührü (Mısır)"], .blue,
              [top("EXAMPLE FOR TRADING S.A.E."), bottom("CAIRO"), f("centre", "Name in Arabic", "مثال للتجارة\nش.م.م")],
              .init(ring: .rope, edge: .topBottom, centreFont: arabic)),

        // MARK: Latin America
        company("mx.sello", .latinAmerica, ["Company stamp (Mexico)", "Штамп компании (Мексика)", "Şirket kaşesi (Meksika)"], .blue,
                name: "EJEMPLO S.A. DE C.V.", lines: "Av. Reforma 1, Col. Juárez, CDMX", numbers: "RFC EJE010101ABC", upper: true),
        rect("br.cnpj", .latinAmerica, ["CNPJ stamp (Brazil)", "Штамп CNPJ (Бразилия)", "CNPJ kaşesi (Brezilya)"], .blue,
             [numbers("12.345.678/0001-90"), name("EXEMPLO COMÉRCIO LTDA."), lines("Av. Paulista, 1000 – Bela Vista\nCEP 01310-100 – São Paulo – SP")],
             [t("numbers", 86, sans), t("name", 66, sans, upper: true), t("lines", 50)], frame: .thick),
        oval("ar.sello", .latinAmerica, ["Oval stamp (Argentina)", "Овальный штамп (Аргентина)", "Oval kaşe (Arjantin)"], .violet,
             [top("EJEMPLO S.R.L."), bottom("BUENOS AIRES"), centre("CUIT\n30-12345678-9")]),
        round("latam.round", .latinAmerica, ["Round company seal (Latin America)", "Круглая печать (Латинская Америка)", "Yuvarlak şirket mührü (Latin Amerika)"], .blue,
              [top("EJEMPLO S.A.C."), bottom("LIMA - PERÚ"), centre("RUC\n20123456789")], .init(edge: .topBottom)),
        word("br.recebido", .latinAmerica, ["“Recebido” stamp (Brazil)", "Штамп «Recebido» (Бразилия)", "“Recebido” kaşesi (Brezilya)"], .blue, "RECEBIDO"),
        word("es.pagado", .latinAmerica, ["“Pagado” stamp", "Штамп «Pagado» (оплачено)", "“Pagado” kaşesi"], .red, "PAGADO"),

        // MARK: Office stamps
        word("office.approved", .office, ["Approved", "Approved (утверждено)", "Approved (onaylandı)"], .red, "APPROVED", top: "EXAMPLE LTD"),
        word("office.paid", .office, ["Paid", "Paid (оплачено)", "Paid (ödendi)"], .red, "PAID"),
        word("office.received", .office, ["Received", "Received (получено)", "Received (alındı)"], .blue, "RECEIVED"),
        word("office.copy", .office, ["Copy", "Copy (копия)", "Copy (kopya)"], .red, "COPY", date: " "),
        word("office.original", .office, ["Original", "Original (оригинал)", "Original (asıl)"], .blue, "ORIGINAL", date: " "),
        word("office.confidential", .office, ["Confidential", "Confidential (конфиденциально)", "Confidential (gizli)"], .red, "CONFIDENTIAL", date: " "),
        word("office.urgent", .office, ["Urgent", "Urgent (срочно)", "Urgent (acil)"], .red, "URGENT", date: " "),
        word("office.draft", .office, ["Draft", "Draft (черновик)", "Draft (taslak)"], .blue, "DRAFT", date: " "),
        word("office.rejected", .office, ["Rejected", "Rejected (отклонено)", "Rejected (reddedildi)"], .red, "REJECTED"),
        word("office.void", .office, ["Void", "Void (аннулировано)", "Void (geçersiz)"], .red, "VOID", date: " "),
        word("office.cancelled", .office, ["Cancelled", "Cancelled (отменено)", "Cancelled (iptal)"], .red, "CANCELLED"),
        word("office.posted", .office, ["Posted", "Posted (проведено)", "Posted (işlendi)"], .blue, "POSTED"),
        word("office.entered", .office, ["Entered", "Entered (внесено)", "Entered (girildi)"], .green, "ENTERED"),
        word("office.checked", .office, ["Checked", "Checked (проверено)", "Checked (kontrol edildi)"], .green, "CHECKED"),
        word("office.faxed", .office, ["Faxed", "Faxed (отправлено по факсу)", "Faxed (fakslandı)"], .blue, "FAXED"),
        word("office.scanned", .office, ["Scanned", "Scanned (отсканировано)", "Scanned (tarandı)"], .blue, "SCANNED"),
        word("office.completed", .office, ["Completed", "Completed (выполнено)", "Completed (tamamlandı)"], .green, "COMPLETED"),
        word("office.sample", .office, ["Sample", "Sample (образец)", "Sample (numune)"], .red, "SAMPLE", date: " "),
        word("office.ru.copy", .office, ["“Копия” (Russian)", "«Копия»", "“Копия” (Rusça)"], .blue, "КОПИЯ", date: " "),
        word("office.ru.urgent", .office, ["“Срочно” (Russian)", "«Срочно»", "“Срочно” (Rusça)"], .red, "СРОЧНО", date: " "),
        word("office.tr.onay", .office, ["“Onaylandı” (Turkish)", "«Onaylandı» (утверждено)", "“Onaylandı”"], .red, "ONAYLANDI"),
        word("office.tr.gizli", .office, ["“Gizli” (Turkish)", "«Gizli» (конфиденциально)", "“Gizli”"], .red, "GİZLİ", date: " "),

        // MARK: Date and registration stamps
        round("date.round", .dates, ["Round date stamp", "Круглый датер", "Yuvarlak tarih kaşesi"], .blue,
              [top("EXAMPLE TRADING LTD"), bottom("RECEIVED"), f("centre", "Date or note (empty: today)", "")],
              .init(edge: .topBottom, centre: .lines, centreFont: mono)),
        rect("date.rect", .dates, ["Received date stamp with reference", "Штамп получения с датой и номером", "Tarih ve numaralı alındı kaşesi"], .blue,
             [name("EXAMPLE TRADING LTD"), word("RECEIVED"), date(), f("ref", "Reference line", "Ref. No. ____________")],
             [t("name", 50, sans), t("word", 84, black), t("date", 74, mono), t("ref", 50)], frame: .rounded),
        SealTemplate(id: "date.table", category: .dates, titleRow: ["Approval table", "Таблица согласования", "Onay tablosu"],
                     fields: [f("top", "Top line (optional)", "APPROVAL"), f("rows", "Rows", "Prepared by\nChecked by\nApproved by", multiline: true)],
                     ink: .blue, layout: .table),
        SealTemplate(id: "date.table.ru", category: .dates, titleRow: ["Registration table (Russian)", "Регистрационная таблица", "Kayıt tablosu (Rusça)"],
                     fields: [f("top", "Top line (optional)", "ООО «РОМАШКА»"), f("rows", "Rows", "Вх. №\nДата\nПодпись", multiline: true)],
                     ink: .violet, layout: .table),
        round("date.qc", .dates, ["Round inspection stamp", "Круглый штамп контроля", "Yuvarlak muayene kaşesi"], .green,
              [top("QUALITY CONTROL"), bottom("INSPECTOR"), centre("PASSED\n07")], .init(ring: .thin, double: true, edge: .topBottom)),

        // MARK: Personal stamps
        rect("personal.name", .personal, ["Name and position", "Имя и должность", "Ad ve unvan"], .blue,
             [name("Ivan Petrov"), f("position", "Position", "Managing Director")],
             [t("name", 92, sans), t("position", 62)], left: true),
        rect("personal.address", .personal, ["Return address", "Обратный адрес", "Dönüş adresi"], .black,
             [name("Anna Schmidt"), lines("Lindenweg 7\n12345 Musterstadt")], [t("name", 76, sans), t("lines", 60)], left: true),
        round("personal.monogram", .personal, ["Round monogram", "Круглая монограмма", "Yuvarlak monogram"], .blue,
              [edge("IVAN PETROV * MOSCOW *"), f("centre", "Initials", "IP")], .init(ring: .dotted, double: false, centre: .initials, centreFont: serif)),
        round("personal.exlibris", .personal, ["Book stamp (ex libris)", "Книжный штамп (экслибрис)", "Kitap kaşesi (ex libris)"], .black,
              [top("EX LIBRIS"), bottom("ANNA SCHMIDT"), centre("❦")], .init(ring: .rope, edge: .topBottom, font: serif, centreFont: serif)),
        grid("personal.seal.cjk", .personal, ["Name seal, square (any script)", "Именная квадратная печать (любой алфавит)", "Kare isim mührü (herhangi bir yazı)"], .red,
             "ANNA", .init(shape: .square, font: serif, frame: 22, perColumn: 2)),
    ]
}
