import Foundation
import Kit42

extension SelfTest {
    /// Reproduced calculation, reference, date-epoch and formatting defects.
    static func deepFormulas() -> Int {
        var failed = 0, checked = 0
        func check(_ name: String, _ condition: Bool) {
            checked += 1
            if !condition { failed += 1; print("FAIL deep formulas:", name) }
        }
        func cell(_ input: String, _ value: Value) -> Cell {
            var result = Cell(); result.input = input; result.value = value
            return result
        }
        var wb = Workbook()
        wb.sheets[0][CellRef("A1")!] = cell("10", .number(10))
        wb.sheets[0][CellRef("A3")!] = cell("20", .number(20))
        wb.sheets[0][CellRef("B1")!] = cell("text", .string("text"))
        wb.names["AllCells"] = "A1:XFD1048576"
        let at = CellRef("Z100")!
        func evaluate(_ formula: String, _ workbook: Workbook = wb) -> Value {
            let calculator = Calculator(workbook)
            guard let expression = try? Formula.parse(formula) else { return .error("parse failed") }
            return calculator.scalar(calculator.eval(expression, sheet: 0, at: at), at: at)
        }
        func number(_ formula: String, _ expected: Double, _ workbook: Workbook = wb) {
            let actual = evaluate(formula, workbook)
            if case .number(let value) = actual {
                check(formula, value.isFinite && abs(value - expected) <= max(1e-9, abs(expected) * 1e-12))
            } else { check("\(formula) returned \(actual.plain)", false) }
        }
        func error(_ formula: String, _ expected: String = "#NUM!") {
            check(formula, evaluate(formula) == .error(expected))
        }

        check("last Excel cell", CellRef("XFD1048576") == CellRef(row: RefPart.maxRow, col: RefPart.maxCol))
        for invalid in ["XFE1", "A1048577", "A0", String(repeating: "Z", count: 200) + "1", "A" + String(repeating: "9", count: 200)] {
            check("invalid address \(invalid.prefix(20))", CellRef(invalid) == nil)
        }
        for invalid in [":A1", "A1:", "A1::B2"] { check("invalid range \(invalid)", CellRange(invalid) == nil) }
        check("copy below sheet", Formula.shifted("=A1048576", rows: 1, cols: 0) == "=#REF!")
        check("copy beyond last column", Formula.shifted("=XFD1", rows: 0, cols: 1) == "=#REF!")
        check("copy absolute edge", Formula.shifted("=$XFD$1048576", rows: 1, cols: 1) == "=$XFD$1048576")
        check("delete only referenced row", Formula.adjusted("=A2", sheet: "Data", formulaSheet: "Data", rows: true, at: 1, count: -1) == "=#REF!")
        check("delete contracts reversed range", Formula.adjusted("=SUM(A5:A2)", sheet: "Data", formulaSheet: "Data", rows: true, at: 1, count: -2) == "=SUM(A3:A2)")
        check("unrelated sheet keeps reference", Formula.adjusted("='Other sheet'!A2", sheet: "Data", formulaSheet: "Data", rows: true, at: 1, count: -1) == "='Other sheet'!A2")

        number("=ROWS(A1:A10)", 10)
        number("=COLUMNS(A1:J1)", 10)
        number("=ROWS(A:A)", 1_048_576)
        number("=COLUMNS(1:1)", 16_384)
        number("=COUNTBLANK(A1:A10)", 8)
        number("=COUNTBLANK(A1:XFD1048576)", 17_179_869_181)
        number("=SUM(A1:XFD1048576)", 30)
        number("=COUNT(A1:XFD1048576)", 2)
        number("=COUNTA(A1:XFD1048576)", 3)
        number("=SUM(AllCells)", 30)
        number("=ROWS(AllCells)", 1_048_576)
        number("=SUBTOTAL(9,A:XFD)", 30)
        number("=AGGREGATE(9,0,A:XFD)", 30)
        check("CELL retains empty first reference", evaluate("=CELL(\"address\",A2:XFD1048576)") == .string("$A$2"))
        check("INDEX can select blank beyond used range", evaluate("=INDEX(A1:A10,10)") == .empty)
        let calc = Calculator(wb)
        if let expression = try? Formula.parse("=TRANSPOSE(A1:A10)"), case .matrix(let matrix, _) = calc.eval(expression, sheet: 0, at: at) {
            check("TRANSPOSE preserves blank tail", matrix.rows == 1 && matrix.cols == 10 && matrix.values.last == .empty)
        } else { check("TRANSPOSE returns matrix", false) }
        error("=TRANSPOSE(A1:XFD1048576)")
        error("=OFFSET(A1,0,0,0,1)", "#REF!")
        error("=OFFSET(A1:B2,0,0,-1,1)", "#REF!")
        error("=OFFSET(XFD1,0,1)", "#REF!")
        error("=OFFSET(A1048576,1,0)", "#REF!")
        number("=SUM(1E300)", 1e300)
        number("=PRODUCT(Z1:Z10)", 0)
        number("=BITLSHIFT(1,47)", 140_737_488_355_328)
        error("=BITLSHIFT(140737488355328,17)")
        error("=BITRSHIFT(140737488355328,-17)")
        error("=1E300*1E300")
        for formula in ["=LEFT(\"x\",1E300)", "=FACT(1E300)", "=DATE(1E300,1,1)",
                        "=ROMAN(1E300)", "=PERMUT(1E300,1E300)", "=SEQUENCE(1E12,1E12)",
                        "=RANDARRAY(1E12,1E12)", "=RANDARRAY(1,1,1E300,1E300,TRUE)",
                        "=RANDARRAY(1,1,0.2,0.8,TRUE)", "=CHOOSECOLS(A1:B1,1E300)",
                        "=EXPAND(A1,1E12,1E12)", "=WRAPROWS(A1:A3,1E12)",
                        "=MUNIT(1E12)", "=AGGREGATE(14,0,A1:A3,1E300)",
                        "=BINOM.DIST(1E300,1E300,0.5,TRUE)", "=BINOM.INV(1E300,0.5,0.5)",
                        "=POISSON.DIST(1E300,1,TRUE)", "=DDB(100,0,1E300,1E300)",
                        "=DB(100,0,1E300,1E300)", "=CUMIPMT(0.01,1E300,100,1,1E300,0)",
                        "=IF(SEQUENCE(2000),SEQUENCE(1,2000),0)",
                        "=IFERROR(SEQUENCE(2000),SEQUENCE(1,2000))"] { error(formula) }
        error("=REPT(\"x\",1E12)", "#VALUE!")
        error("=BASE(1,2,1E12)")
        number("=LEN(REPT(\"\",1E12))", 0)
        error("=FVSCHEDULE(1)", "#VALUE!")
        error("=IRR()", "#VALUE!")
        number("=BINOM.DIST(2,4,0.5,TRUE)", 0.6875)
        number("=POISSON.DIST(2,1,TRUE)", 2.5 / exp(1))

        var rowArray = Workbook()
        var rowAnchor = cell("=ROW(A1:A2)*10", .empty); rowAnchor.array = true
        rowArray.sheets[0][CellRef("C1")!] = rowAnchor
        rowArray.sheets[0].arrays[CellRef("C1")!] = CellRange("C1:C2")!
        var colAnchor = cell("=COLUMN(A1:B1)*10", .empty); colAnchor.array = true
        rowArray.sheets[0][CellRef("E1")!] = colAnchor
        rowArray.sheets[0].arrays[CellRef("E1")!] = CellRange("E1:F1")!
        rowArray.sheets[0][CellRef("G2")!] = cell("=ROW(A1:A3)", .empty)
        rowArray = Calculator.recalculate(rowArray)
        check("ROW produces every fixed-array row", rowArray.sheets[0][CellRef("C1")!].value == .number(10) && rowArray.sheets[0][CellRef("C2")!].value == .number(20))
        check("COLUMN produces every fixed-array column", rowArray.sheets[0][CellRef("E1")!].value == .number(10) && rowArray.sheets[0][CellRef("F1")!].value == .number(20))
        check("ordinary ROW retains implicit intersection", rowArray.sheets[0][CellRef("G2")!].value == .number(2))
        error("=ROW('Missing sheet'!A1)", "#REF!")

        var crossing = Workbook()
        crossing.sheets[0].merges = [CellRange("B1:B3")!]
        crossing.sheets[0][CellRef("A2")!] = cell("=SEQUENCE(1,3)", .empty)
        crossing = Calculator.recalculate(crossing)
        check("spill intersects middle of merge", crossing.sheets[0][CellRef("A2")!].value == .error("#SPILL!"))
        var legacy = Workbook()
        var anchor = cell("=1", .empty); anchor.array = true
        legacy.sheets[0][CellRef("A1")!] = anchor
        legacy.sheets[0].arrays[CellRef("A1")!] = CellRange("A1:XFD1048576")!
        legacy = Calculator.recalculate(legacy)
        check("oversized legacy array is bounded", legacy.sheets[0][CellRef("A1")!].value == .error("#NUM!"))

        for (formula, expected) in [("=DATE(1900,1,1)", 1.0), ("=DATE(1900,2,28)", 59),
                                    ("=DATE(1900,2,29)", 60), ("=DATE(1900,3,1)", 61),
                                    ("=DATE(1900,3,0)", 60), ("=MONTH(60)", 2), ("=DAY(60)", 29),
                                    ("=DAY(1)", 1), ("=TIME(24,0,0)", 0)] { number(formula, expected) }
        for invalid in ["2023-02-29", "2024-02-31", "2024-01-01 10:bad", "2024-01-01 -1:00", "10:bad:20", "10::20", "-1:00"] {
            check("invalid date/time rejected \(invalid)", DateMath.parse(invalid) == nil)
        }
        check("leap date accepted", DateMath.parse("2024-02-29") == DateMath.serial(year: 2024, month: 2, day: 29))
        check("1904 typed date", DateMath.parse("1904-01-01", date1904: true) == 0)
        check("1904 time unchanged", DateMath.parse("12:00", date1904: true) == 0.5)
        error("=HOUR(-0.5)")
        error("=NETWORKDAYS(1E300,1E300)")
        error("=WORKDAY(1E300,0)")
        error("=WORKDAY(2958465,1)")
        error("=YEARFRAC(1E300,1E300)")
        error("=ISOWEEKNUM(1E300)")
        var mac = wb; mac.date1904 = true
        for (formula, expected) in [("=DATE(1904,1,1)", 0.0), ("=YEAR(0)", 1904), ("=MONTH(0)", 1), ("=DAY(0)", 1),
                                    ("=WEEKDAY(0)", 6), ("=EDATE(0,1)", 31), ("=EOMONTH(0,0)", 30),
                                    ("=DATEVALUE(\"1904-01-01\")", 0), ("=WEEKNUM(0)", 1), ("=ISOWEEKNUM(0)", 53),
                                    ("=WORKDAY(0,1)", 3), ("=NETWORKDAYS(0,3)", 2), ("=YEARFRAC(0,366,1)", 1),
                                    ("=DAYS360(0,31)", 30), ("=DATEDIF(0,31,\"M\")", 1)] { number(formula, expected, mac) }
        check("TEXT respects epoch", evaluate("=TEXT(0,\"yyyy-mm-dd\")", mac) == .string("1904-01-01"))

        let decimal = NumberFormat.decimal
        check("formatting epoch", NumberFormat.format(.number(0), "yyyy-mm-dd", date1904: true).text == "1904-01-01")
        check("early 1900 formatting", NumberFormat.format(.number(1), "yyyy-mm-dd").text == "1900-01-01")
        check("fictitious leap-day formatting", NumberFormat.format(.number(60), "yyyy-mm-dd").text == "1900-02-29")
        check("scientific exponent rounding", NumberFormat.format(.number(9999), "0.00E+00").text == "1\(decimal)00E+04")
        check("subnormal scientific format", NumberFormat.format(.number(1e-320), "0.00E+00").text.hasSuffix("E-320"))
        check("fractional seconds recognized", NumberFormat.isDateFormat("mm:ss.0"))
        check("fractional seconds displayed", NumberFormat.format(.number(0.5 / 86400), "mm:ss.0").text == "00:00\(decimal)5")
        check("elapsed hours recognized", NumberFormat.isDateFormat("[h]"))
        check("elapsed hours unchanged by epoch", NumberFormat.format(.number(1.5), "[h]", date1904: true).text == "36")
        check("nonfinite format", NumberFormat.format(.number(.infinity), "# ?/?").text == NumberFormat.errorText("#NUM!"))
        check("condition follows color", NumberFormat.format(.number(5), "[Red][>10]0;[Blue]0.00").text == "5\(decimal)00")
        check("conditional fallback", NumberFormat.format(.number(5), "[>10]0;[<0]0;0.00").text == "5\(decimal)00")
        print("XLS deep formula regressions: \(checked - failed)/\(checked) passed")
        return failed
    }
}
