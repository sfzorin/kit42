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
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
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
                    if j < chars.count, chars[j] == ":" , Int(text) != nil {
                        tokens.append(.word(text))   // row range 1:3
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
                guard case .word(let w2)? = next(), let b = Formula.refPart(w2) else { throw FormulaError(message: "Неверный диапазон") }
                return .range(sheet: sheet, a, b)
            }
            guard !a.wholeColumn, !a.wholeRow else { throw FormulaError(message: "Неверная ссылка \(w)") }
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
            guard let r = Int(rest), r > 0 else { return nil }
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
    ]

    /// Functions Excel stores with the "_xlfn." prefix.
    static let futureFunctions: Set<String> = [
        "IFS", "IFNA", "XLOOKUP", "CONCAT", "TEXTJOIN", "MAXIFS", "MINIFS", "SWITCH", "XOR", "DAYS",
        "STDEV.S", "STDEV.P", "VAR.S", "VAR.P", "RANK.EQ",
    ]

    static func canonicalFunction(_ name: String) -> String {
        var up = name.uppercased()
        for prefix in ["_XLFN._XLWS.", "_XLFN.", "_XLWS."] where up.hasPrefix(prefix) { up.removeFirst(prefix.count) }
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
            case .number(let d): return Value.formatGeneral(d)
            case .string(let str): return "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .bool(let b): return b ? "TRUE" : "FALSE"
            case .error(let err): return err
            case .missing: return ""
            case .name(let n): return n
            case .ref(let sheet, let p): return sheetPrefix(sheet) + p.text
            case .range(let sheet, let a, let b): return sheetPrefix(sheet) + a.text + ":" + b.text
            case .unary(let o, let x): return o + s(x, 6)
            case .percent(let x): return s(x, 7) + "%"
            case .call(let name, let args):
                let n = forFile && futureFunctions.contains(name) ? "_xlfn." + name : name
                return n + "(" + args.map { s($0, 0) }.joined(separator: ",") + ")"
            case .binary(let o, let l, let r):
                let prec = precedence(o)
                let text = s(l, prec) + o + s(r, prec + 1)
                return prec < parentPrec ? "(" + text + ")" : text
            }
        }
        return s(e, 0)
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
        let out = mapRefs(e) { refSheet, p, isEnd in
            let target = refSheet ?? formulaSheet
            guard target.caseInsensitiveCompare(sheet) == .orderedSame else { return p }
            var p = p
            if rows ? p.wholeColumn : p.wholeRow { return p }
            var v = rows ? p.row : p.col
            if count > 0 {
                if v >= index { v += count }
            } else {
                let delEnd = index - count   // exclusive
                if v >= delEnd { v += count }
                else if v >= index {
                    // Inside the deleted block: single refs break, range ends clamp.
                    if isEnd { v = index - 1 } else { v = index }
                    if !isEnd, v < 0 { return nil }
                }
            }
            if v < 0 { return nil }
            if rows { p.row = v } else { p.col = v }
            return p
        }
        return "=" + serialize(out)
    }
}
