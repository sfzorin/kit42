import Kit42
import Foundation

/// One end of a reference: A1, $A$1, A:A (whole column), 3:3 (whole row).
struct RefPart: Hashable {
    var row: Int
    var col: Int
    var absRow = false
    var absCol = false
    var wholeColumn = false   // A:A — row is ignored
    var wholeRow = false      // 1:1 — col is ignored

    static let maxRow = 1_048_575
    static let maxCol = 16_383

    var text: String {
        if wholeColumn { return (absCol ? "$" : "") + CellRef.columnName(col) }
        if wholeRow { return (absRow ? "$" : "") + "\(row + 1)" }
        return (absCol ? "$" : "") + CellRef.columnName(col) + (absRow ? "$" : "") + "\(row + 1)"
    }
}

indirect enum Expr {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(String)
    case ref(sheet: String?, RefPart)
    case range(sheet: String?, RefPart, RefPart)
    case unary(String, Expr)
    case percent(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
    case name(String)
    case missing   // empty argument: IF(A1,,1)
    /// Array constant {1,2;3,4} (also values computed elsewhere, e.g. lifted arguments).
    case array(Matrix)
}

struct FormulaError: Error { let message: String }

/// Excel-compatible formula syntax. Accepts "," or ";" as argument separator and Russian
/// function names (СУММ, ЕСЛИ, …); stores canonical English names like Excel files do.
enum Formula {
    enum Token: Equatable {
        case number(Double), string(String), bool(Bool), error(String)
        case word(String)          // identifier / reference text
        case sheetPrefix(String)   // "Sheet1!" or "'My sheet'!"
        case op(String)
        case lparen, rparen, sep, colon
        case lbrace, rbrace, rowSep   // array constants: {1,2;3,4}
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        var braces = 0
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." || c == "$" || c == "\\" }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "\"":
                var str = ""
                i += 1
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { str.append("\""); i += 2; continue }
                        break
                    }
                    str.append(chars[i]); i += 1
                }
                guard i < chars.count else { throw FormulaError(message: "Незакрытая кавычка") }
                i += 1
                tokens.append(.string(str))
            case "'":
                var name = ""
                i += 1
                while i < chars.count {
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { name.append("'"); i += 2; continue }
                        break
                    }
                    name.append(chars[i]); i += 1
                }
                i += 1
                guard i < chars.count, chars[i] == "!" else { throw FormulaError(message: "Ожидалось ! после имени листа") }
                i += 1
                tokens.append(.sheetPrefix(name))
            case "#":
                var e = "#"
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || "/!?".contains(chars[i]) {
                    e.append(chars[i]); i += 1
                    if e.hasSuffix("!") || e.hasSuffix("?") { break }
                }
                tokens.append(.error(e.uppercased()))
            case "(": tokens.append(.lparen); i += 1
            case ")": tokens.append(.rparen); i += 1
            case "{": tokens.append(.lbrace); braces += 1; i += 1
            case "}": tokens.append(.rbrace); braces = max(0, braces - 1); i += 1
            case ";" where braces > 0: tokens.append(.rowSep); i += 1
            case ",", ";": tokens.append(.sep); i += 1
            case ":": tokens.append(.colon); i += 1
            case "+", "-", "*", "/", "^", "&", "%", "=":
                tokens.append(.op(String(c))); i += 1
            case "<", ">":
                if i + 1 < chars.count, chars[i + 1] == "=" || (c == "<" && chars[i + 1] == ">") {
                    tokens.append(.op(String([c, chars[i + 1]]))); i += 2
                } else { tokens.append(.op(String(c))); i += 1 }
            default:
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    // Number, unless it is a row reference like 3:3 (handled by parser via word)
                    var j = i
                    while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                    if j < chars.count, chars[j] == "E" || chars[j] == "e",
                       j + 1 < chars.count, chars[j + 1].isNumber || chars[j + 1] == "+" || chars[j + 1] == "-" {
                        j += 2
                        while j < chars.count, chars[j].isNumber { j += 1 }
                    }
                    let text = String(chars[i..<j])
                    var next = j
                    while next < chars.count, chars[next].isWhitespace { next += 1 }
                    if Int(text) != nil, (next < chars.count && chars[next] == ":") || tokens.last == .colon {
                        tokens.append(.word(text))   // both ends of a row range, including 1 : 3
                    } else {
                        guard let d = Double(text) else { throw FormulaError(message: "Неверное число \(text)") }
                        tokens.append(.number(d))
                    }
                    i = j
                } else if isWordChar(c) {
                    var j = i
                    while j < chars.count, isWordChar(chars[j]) { j += 1 }
                    let w = String(chars[i..<j])
                    if j < chars.count, chars[j] == "!" {
                        tokens.append(.sheetPrefix(w)); i = j + 1
                    } else {
                        tokens.append(.word(w)); i = j
                    }
                } else {
                    throw FormulaError(message: "Неожиданный символ «\(c)»")
                }
            }
        }
        return tokens
    }

    static func parse(_ formula: String) throws -> Expr {
        var text = formula
        if text.hasPrefix("=") { text.removeFirst() }
        var p = Parser(tokens: try tokenize(text))
        let e = try p.comparison()
        guard p.pos == p.tokens.count else { throw FormulaError(message: "Лишние символы в формуле") }
        return e
    }

    struct Parser {
        let tokens: [Token]
        var pos = 0

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func next() -> Token? { defer { pos += 1 }; return peek }

        mutating func comparison() throws -> Expr {
            var lhs = try concat()
            while case .op(let o)? = peek, ["=", "<>", "<", ">", "<=", ">="].contains(o) {
                pos += 1
                lhs = .binary(o, lhs, try concat())
            }
            return lhs
        }

        mutating func concat() throws -> Expr {
            var lhs = try additive()
            while case .op("&")? = peek {
                pos += 1
                lhs = .binary("&", lhs, try additive())
            }
            return lhs
        }

        mutating func additive() throws -> Expr {
            var lhs = try multiplicative()
            while case .op(let o)? = peek, o == "+" || o == "-" {
                pos += 1
                lhs = .binary(o, lhs, try multiplicative())
            }
            return lhs
        }

        mutating func multiplicative() throws -> Expr {
            var lhs = try power()
            while case .op(let o)? = peek, o == "*" || o == "/" {
                pos += 1
                lhs = .binary(o, lhs, try power())
            }
            return lhs
        }

        mutating func power() throws -> Expr {
            var lhs = try unary()
            while case .op("^")? = peek {
                pos += 1
                lhs = .binary("^", lhs, try unary())
            }
            return lhs
        }

        mutating func unary() throws -> Expr {
            if case .op(let o)? = peek, o == "-" || o == "+" {
                pos += 1
                return .unary(o, try unary())
            }
            return try postfix()
        }

        mutating func postfix() throws -> Expr {
            var e = try primary()
            while case .op("%")? = peek {
                pos += 1
                e = .percent(e)
            }
            return e
        }

        mutating func primary() throws -> Expr {
            guard let t = next() else { throw FormulaError(message: "Формула оборвана") }
            switch t {
            case .number(let d): return .number(d)
            case .string(let s): return .string(s)
            case .bool(let b): return .bool(b)
            case .error(let e): return .error(Formula.canonicalError(e))
            case .lparen:
                let e = try comparison()
                guard next() == .rparen else { throw FormulaError(message: "Не хватает «)»") }
                return e
            case .lbrace:
                var rows: [[Value]] = [[]]
                while true {
                    var negative = false
                    if case .op(let o)? = peek, o == "-" || o == "+" { negative = o == "-"; pos += 1 }
                    guard let t = next() else { throw FormulaError(message: "Не хватает «}»") }
                    switch t {
                    case .number(let d): rows[rows.count - 1].append(.number(negative ? -d : d))
                    case .string(let s): rows[rows.count - 1].append(.string(s))
                    case .bool(let b): rows[rows.count - 1].append(.bool(b))
                    case .error(let e): rows[rows.count - 1].append(.error(Formula.canonicalError(e)))
                    case .word(let w) where ["TRUE", "ИСТИНА"].contains(w.uppercased()): rows[rows.count - 1].append(.bool(true))
                    case .word(let w) where ["FALSE", "ЛОЖЬ"].contains(w.uppercased()): rows[rows.count - 1].append(.bool(false))
                    default: throw FormulaError(message: "Неверный элемент массива")
                    }
                    guard let sep = next() else { throw FormulaError(message: "Не хватает «}»") }
                    if sep == .rbrace { break }
                    if sep == .rowSep { rows.append([]); continue }
                    guard sep == .sep else { throw FormulaError(message: "Неверный массив") }
                }
                let cols = rows[0].count
                guard cols > 0, rows.allSatisfy({ $0.count == cols }) else { throw FormulaError(message: "Неверный массив") }
                return .array(Matrix(rows: rows.count, cols: cols, values: rows.flatMap { $0 }))
            case .sheetPrefix(let sheet):
                guard case .word(let w)? = next() else { throw FormulaError(message: "Ожидалась ссылка после имени листа") }
                return try reference(w, sheet: sheet)
            case .word(let w):
                if peek == .lparen {
                    pos += 1
                    var args: [Expr] = []
                    if peek == .rparen { pos += 1 } else {
                        while true {
                            if peek == .sep || peek == .rparen { args.append(.missing) } else { args.append(try comparison()) }
                            guard let t = next() else { throw FormulaError(message: "Не хватает «)»") }
                            if t == .rparen { break }
                            guard t == .sep else { throw FormulaError(message: "Ожидалась «;» или «)»") }
                        }
                    }
                    return .call(Formula.canonicalFunction(w), args)
                }
                let up = w.uppercased()
                if up == "TRUE" || up == "ИСТИНА" { return .bool(true) }
                if up == "FALSE" || up == "ЛОЖЬ" { return .bool(false) }
                return try reference(w, sheet: nil)
            default:
                throw FormulaError(message: "Неожиданный элемент формулы")
            }
        }

        mutating func reference(_ w: String, sheet: String?) throws -> Expr {
            guard let a = Formula.refPart(w) else {
                if sheet == nil { return .name(w) }
                throw FormulaError(message: "Неверная ссылка \(w)")
            }
            if peek == .colon {
                pos += 1
                guard case .word(let w2)? = next(), let b = Formula.refPart(w2),
                      a.wholeRow == b.wholeRow, a.wholeColumn == b.wholeColumn else { throw FormulaError(message: "Неверный диапазон") }
                return .range(sheet: sheet, a, b)
            }
            guard !a.wholeColumn, !a.wholeRow else {
                // A bare word like "x" (LET/LAMBDA names), not a column.
                if sheet == nil, !w.contains("$"), !w.first!.isNumber { return .name(w) }
                throw FormulaError(message: "Неверная ссылка \(w)")
            }
            return .ref(sheet: sheet, a)
        }
    }

    /// "A1", "$B$2", "C" (column), "3" (row).
    static func refPart(_ w: String) -> RefPart? {
        var s = Substring(w.uppercased())
        var absCol = false, absRow = false
        if s.hasPrefix("$") { absCol = true; s = s.dropFirst() }
        let letters = s.prefix { $0.isASCII && $0.isLetter }
        var rest = s.dropFirst(letters.count)
        if rest.hasPrefix("$") { absRow = true; rest = rest.dropFirst() }
        if letters.isEmpty {
            guard let r = Int(rest), r > 0, r - 1 <= RefPart.maxRow else { return nil }
            return RefPart(row: r - 1, col: 0, absRow: absCol || absRow, wholeRow: true)
        }
        guard letters.count <= 3, let col = CellRef.columnIndex(letters), col <= RefPart.maxCol else { return nil }
        if rest.isEmpty { return absRow ? nil : RefPart(row: 0, col: col, absCol: absCol, wholeColumn: true) }
        guard let r = Int(rest), r > 0, r - 1 <= RefPart.maxRow else { return nil }
        return RefPart(row: r - 1, col: col, absRow: absRow, absCol: absCol)
    }

    // MARK: - Names

    static let russianNames: [String: String] = [
        "СУММ": "SUM", "СРЗНАЧ": "AVERAGE", "МИН": "MIN", "МАКС": "MAX", "СЧЁТ": "COUNT", "СЧЕТ": "COUNT",
        "СЧЁТЗ": "COUNTA", "СЧЕТЗ": "COUNTA", "СЧИТАТЬПУСТОТЫ": "COUNTBLANK", "ЕСЛИ": "IF", "ЕСЛИМН": "IFS",
        "ЕСЛИОШИБКА": "IFERROR", "ЕСНД": "IFNA", "И": "AND", "ИЛИ": "OR", "НЕ": "NOT", "ОКРУГЛ": "ROUND",
        "ОКРУГЛВВЕРХ": "ROUNDUP", "ОКРУГЛВНИЗ": "ROUNDDOWN", "ЦЕЛОЕ": "INT", "ОТБР": "TRUNC", "ОСТАТ": "MOD",
        "СТЕПЕНЬ": "POWER", "КОРЕНЬ": "SQRT", "ABS": "ABS", "ПРОИЗВЕД": "PRODUCT", "СУММЕСЛИ": "SUMIF",
        "СУММЕСЛИМН": "SUMIFS", "СЧЁТЕСЛИ": "COUNTIF", "СЧЕТЕСЛИ": "COUNTIF", "СЧЁТЕСЛИМН": "COUNTIFS",
        "СЧЕТЕСЛИМН": "COUNTIFS", "СРЗНАЧЕСЛИ": "AVERAGEIF", "СРЗНАЧЕСЛИМН": "AVERAGEIFS", "ВПР": "VLOOKUP",
        "ГПР": "HLOOKUP", "ПРОСМОТРX": "XLOOKUP", "ИНДЕКС": "INDEX", "ПОИСКПОЗ": "MATCH", "ВЫБОР": "CHOOSE",
        "ДЛСТР": "LEN", "ЛЕВСИМВ": "LEFT", "ПРАВСИМВ": "RIGHT", "ПСТР": "MID", "ПРОПИСН": "UPPER",
        "СТРОЧН": "LOWER", "ПРОПНАЧ": "PROPER", "СЖПРОБЕЛЫ": "TRIM", "СЦЕП": "CONCAT", "СЦЕПИТЬ": "CONCATENATE",
        "ОБЪЕДИНИТЬ": "TEXTJOIN", "ПОДСТАВИТЬ": "SUBSTITUTE", "ЗАМЕНИТЬ": "REPLACE", "НАЙТИ": "FIND",
        "ПОИСК": "SEARCH", "ТЕКСТ": "TEXT", "ЗНАЧЕН": "VALUE", "ПОВТОР": "REPT", "СОВПАД": "EXACT",
        "СЕГОДНЯ": "TODAY", "ТДАТА": "NOW", "ДАТА": "DATE", "ГОД": "YEAR", "МЕСЯЦ": "MONTH", "ДЕНЬ": "DAY",
        "ЧАС": "HOUR", "МИНУТЫ": "MINUTE", "СЕКУНДЫ": "SECOND", "ДЕНЬНЕД": "WEEKDAY", "ДАТАМЕС": "EDATE",
        "КОНМЕСЯЦА": "EOMONTH", "РАЗНДАТ": "DATEDIF", "ДНИ": "DAYS", "ВРЕМЯ": "TIME", "ЧИСТРАБДНИ": "NETWORKDAYS",
        "ПИ": "PI", "СЛЧИС": "RAND", "СЛУЧМЕЖДУ": "RANDBETWEEN", "ОКРВВЕРХ": "CEILING", "ОКРВНИЗ": "FLOOR",
        "ЗНАК": "SIGN", "LN": "LN", "LOG": "LOG", "LOG10": "LOG10", "EXP": "EXP", "МЕДИАНА": "MEDIAN",
        "СТАНДОТКЛОН": "STDEV", "СТАНДОТКЛОН.В": "STDEV.S", "СТАНДОТКЛОН.Г": "STDEV.P", "ДИСП": "VAR",
        "ДИСП.В": "VAR.S", "ДИСП.Г": "VAR.P", "НАИБОЛЬШИЙ": "LARGE", "НАИМЕНЬШИЙ": "SMALL", "РАНГ": "RANK",
        "РАНГ.РВ": "RANK.EQ", "ЕПУСТО": "ISBLANK", "ЕЧИСЛО": "ISNUMBER", "ЕТЕКСТ": "ISTEXT",
        "ЕОШИБКА": "ISERROR", "ЕОШ": "ISERR", "ЕНД": "ISNA", "ЕЛОГИЧ": "ISLOGICAL", "НД": "NA", "СТРОКА": "ROW",
        "СТОЛБЕЦ": "COLUMN", "ЧСТРОК": "ROWS", "ЧИСЛСТОЛБ": "COLUMNS", "СУММПРОИЗВ": "SUMPRODUCT",
        "ПЛТ": "PMT", "БС": "FV", "ПС": "PV", "МАКСЕСЛИ": "MAXIFS", "МИНЕСЛИ": "MINIFS", "ИСКЛИЛИ": "XOR",
        "ПЕРЕКЛЮЧ": "SWITCH", "ОКРУГЛТ": "MROUND", "СУММКВ": "SUMSQ", "ФАКТР": "FACT", "СИМВОЛ": "CHAR",
        "КОДСИМВ": "CODE", "ЧЁТН": "EVEN", "НЕЧЁТ": "ODD", "СРЗНАЧА": "AVERAGEA", "РАБДЕНЬ": "WORKDAY",
        "ИСТИНА": "TRUE", "ЛОЖЬ": "FALSE", "ПРОМЕЖУТОЧНЫЕ.ИТОГИ": "SUBTOTAL", "ДВССЫЛ": "INDIRECT",
        "СМЕЩ": "OFFSET", "МОДА": "MODE", "ГРАДУСЫ": "DEGREES", "РАДИАНЫ": "RADIANS",
        "ПРОСМОТР": "LOOKUP", "ПОИСКПОЗX": "XMATCH", "АДРЕС": "ADDRESS", "ФИЛЬТР": "FILTER", "СОРТ": "SORT", "СОРТПО": "SORTBY",
        "УНИК": "UNIQUE", "ПОСЛЕДОВ": "SEQUENCE", "СЛУЧМАССИВ": "RANDARRAY", "ТРАНСП": "TRANSPOSE", "ТЕКСТДО": "TEXTBEFORE",
        "ТЕКСТПОСЛЕ": "TEXTAFTER", "ТЕКСТРАЗД": "TEXTSPLIT", "ПЕЧСИМВ": "CLEAN", "ЧЗНАЧ": "NUMBERVALUE", "ФИКСИРОВАННЫЙ": "FIXED",
        "РУБЛЬ": "DOLLAR", "ЮНИКОД": "UNICODE", "ЮНИСИМВ": "UNICHAR", "ЧИСТРАБДНИ.МЕЖД": "NETWORKDAYS.INTL",
        "РАБДЕНЬ.МЕЖД": "WORKDAY.INTL", "НОМНЕДЕЛИ": "WEEKNUM", "НОМНЕДЕЛИ.ISO": "ISOWEEKNUM", "ДОЛЯГОДА": "YEARFRAC",
        "ДНЕЙ360": "DAYS360", "ДАТАЗНАЧ": "DATEVALUE", "ВРЕМЗНАЧ": "TIMEVALUE", "ОКРВВЕРХ.МАТ": "CEILING.MATH",
        "ОКРВНИЗ.МАТ": "FLOOR.MATH", "ЧАСТНОЕ": "QUOTIENT", "НОД": "GCD", "НОК": "LCM", "ЧИСЛКОМБ": "COMBIN", "ПЕРЕСТ": "PERMUT",
        "СУММРАЗНКВ": "SUMX2MY2", "СУММСУММКВ": "SUMX2PY2", "СУММКВРАЗН": "SUMXMY2", "МОДА.НСК": "MODE.MULT", "МОДА.ОДН": "MODE.SNGL",
        "СТАНДОТКЛОНП": "STDEVP", "ДИСПР": "VARP", "РАНГ.СР": "RANK.AVG", "ПЕРСЕНТИЛЬ": "PERCENTILE", "ПРОЦЕНТИЛЬ.ВКЛ": "PERCENTILE.INC",
        "ПРОЦЕНТИЛЬ.ИСКЛ": "PERCENTILE.EXC", "КВАРТИЛЬ": "QUARTILE", "КВАРТИЛЬ.ВКЛ": "QUARTILE.INC", "КВАРТИЛЬ.ИСКЛ": "QUARTILE.EXC",
        "ПРОЦЕНТРАНГ": "PERCENTRANK", "ПРОЦЕНТРАНГ.ВКЛ": "PERCENTRANK.INC", "ПРОЦЕНТРАНГ.ИСКЛ": "PERCENTRANK.EXC", "КОРРЕЛ": "CORREL",
        "ПИРСОН": "PEARSON", "НАКЛОН": "SLOPE", "ОТРЕЗОК": "INTERCEPT", "КВПИРСОН": "RSQ", "ПРЕДСКАЗ": "FORECAST",
        "ПРЕДСКАЗ.ЛИНЕЙН": "FORECAST.LINEAR", "ТЕНДЕНЦИЯ": "TREND", "РОСТ": "GROWTH", "ЛИНЕЙН": "LINEST", "НОРМ.РАСП": "NORM.DIST",
        "НОРМ.ОБР": "NORM.INV", "НОРМ.СТ.РАСП": "NORM.S.DIST", "НОРМ.СТ.ОБР": "NORM.S.INV", "СТЬЮДЕНТ.РАСП": "T.DIST",
        "СТЬЮДЕНТ.РАСП.2Х": "T.DIST.2T", "СТЬЮДЕНТ.РАСП.ПХ": "T.DIST.RT", "СТЬЮДЕНТ.ОБР": "T.INV", "СТЬЮДЕНТ.ОБР.2Х": "T.INV.2T",
        "БИНОМ.РАСП": "BINOM.DIST", "ПУАССОН.РАСП": "POISSON.DIST", "ЭКСП.РАСП": "EXPON.DIST", "ХИ2.РАСП": "CHISQ.DIST",
        "ХИ2.РАСП.ПХ": "CHISQ.DIST.RT", "ХИ2.ОБР": "CHISQ.INV", "ХИ2.ОБР.ПХ": "CHISQ.INV.RT", "НОРМРАСП": "NORMDIST",
        "НОРМОБР": "NORMINV", "НОРМСТРАСП": "NORMSDIST", "НОРМСТОБР": "NORMSINV", "СРОТКЛ": "AVEDEV", "КВАДРОТКЛ": "DEVSQ",
        "СРГЕОМ": "GEOMEAN", "СРГАРМ": "HARMEAN", "ЭКСЦЕСС": "KURT", "СКОС": "SKEW", "НОРМАЛИЗАЦИЯ": "STANDARDIZE",
        "КОВАРИАЦИЯ.Г": "COVARIANCE.P", "КОВАРИАЦИЯ.В": "COVARIANCE.S", "КОВАР": "COVAR", "ЧАСТОТА": "FREQUENCY",
        "МУМНОЖ": "MMULT", "МОПРЕД": "MDETERM", "МОБР": "MINVERSE", "МЕДИН": "MUNIT", "ПРПЛТ": "IPMT", "ОСПЛТ": "PPMT", "КПЕР": "NPER",
        "СТАВКА": "RATE", "ЧПС": "NPV", "ЧИСТНЗ": "XNPV", "ВСД": "IRR", "ЧИСТВНДОХ": "XIRR", "МВСД": "MIRR", "АПЛ": "SLN", "ФУО": "DB",
        "ДДОБ": "DDB", "АСЧ": "SYD", "ЭФФЕКТ": "EFFECT", "НОМИНАЛ": "NOMINAL", "ОБЩПЛАТ": "CUMIPMT", "ОБЩДОХОД": "CUMPRINC",
        "ЕФОРМУЛА": "ISFORMULA", "ЕЧЁТН": "ISEVEN", "ЕЧЕТН": "ISEVEN", "ЕНЕЧЁТ": "ISODD", "ЕНЕЧЕТ": "ISODD", "ТИП": "TYPE",
        "ЯЧЕЙКА": "CELL", "ИНФОРМ": "INFO", "ЛИСТ": "SHEET", "ЛИСТЫ": "SHEETS", "ЕССЫЛКА": "ISREF", "Ф.ТЕКСТ": "FORMULATEXT",
        "ТИП.ОШИБКИ": "ERROR.TYPE", "ПРЕОБР": "CONVERT", "ДЕС.В.ДВ": "DEC2BIN", "ДВ.В.ДЕС": "BIN2DEC", "ДЕС.В.ШЕСТН": "DEC2HEX",
        "ШЕСТН.В.ДЕС": "HEX2DEC", "ДЕС.В.ВОСЬМ": "DEC2OCT", "ВОСЬМ.В.ДЕС": "OCT2DEC", "ДВ.В.ШЕСТН": "BIN2HEX", "ШЕСТН.В.ДВ": "HEX2BIN",
        "ДВ.В.ВОСЬМ": "BIN2OCT", "ВОСЬМ.В.ДВ": "OCT2BIN", "ШЕСТН.В.ВОСЬМ": "HEX2OCT", "ВОСЬМ.В.ШЕСТН": "OCT2HEX", "БИТ.И": "BITAND",
        "БИТ.ИЛИ": "BITOR", "БИТ.ИСКЛИЛИ": "BITXOR", "БИТ.СДВИГЛ": "BITLSHIFT", "БИТ.СДВИГП": "BITRSHIFT", "ДЕЛЬТА": "DELTA",
        "ПОРОГ": "GESTEP", "ДВФАКТР": "FACTDOUBLE", "МУЛЬТИНОМ": "MULTINOMIAL",
        "РИМСКОЕ": "ROMAN", "АРАБСКОЕ": "ARABIC", "ОСНОВАНИЕ": "BASE", "ДЕС": "DECIMAL", "КОРЕНЬПИ": "SQRTPI", "АГРЕГАТ": "AGGREGATE",
        "ГАММА": "GAMMA", "ГАММАНЛОГ": "GAMMALN", "ДОВЕРИТ.НОРМ": "CONFIDENCE.NORM", "ФИШЕР": "FISHER", "ФИШЕРОБР": "FISHERINV",
        "СТАНДОТКЛОНА": "STDEVA", "СТАНДОТКЛОНПА": "STDEVPA", "ДИСПА": "VARA", "ДИСПРА": "VARPA", "МАКСА": "MAXA", "МИНА": "MINA",
        "БЗРАСПИС": "FVSCHEDULE", "ПДЛИТ": "PDURATION", "ЭКВ.СТАВКА": "RRI", "ВЫБОРСТОЛБЦ": "CHOOSECOLS",
        "ВЫБОРСТРОК": "CHOOSEROWS", "ВСТОЛБИК": "VSTACK", "ГСТОЛБИК": "HSTACK", "ПОСТОЛБЦ": "TOCOL", "ПОСТРОК": "TOROW",
        "ВЗЯТЬ": "TAKE", "СБРОСИТЬ": "DROP", "ГИПЕРССЫЛКА": "HYPERLINK",
    ]

    /// Functions Excel stores with the "_xlfn." prefix.
    static let futureFunctions: Set<String> = [
        "IFS", "IFNA", "XLOOKUP", "CONCAT", "TEXTJOIN", "MAXIFS", "MINIFS", "SWITCH", "XOR", "DAYS",
        "STDEV.S", "STDEV.P", "VAR.S", "VAR.P", "RANK.EQ",
        "XMATCH", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "TEXTBEFORE", "TEXTAFTER", "TEXTSPLIT", "LET", "LAMBDA",
        "VSTACK", "HSTACK", "TOCOL", "TOROW", "CHOOSECOLS", "CHOOSEROWS", "TAKE", "DROP", "EXPAND", "WRAPROWS", "WRAPCOLS",
        "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "T.DIST", "T.DIST.2T", "T.DIST.RT", "T.INV", "T.INV.2T",
        "CHISQ.DIST", "CHISQ.DIST.RT", "CHISQ.INV", "CHISQ.INV.RT", "BINOM.DIST", "POISSON.DIST", "EXPON.DIST",
        "PERCENTILE.INC", "PERCENTILE.EXC", "QUARTILE.INC", "QUARTILE.EXC", "PERCENTRANK.INC", "PERCENTRANK.EXC",
        "MODE.SNGL", "MODE.MULT", "RANK.AVG", "FORECAST.LINEAR", "CEILING.MATH", "FLOOR.MATH", "CEILING.PRECISE",
        "FLOOR.PRECISE", "ISOWEEKNUM", "MUNIT", "F.INV", "F.INV.RT", "T.TEST", "Z.TEST", "BITAND", "BITOR", "BITXOR", "BITLSHIFT",
        "BITRSHIFT", "UNICODE", "UNICHAR", "NUMBERVALUE", "ISFORMULA", "SHEET", "SHEETS", "FORMULATEXT", "COVARIANCE.P",
        "COVARIANCE.S", "GAMMA", "GAMMALN.PRECISE", "GAMMA.DIST", "GAMMA.INV", "COMBINA", "PERMUTATIONA", "ACOT", "ACOTH",
        "COT", "COTH", "CSC", "CSCH", "SEC", "SECH", "ARABIC", "BASE", "DECIMAL", "AGGREGATE", "PHI", "GAUSS",
        "CONFIDENCE.NORM", "CONFIDENCE.T", "LOGNORM.DIST", "LOGNORM.INV", "WEIBULL.DIST", "F.DIST", "F.DIST.RT",
        "ERF.PRECISE", "ERFC.PRECISE", "PDURATION", "RRI", "SKEW.P", "BETA.DIST", "BETA.INV", "BINOM.INV",
        "REGEXTEST", "REGEXEXTRACT", "REGEXREPLACE", "VALUETOTEXT", "ARRAYTOTEXT",
    ]

    /// Prefix Excel files use for the function ("_xlfn.", "_xlfn._xlws." or none).
    static func filePrefix(_ name: String) -> String {
        if worksheetFunctions.contains(name) { return "_xlfn._xlws." }
        if name == "REGEX" { return "_xlfn.ORG.LIBREOFFICE." }
        return futureFunctions.contains(name) ? "_xlfn." : ""
    }

    static let worksheetFunctions: Set<String> = ["FILTER", "SORT"]

    static func canonicalFunction(_ name: String) -> String {
        var up = name.uppercased()
        for prefix in ["_XLFN._XLWS.", "_XLFN.", "_XLWS.", "ORG.LIBREOFFICE.", "COM.MICROSOFT.", "LEGACY."] where up.hasPrefix(prefix) { up.removeFirst(prefix.count) }
        return russianNames[up] ?? up
    }

    static let errorNames: [String: String] = [
        "#ДЕЛ/0!": "#DIV/0!", "#ЗНАЧ!": "#VALUE!", "#ССЫЛКА!": "#REF!", "#ИМЯ?": "#NAME?",
        "#Н/Д": "#N/A", "#ЧИСЛО!": "#NUM!", "#ПУСТО!": "#NULL!",
    ]

    static func canonicalError(_ e: String) -> String { errorNames[e] ?? e }

    /// Russian display names of error codes.
    static func displayError(_ e: String) -> String {
        errorNames.first { $0.value == e }?.key ?? e
    }

    // MARK: - Serialization

    static func sheetPrefix(_ sheet: String?) -> String {
        guard let sheet else { return "" }
        let plain = sheet.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(sheet.first?.isNumber ?? true)
        return plain ? "\(sheet)!" : "'\(sheet.replacingOccurrences(of: "'", with: "''"))'!"
    }

    /// Canonical text. `forFile` adds the _xlfn. prefixes Excel expects.
    static func serialize(_ e: Expr, forFile: Bool = false) -> String {
        func s(_ e: Expr, _ parentPrec: Int) -> String {
            switch e {
            case .number(let d): return Value.numberLiteral(d)
            case .string(let str): return "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .bool(let b): return b ? "TRUE" : "FALSE"
            case .error(let err): return err
            case .missing: return ""
            case .array(let m): return arrayText(m, col: ",", row: ";")
            case .name(let n): return n
            case .ref(let sheet, let p): return sheetPrefix(sheet) + p.text
            case .range(let sheet, let a, let b): return sheetPrefix(sheet) + a.text + ":" + b.text
            case .unary(let o, let x): return o + s(x, 6)
            case .percent(let x): return s(x, 7) + "%"
            case .call(let name, let args):
                let n = forFile ? filePrefix(name) + name : name
                return n + "(" + args.map { s($0, 0) }.joined(separator: ",") + ")"
            case .binary(let o, let l, let r):
                let prec = precedence(o)
                let text = s(l, prec) + o + s(r, prec + 1)
                return prec < parentPrec ? "(" + text + ")" : text
            }
        }
        return s(e, 0)
    }

    /// "{1,2;3,4}" (Excel) or "{1;2|3;4}" (OpenFormula).
    static func arrayText(_ m: Matrix, col: String, row: String) -> String {
        func item(_ v: Value) -> String {
            switch v {
            case .number(let d): return Value.numberLiteral(d)
            case .string(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .bool(let b): return b ? "TRUE" : "FALSE"
            case .error(let e): return e
            case .empty: return "0"
            }
        }
        return "{" + (0..<m.rows).map { r in (0..<m.cols).map { item(m[r, $0]) }.joined(separator: col) }.joined(separator: row) + "}"
    }

    static func precedence(_ op: String) -> Int {
        switch op {
        case "=", "<>", "<", ">", "<=", ">=": return 1
        case "&": return 2
        case "+", "-": return 3
        case "*", "/": return 4
        case "^": return 5
        default: return 0
        }
    }

    // MARK: - Reference transforms

    /// Rewrites every reference. `transform` gets (sheet or nil, part, isRangeEnd) and returns the new part or nil (→ #REF!).
    static func mapRefs(_ e: Expr, _ transform: (String?, RefPart, Bool) -> RefPart?) -> Expr {
        func m(_ e: Expr) -> Expr {
            switch e {
            case .ref(let sheet, let p):
                guard let np = transform(sheet, p, false) else { return .error("#REF!") }
                return .ref(sheet: sheet, np)
            case .range(let sheet, let a, let b):
                guard let na = transform(sheet, a, false), let nb = transform(sheet, b, true) else { return .error("#REF!") }
                return .range(sheet: sheet, na, nb)
            case .unary(let o, let x): return .unary(o, m(x))
            case .percent(let x): return .percent(m(x))
            case .binary(let o, let l, let r): return .binary(o, m(l), m(r))
            case .call(let n, let args): return .call(n, args.map(m))
            default: return e
            }
        }
        return m(e)
    }

    /// Formula copied by (dr, dc): relative parts move, absolute stay (copy, fill, shared formulas).
    static func shifted(_ formula: String, rows dr: Int, cols dc: Int) -> String {
        guard let e = try? parse(formula) else { return formula }
        let out = mapRefs(e) { _, p, _ in
            var p = p
            if !p.absRow, !p.wholeColumn { p.row += dr }
            if !p.absCol, !p.wholeRow { p.col += dc }
            return p.row < 0 || p.col < 0 || p.row > RefPart.maxRow || p.col > RefPart.maxCol ? nil : p
        }
        return "=" + serialize(out)
    }

    /// Adjusts references after inserting (count > 0) or deleting (count < 0) rows/columns at `index`
    /// on `sheet`. `formulaSheet` is the sheet that holds the formula (for unqualified refs).
    static func adjusted(_ formula: String, sheet: String, formulaSheet: String, rows: Bool, at index: Int, count: Int) -> String {
        guard let e = try? parse(formula) else { return formula }
        func affected(_ refSheet: String?, _ p: RefPart) -> Bool {
            (refSheet ?? formulaSheet).caseInsensitiveCompare(sheet) == .orderedSame && !(rows ? p.wholeColumn : p.wholeRow)
        }
        func coordinate(_ p: RefPart) -> Int { rows ? p.row : p.col }
        func moved(_ p: RefPart, rangeEnd: Bool? = nil) -> RefPart? {
            var p = p
            var v = coordinate(p)
            if count > 0 {
                if v >= index { v += count }
            } else if count < 0 {
                let delEnd = index - count   // exclusive
                if v >= delEnd { v += count }
                else if v >= index {
                    // A deleted cell is gone; only the surviving part of a range may clamp.
                    guard let rangeEnd else { return nil }
                    v = rangeEnd ? index - 1 : index
                }
            }
            guard v >= 0, v <= (rows ? RefPart.maxRow : RefPart.maxCol) else { return nil }
            if rows { p.row = v } else { p.col = v }
            return p
        }
        func adjust(_ e: Expr) -> Expr {
            switch e {
            case .ref(let refSheet, let p):
                guard affected(refSheet, p) else { return e }
                guard let p = moved(p) else { return .error("#REF!") }
                return .ref(sheet: refSheet, p)
            case .range(let refSheet, let a, let b):
                guard affected(refSheet, a) else { return e }
                let low = min(coordinate(a), coordinate(b)), high = max(coordinate(a), coordinate(b))
                if count < 0, low >= index, high < index - count { return .error("#REF!") }
                // References may be written in reverse order (A10:A1).
                let reversed = coordinate(a) > coordinate(b)
                guard let a = moved(a, rangeEnd: reversed), let b = moved(b, rangeEnd: !reversed) else { return .error("#REF!") }
                return .range(sheet: refSheet, a, b)
            case .unary(let o, let x): return .unary(o, adjust(x))
            case .percent(let x): return .percent(adjust(x))
            case .binary(let o, let l, let r): return .binary(o, adjust(l), adjust(r))
            case .call(let n, let args): return .call(n, args.map(adjust))
            default: return e
            }
        }
        return "=" + serialize(adjust(e))
    }
}
