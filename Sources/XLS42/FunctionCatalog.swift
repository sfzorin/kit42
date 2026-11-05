import Foundation
import Kit42

/// Every function the formula engine (`Calculator.call`) implements, with category, argument
/// signature and a one-line description (localized through `L`). Used by the function wizard,
/// the signature hint while typing and Help › Supported Functions.
enum FunctionCatalog {
    enum Category: String, CaseIterable {
        case math = "Math", statistical = "Statistical", text = "Text", logical = "Logical", date = "Date & Time"
        case lookup = "Lookup & Reference", information = "Information", financial = "Financial", engineering = "Engineering"
        var title: String { L(rawValue) }
    }

    struct Function {
        let name: String
        let category: Category
        /// Arguments as written in the signature; "[x]" optional, "…" repeats the previous one.
        let args: [String]
        let summary: String   // English; localized via `L`
        var signature: String { "\(name)(\(args.joined(separator: NumberFormat.decimal == "," ? "; " : ", ")))" }
        var description: String { L(summary) }
    }

    static func f(_ name: String, _ c: Category, _ args: String, _ summary: String) -> Function {
        Function(name: name, category: c, args: args.isEmpty ? [] : args.components(separatedBy: ", "), summary: summary)
    }

    static let all: [Function] = core + extra

    static let core: [Function] = [
        // Math
        f("SUM", .math, "number1, [number2], …", "Adds all the numbers"),
        f("PRODUCT", .math, "number1, [number2], …", "Multiplies all the numbers"),
        f("SUMPRODUCT", .math, "array1, [array2], …", "Sum of the products of corresponding array elements"),
        f("SUMSQ", .math, "number1, [number2], …", "Sum of the squares of the arguments"),
        f("SUMIF", .math, "range, criteria, [sum_range]", "Adds the cells that meet a condition"),
        f("SUMIFS", .math, "sum_range, criteria_range1, criteria1, …", "Adds the cells that meet several conditions"),
        f("SUBTOTAL", .math, "function_num, ref1, …", "Subtotal of a list (1 average, 2 count, 9 sum…)"),
        f("ABS", .math, "number", "Absolute value of a number"),
        f("SIGN", .math, "number", "Sign of a number: 1, 0 or -1"),
        f("INT", .math, "number", "Rounds down to the nearest integer"),
        f("TRUNC", .math, "number, [num_digits]", "Truncates a number to an integer or to given decimals"),
        f("ROUND", .math, "number, num_digits", "Rounds a number to a number of digits"),
        f("ROUNDUP", .math, "number, num_digits", "Rounds a number away from zero"),
        f("ROUNDDOWN", .math, "number, num_digits", "Rounds a number towards zero"),
        f("MROUND", .math, "number, multiple", "Rounds a number to the nearest multiple"),
        f("CEILING", .math, "number, [significance]", "Rounds up to the nearest multiple of significance"),
        f("CEILING.MATH", .math, "number, [significance]", "Rounds up to the nearest multiple of significance"),
        f("FLOOR", .math, "number, [significance]", "Rounds down to the nearest multiple of significance"),
        f("FLOOR.MATH", .math, "number, [significance]", "Rounds down to the nearest multiple of significance"),
        f("EVEN", .math, "number", "Rounds up to the nearest even integer"),
        f("ODD", .math, "number", "Rounds up to the nearest odd integer"),
        f("MOD", .math, "number, divisor", "Remainder after division"),
        f("POWER", .math, "number, power", "Number raised to a power"),
        f("SQRT", .math, "number", "Square root"),
        f("EXP", .math, "number", "e raised to the power of a number"),
        f("LN", .math, "number", "Natural logarithm"),
        f("LOG", .math, "number, [base]", "Logarithm to a base (10 by default)"),
        f("LOG10", .math, "number", "Base-10 logarithm"),
        f("PI", .math, "", "The number π"),
        f("RAND", .math, "", "Random number between 0 and 1"),
        f("RANDBETWEEN", .math, "bottom, top", "Random integer between two numbers"),
        f("FACT", .math, "number", "Factorial of a number"),
        f("DEGREES", .math, "angle", "Converts radians to degrees"),
        f("RADIANS", .math, "angle", "Converts degrees to radians"),
        f("SIN", .math, "number", "Sine of an angle in radians"),
        f("COS", .math, "number", "Cosine of an angle in radians"),
        f("TAN", .math, "number", "Tangent of an angle in radians"),
        // Statistical
        f("AVERAGE", .statistical, "number1, [number2], …", "Arithmetic mean of the numbers"),
        f("AVERAGEA", .statistical, "value1, [value2], …", "Mean counting text as 0 and TRUE as 1"),
        f("AVERAGEIF", .statistical, "range, criteria, [average_range]", "Mean of the cells that meet a condition"),
        f("AVERAGEIFS", .statistical, "average_range, criteria_range1, criteria1, …", "Mean of the cells that meet several conditions"),
        f("MIN", .statistical, "number1, [number2], …", "Smallest number"),
        f("MAX", .statistical, "number1, [number2], …", "Largest number"),
        f("MINIFS", .statistical, "min_range, criteria_range1, criteria1, …", "Smallest value among cells that meet conditions"),
        f("MAXIFS", .statistical, "max_range, criteria_range1, criteria1, …", "Largest value among cells that meet conditions"),
        f("COUNT", .statistical, "value1, [value2], …", "Counts the cells that contain numbers"),
        f("COUNTA", .statistical, "value1, [value2], …", "Counts the non-empty cells"),
        f("COUNTBLANK", .statistical, "range", "Counts the empty cells"),
        f("COUNTIF", .statistical, "range, criteria", "Counts the cells that meet a condition"),
        f("COUNTIFS", .statistical, "criteria_range1, criteria1, …", "Counts the cells that meet several conditions"),
        f("MEDIAN", .statistical, "number1, [number2], …", "Median of the numbers"),
        f("MODE", .statistical, "number1, [number2], …", "Most frequent value"),
        f("MODE.SNGL", .statistical, "number1, [number2], …", "Most frequent value"),
        f("STDEV", .statistical, "number1, [number2], …", "Standard deviation of a sample"),
        f("STDEV.S", .statistical, "number1, [number2], …", "Standard deviation of a sample"),
        f("STDEV.P", .statistical, "number1, [number2], …", "Standard deviation of a whole population"),
        f("VAR", .statistical, "number1, [number2], …", "Variance of a sample"),
        f("VAR.S", .statistical, "number1, [number2], …", "Variance of a sample"),
        f("VAR.P", .statistical, "number1, [number2], …", "Variance of a whole population"),
        f("LARGE", .statistical, "array, k", "The k-th largest value"),
        f("SMALL", .statistical, "array, k", "The k-th smallest value"),
        f("RANK", .statistical, "number, ref, [order]", "Rank of a number in a list"),
        f("RANK.EQ", .statistical, "number, ref, [order]", "Rank of a number in a list"),
        // Text
        f("LEN", .text, "text", "Number of characters in a text"),
        f("LEFT", .text, "text, [num_chars]", "First characters of a text"),
        f("RIGHT", .text, "text, [num_chars]", "Last characters of a text"),
        f("MID", .text, "text, start_num, num_chars", "Characters from the middle of a text"),
        f("UPPER", .text, "text", "Converts text to upper case"),
        f("LOWER", .text, "text", "Converts text to lower case"),
        f("PROPER", .text, "text", "Capitalizes the first letter of each word"),
        f("TRIM", .text, "text", "Removes extra spaces"),
        f("CONCAT", .text, "text1, [text2], …", "Joins texts together"),
        f("CONCATENATE", .text, "text1, [text2], …", "Joins texts together"),
        f("TEXTJOIN", .text, "delimiter, ignore_empty, text1, …", "Joins texts with a delimiter"),
        f("SUBSTITUTE", .text, "text, old_text, new_text, [instance_num]", "Replaces old text with new text"),
        f("REPLACE", .text, "old_text, start_num, num_chars, new_text", "Replaces characters at a position"),
        f("FIND", .text, "find_text, within_text, [start_num]", "Position of a text (case-sensitive)"),
        f("SEARCH", .text, "find_text, within_text, [start_num]", "Position of a text (case-insensitive, wildcards)"),
        f("REPT", .text, "text, number_times", "Repeats a text"),
        f("EXACT", .text, "text1, text2", "Checks whether two texts are identical"),
        f("CHAR", .text, "number", "Character with a code"),
        f("UNICHAR", .text, "number", "Unicode character with a code"),
        f("CODE", .text, "text", "Code of the first character"),
        f("UNICODE", .text, "text", "Unicode code of the first character"),
        f("T", .text, "value", "The text, or empty if the value is not text"),
        f("TEXT", .text, "value, format_text", "Formats a number as text"),
        f("VALUE", .text, "text", "Converts text to a number"),
        // Logical
        f("IF", .logical, "logical_test, [value_if_true], [value_if_false]", "One value if a condition is true, another if false"),
        f("IFS", .logical, "logical_test1, value_if_true1, …", "Value of the first true condition"),
        f("IFERROR", .logical, "value, value_if_error", "A replacement value when a formula gives an error"),
        f("IFNA", .logical, "value, value_if_na", "A replacement value for #N/A"),
        f("AND", .logical, "logical1, [logical2], …", "TRUE if all arguments are true"),
        f("OR", .logical, "logical1, [logical2], …", "TRUE if any argument is true"),
        f("XOR", .logical, "logical1, [logical2], …", "TRUE if an odd number of arguments are true"),
        f("NOT", .logical, "logical", "Reverses a logical value"),
        f("TRUE", .logical, "", "The logical value TRUE"),
        f("FALSE", .logical, "", "The logical value FALSE"),
        f("SWITCH", .logical, "expression, value1, result1, …", "Result matching the first equal value"),
        f("CHOOSE", .logical, "index_num, value1, [value2], …", "Value at a position in the list"),
        // Date & time
        f("TODAY", .date, "", "Today's date"),
        f("NOW", .date, "", "Current date and time"),
        f("DATE", .date, "year, month, day", "Date from year, month and day"),
        f("TIME", .date, "hour, minute, second", "Time from hours, minutes and seconds"),
        f("YEAR", .date, "date", "Year of a date"),
        f("MONTH", .date, "date", "Month of a date (1–12)"),
        f("DAY", .date, "date", "Day of the month (1–31)"),
        f("WEEKDAY", .date, "date, [return_type]", "Day of the week"),
        f("HOUR", .date, "time", "Hour of a time (0–23)"),
        f("MINUTE", .date, "time", "Minute of a time (0–59)"),
        f("SECOND", .date, "time", "Second of a time (0–59)"),
        f("EDATE", .date, "start_date, months", "Date a number of months before or after"),
        f("EOMONTH", .date, "start_date, months", "Last day of the month a number of months away"),
        f("DAYS", .date, "end_date, start_date", "Number of days between two dates"),
        f("DATEDIF", .date, "start_date, end_date, unit", "Difference between dates in years, months or days"),
        f("NETWORKDAYS", .date, "start_date, end_date, [holidays]", "Number of working days between two dates"),
        f("WORKDAY", .date, "start_date, days, [holidays]", "Date a number of working days away"),
        // Lookup & reference
        f("VLOOKUP", .lookup, "lookup_value, table_array, col_index_num, [range_lookup]", "Looks up a value in the first column and returns a value from the row"),
        f("HLOOKUP", .lookup, "lookup_value, table_array, row_index_num, [range_lookup]", "Looks up a value in the first row and returns a value from the column"),
        f("XLOOKUP", .lookup, "lookup_value, lookup_array, return_array, [if_not_found], [match_mode]", "Looks up a value and returns the matching item"),
        f("INDEX", .lookup, "array, row_num, [column_num]", "Value at a row and column of a range"),
        f("MATCH", .lookup, "lookup_value, lookup_array, [match_type]", "Position of a value in a range"),
        f("OFFSET", .lookup, "reference, rows, cols, [height], [width]", "Reference shifted from a starting cell"),
        f("INDIRECT", .lookup, "ref_text", "Reference given by a text"),
        f("ROW", .lookup, "[reference]", "Row number of a reference"),
        f("COLUMN", .lookup, "[reference]", "Column number of a reference"),
        f("ROWS", .lookup, "array", "Number of rows in a range"),
        f("COLUMNS", .lookup, "array", "Number of columns in a range"),
        // Information
        f("ISBLANK", .information, "value", "TRUE if the cell is empty"),
        f("ISNUMBER", .information, "value", "TRUE if the value is a number"),
        f("ISTEXT", .information, "value", "TRUE if the value is text"),
        f("ISLOGICAL", .information, "value", "TRUE if the value is logical"),
        f("ISERROR", .information, "value", "TRUE if the value is any error"),
        f("ISERR", .information, "value", "TRUE if the value is an error other than #N/A"),
        f("ISNA", .information, "value", "TRUE if the value is #N/A"),
        f("NA", .information, "", "The error value #N/A"),
        f("N", .information, "value", "The value converted to a number"),
        // Financial
        f("PMT", .financial, "rate, nper, pv, [fv], [type]", "Payment for a loan with constant payments and rate"),
        f("FV", .financial, "rate, nper, pmt, [pv], [type]", "Future value of an investment"),
        f("PV", .financial, "rate, nper, pmt, [fv], [type]", "Present value of an investment"),
    ]

    static let byName: [String: Function] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    /// Name of the function whose argument list contains the caret, e.g. "=ROUND(SUM(A1;" → SUM,
    /// with the index of the argument being typed.
    static func call(at text: String) -> (function: Function, argument: Int)? {
        var depth = 0, argument = 0, inString = false
        let chars = Array(text)
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if c == "\"" { inString.toggle() }
            else if !inString {
                if c == ")" { depth += 1 }
                else if c == "(" {
                    if depth == 0 {
                        var j = i - 1
                        while j >= 0, chars[j].isLetter || chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j -= 1 }
                        let name = Formula.canonicalFunction(String(chars[(j + 1)..<i]))
                        guard let fn = byName[name] else { return nil }
                        return (fn, argument)
                    }
                    depth -= 1
                } else if (c == "," || c == ";"), depth == 0 { argument += 1 }
            }
            i -= 1
        }
        return nil
    }
}
