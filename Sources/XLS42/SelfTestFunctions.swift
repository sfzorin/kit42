import AppKit
import Kit42

/// Function values checked by `--selftest` (expected values verified against LibreOffice with `--lo-compare`).
extension SelfTest {
    /// Data block K1:X10 the cases refer to.
    static func functionData() -> [(String, String)] {
        var d: [(String, String)] = []
        let k = [3, 7, 2, 9, 4, 7, 1, 8, 5, 6]
        let l = ["apple", "Banana", "cherry", "apple", "date", "Elder", "fig", "grape", "apple", "kiwi"]
        let m = ["2024-01-15", "2024-02-29", "2023-12-31", "2024-07-04", "2025-03-10", "2020-02-29", "2024-11-04", "2019-06-15", "2024-12-25", "2026-01-01"]
        let n = ["2.1", "3.9", "6.2", "7.8", "10.1", "12.2", "13.8", "16.1", "18", "20.2"]
        for i in 0..<10 {
            d.append(("K\(i + 1)", "\(k[i])"))
            d.append(("L\(i + 1)", l[i]))
            d.append(("M\(i + 1)", "date:" + m[i]))
            d.append(("N\(i + 1)", n[i]))
            d.append(("O\(i + 1)", "\(i + 1)"))
        }
        for (i, v) in ["-1000", "300", "400", "400", "300", "100"].enumerated() { d.append(("P\(i + 1)", v)) }
        for (i, v) in ["2024-01-01", "2024-03-01", "2024-10-30", "2025-02-15", "2025-04-01", "2025-06-30"].enumerated() { d.append(("Q\(i + 1)", "date:" + v)) }
        d += [("R1", "TRUE"), ("R2", "text"), ("R4", "5"), ("R5", "=NA()"), ("R6", "0")]
        for (i, v) in ["1", "2", "3", "4", "5"].enumerated() { d.append(("U\(i + 1)", v)) }
        for (i, v) in ["5", "3", "8", "1", "9"].enumerated() { d.append(("V\(i + 1)", v)) }
        for (i, v) in ["10", "12", "20", "14", "25"].enumerated() { d.append(("W\(i + 1)", v)) }
        for (i, v) in ["2024-12-25", "2025-01-01", "2024-11-28"].enumerated() { d.append(("X\(i + 1)", "date:" + v)) }
        return d
    }

    /// (formula, expected) — expected nil: compared with LibreOffice only (random or locale-dependent).
    static let functionCases: [(String, String?)] = [
        // Conditional aggregates
        ("=SUMIFS(K1:K10,L1:L10,\"apple\")", "17"), ("=SUMIFS(K1:K10,L1:L10,\"apple\",K1:K10,\">4\")", "14"),
        ("=COUNTIFS(L1:L10,\"a*\",K1:K10,\"<5\")", "1"), ("=AVERAGEIFS(K1:K10,L1:L10,\"<>apple\")", "5"),
        ("=MAXIFS(K1:K10,L1:L10,\"apple\")", "9"), ("=MINIFS(K1:K10,M1:M10,\">=\"&DATE(2024,1,1))", "1"),
        ("=COUNTIF(L1:L10,\"?????\")", "5"), ("=SUMIF(K1:K10,\">5\")", "37"), ("=AVERAGEIFS(K1:K10,L1:L10,\"zzz\")", "#DIV/0!"),
        // Logic
        ("=IFERROR(1/0,\"x\")", "x"), ("=IFNA(NA(),\"n\")", "n"), ("=IFNA(1/0,\"n\")", "#DIV/0!"), ("=IFS(K1>5,\"a\",K1>2,\"b\")", "b"),
        ("=IFS(FALSE,1)", "#N/A"), ("=SWITCH(K2,7,\"seven\",9,\"nine\",\"other\")", "seven"), ("=SWITCH(3,1,\"a\")", "#N/A"),
        ("=XOR(TRUE,FALSE,TRUE)", "FALSE"), ("=XOR(K1>1,K2>10)", "TRUE"),
        // Lookup & reference
        ("=XLOOKUP(\"date\",L1:L10,K1:K10)", "4"), ("=XLOOKUP(\"zz\",L1:L10,K1:K10,\"none\")", "none"),
        ("=XLOOKUP(6.5,K1:K10,L1:L10,,1)", "Banana"), ("=XLOOKUP(6.5,K1:K10,L1:L10,,-1)", "kiwi"),
        ("=XLOOKUP(\"ap*\",L1:L10,K1:K10,,2)", "3"), ("=XLOOKUP(\"apple\",L1:L10,K1:K10,,0,-1)", "5"),
        ("=XLOOKUP(\"zz\",L1:L10,K1:K10)", "#N/A"), ("=SUM(XLOOKUP(4,O1:O10,K1:L10))", "9"),
        ("=XMATCH(9,K1:K10)", "4"), ("=XMATCH(6.5,K1:K10,1)", "2"), ("=XMATCH(\"apple\",L1:L10,0,-1)", "9"), ("=XMATCH(\"gr?pe\",L1:L10,2)", "8"),
        ("=INDEX(K1:L10,4,2)", "apple"), ("=INDEX(K1:K10,3)", "2"), ("=SUM(INDEX(K1:L10,0,1))", "52"), ("=SUM(INDEX(N1:O10,2,0))", "5.9"),
        ("=INDEX(K1:K10,11)", "#REF!"), ("=MATCH(7,K1:K10,0)", "2"), ("=MATCH(\"Elder\",L1:L10,0)", "6"),
        ("=LOOKUP(4.5,O1:O10,N1:N10)", "7.8"), ("=LOOKUP(2,1/(L1:L10=\"apple\"),K1:K10)", "5"), ("=LOOKUP(\"c\",{\"a\",\"b\",\"c\"},{1,2,3})", "3"),
        ("=HLOOKUP(2,{1,2,3;4,5,6},2,FALSE)", "5"), ("=VLOOKUP(5,O1:O10,1,FALSE)", "5"), ("=OFFSET(K1,2,1)", "cherry"),
        ("=SUM(OFFSET(K1,0,0,3,1))", "12"), ("=INDIRECT(\"K\"&4)", "9"), ("=SUM(INDIRECT(\"K1:K3\"))", "12"),
        ("=INDIRECT(\"R2C11\",FALSE)", "7"), ("=CHOOSE(2,\"a\",\"b\",\"c\")", "b"), ("=ROWS(K1:M10)", "10"), ("=COLUMNS(K1:M10)", "3"),
        ("=ADDRESS(2,3)", "$C$2"), ("=ADDRESS(2,3,4)", "C2"), ("=ADDRESS(2,3,2,FALSE)", "R2C[3]"), ("=ADDRESS(1,1,1,TRUE,\"Data sheet\")", "'Data sheet'!$A$1"),
        // Dynamic arrays (results summarised)
        ("=SUM(FILTER(K1:K10,K1:K10>5))", "37"), ("=ROWS(FILTER(K1:K10,L1:L10=\"apple\"))", "3"), ("=FILTER(K1:K10,K1:K10>100,\"none\")", "none"),
        ("=INDEX(SORT(K1:K10),1)", "1"), ("=INDEX(SORT(K1:K10,1,-1),2)", "8"), ("=INDEX(SORT(L1:L10),1)", "apple"),
        ("=INDEX(SORT(K1:L10,2,1),4,2)", "Banana"), ("=INDEX(SORTBY(L1:L10,K1:K10,-1),1)", "apple"), ("=ROWS(UNIQUE(L1:L10))", "8"),
        ("=ROWS(UNIQUE(L1:L10,FALSE,TRUE))", "7"), ("=SUM(SEQUENCE(4))", "10"), ("=SUM(SEQUENCE(3,2,10,5))", "135"), ("=INDEX(SEQUENCE(3,3),2,3)", "6"),
        ("=SUM(TRANSPOSE(K1:K3))", "12"), ("=COLUMNS(TRANSPOSE(K1:K10))", "10"), ("=ROWS(RANDARRAY(3,2))", "3"),
        ("=AND(RANDARRAY(5)>=0,RANDARRAY(5)<1)", "TRUE"), ("=SUMPRODUCT((K1:K10>4)*K1:K10)", "42"), ("=SUMPRODUCT(--(L1:L10=\"apple\"))", "3"),
        ("=SUM(K1:K3*O1:O3)", "23"), ("=MAX(IF(L1:L10=\"apple\",K1:K10))", "9"), ("=SUM(IFERROR(1/(K1:K10-7),0))", "-0.95"),
        ("=TEXTJOIN(\",\",TRUE,SORT(UNIQUE(L1:L3)))", "apple,Banana,cherry"), ("=SUM(LEN(L1:L3))", "17"), ("=SUM(ROUND(N1:N3*1.5,0))", "18"),
        ("=ROWS(VSTACK(K1:K3,K4:K5))", "5"), ("=COLUMNS(HSTACK(K1:K3,L1:L3))", "2"), ("=SUM(TOCOL(K1:L3,3))", "12"),
        ("=INDEX(CHOOSECOLS(K1:M3,2),2)", "Banana"), ("=SUM(TAKE(K1:K10,3))", "12"), ("=SUM(DROP(K1:K10,8))", "11"), ("=SUM(TAKE(K1:K10,-2))", "11"),
        ("=ROWS(EXPAND(K1:K2,4))", "4"), ("=COLUMNS(WRAPROWS(K1:K10,3))", "3"), ("=SUM(MMULT({1,2;3,4},{5;6}))", "56"),
        ("=MDETERM({1,2;3,4})", "-2"), ("=INDEX(MINVERSE({4,7;2,6}),1,1)", "0.6"), ("=SUM(MUNIT(3))", "3"), ("=INDEX(FREQUENCY(K1:K10,{3,6}),2)", "3"),
        ("=LET(x,5,y,x*2,x+y)", "15"), ("=SUM({1,2,3}*2)", "12"),
        // Text
        ("=TEXTJOIN(\"-\",FALSE,\"a\",\"\",\"b\")", "a--b"), ("=CONCAT(L1:L3)", "appleBananacherry"),
        ("=TEXTBEFORE(\"john.smith@x.com\",\"@\")", "john.smith"), ("=TEXTAFTER(\"a-b-c\",\"-\",2)", "c"), ("=TEXTAFTER(\"a-b-c\",\"-\",-1)", "c"),
        ("=TEXTBEFORE(\"a-b-c\",\"-\",-1)", "a-b"), ("=TEXTBEFORE(\"abc\",\"z\")", "#N/A"), ("=TEXTBEFORE(\"abc\",\"z\",,,,\"none\")", "none"),
        ("=TEXTAFTER(\"aXbxc\",\"x\",1,1)", "bxc"), ("=INDEX(TEXTSPLIT(\"a,b;c,d\",\",\",\";\"),2,1)", "c"), ("=COLUMNS(TEXTSPLIT(\"a,,b\",\",\",,TRUE))", "2"),
        ("=SUBSTITUTE(\"aaa\",\"a\",\"b\",2)", "aba"), ("=REPLACE(\"abcdef\",2,3,\"X\")", "aXef"), ("=REPT(\"ab\",3)", "ababab"),
        ("=PROPER(\"hello WORLD o'neil 2nd-place\")", "Hello World O'Neil 2Nd-Place"), ("=CLEAN(\"a\"&CHAR(10)&\"b\")", "ab"),
        ("=TRIM(\"  a   b  \")", "a b"), ("=VALUE(\"12.5\")", "12.5"), ("=NUMBERVALUE(\"1.234,5\",\",\",\".\")", "1234.5"), ("=NUMBERVALUE(\"12%\")", "0.12"),
        ("=UNICODE(\"Ж\")", "1046"), ("=UNICHAR(8364)", "€"), ("=LEN(\"Привет\")", "6"), ("=REGEX(\"abc123def\",\"[0-9]+\")", "123"),
        ("=REGEX(\"abc123def\",\"[0-9]+\",\"#\")", "abc#def"), ("=REGEX(\"a1b2c3\",\"[0-9]\",\"#\",\"g\")", "a#b#c#"), ("=REGEX(\"a1b2c3\",\"[0-9]\",,2)", "2"),
        ("=REGEX(\"abc\",\"z\")", "#N/A"), ("=FIXED(1234.567,-2,TRUE)", "1200"), ("=FIXED(1234.567,1)", nil), ("=EXACT(\"a\",\"A\")", "FALSE"),
        ("=FIND(\"b\",\"abcb\",3)", "4"), ("=SEARCH(\"B\",\"abcb\")", "2"), ("=MID(\"abcdef\",3,2)", "cd"), ("=LEFT(\"abc\")", "a"), ("=RIGHT(\"abc\",2)", "bc"),
        ("=CODE(\"A\")", "65"), ("=CHAR(65)", "A"), ("=T(5)", ""), ("=N(\"x\")", "0"), ("=N(TRUE)", "1"), ("=DOLLAR(-1234.5,1)", nil),
        // Dates
        ("=EDATE(DATE(2024,1,31),1)", "45351"), ("=EOMONTH(DATE(2024,2,10),-1)", "45322"), ("=NETWORKDAYS(DATE(2024,11,1),DATE(2024,12,31),X1:X3)", "41"),
        ("=NETWORKDAYS.INTL(DATE(2024,1,1),DATE(2024,1,31),11)", "27"), ("=NETWORKDAYS.INTL(DATE(2024,1,1),DATE(2024,1,31),\"0000110\")", "23"),
        ("=NETWORKDAYS(DATE(2024,1,31),DATE(2024,1,1))", "-23"), ("=WORKDAY(DATE(2024,12,20),5,X1:X3)", "45656"),
        ("=WORKDAY.INTL(DATE(2024,1,5),3,7)", "45300"), ("=WORKDAY(DATE(2024,1,10),-3)", "45296"), ("=WEEKNUM(DATE(2024,1,6))", "1"),
        ("=WEEKNUM(DATE(2024,1,7),2)", "1"), ("=WEEKNUM(DATE(2024,12,31),21)", "1"), ("=WEEKNUM(DATE(2023,12,31),1)", "53"),
        ("=ISOWEEKNUM(DATE(2021,1,3))", "53"), ("=ISOWEEKNUM(DATE(2020,12,31))", "53"), ("=WEEKDAY(DATE(2024,3,15),11)", "5"), ("=WEEKDAY(DATE(2024,3,15),3)", "4"),
        ("=WEEKDAY(DATE(2024,3,15),14)", "2"), ("=DATEDIF(DATE(2020,2,29),DATE(2024,2,28),\"Y\")", "3"), ("=DATEDIF(DATE(2020,2,29),DATE(2024,2,28),\"M\")", "47"),
        ("=DATEDIF(DATE(2023,5,20),DATE(2024,3,1),\"YD\")", "286"), ("=DATEDIF(DATE(2024,1,31),DATE(2024,3,1),\"MD\")", "-1"),
        ("=DATEDIF(DATE(2022,8,15),DATE(2024,3,1),\"YM\")", "6"), ("=DATEDIF(DATE(2024,1,1),DATE(2023,1,1),\"D\")", "#NUM!"),
        ("=YEARFRAC(DATE(2024,1,15),DATE(2024,7,15))", "0.5"), ("=YEARFRAC(DATE(2024,1,15),DATE(2024,7,15),1)", "0.4972677596"),
        ("=YEARFRAC(DATE(2024,1,15),DATE(2024,7,15),2)", "0.5055555556"), ("=YEARFRAC(DATE(2024,1,15),DATE(2024,7,15),3)", "0.498630137"),
        ("=YEARFRAC(DATE(2024,1,31),DATE(2024,7,31),4)", "0.5"), ("=YEARFRAC(DATE(2023,3,1),DATE(2025,2,28),1)", "1.998175182"),
        ("=DAYS(DATE(2024,3,1),DATE(2024,2,1))", "29"), ("=DAYS360(DATE(2024,1,31),DATE(2024,3,31))", "60"),
        ("=DAYS360(DATE(2024,2,29),DATE(2024,3,31),TRUE)", "31"), ("=DATEVALUE(\"2024-03-15\")", "45366"), ("=TIMEVALUE(\"18:30\")", "0.7708333333"),
        ("=HOUR(0.75)", "18"), ("=DATE(2024,14,1)", "45689"), ("=DATE(2024,3,0)", "45351"),
        // Math
        ("=ROUNDUP(3.14159,2)", "3.15"), ("=ROUNDDOWN(-3.14159,1)", "-3.1"), ("=ROUND(-2.5,0)", "-3"), ("=ROUND(1234.567,-2)", "1200"),
        ("=MROUND(10,3)", "9"), ("=MROUND(-10,3)", "#NUM!"), ("=CEILING(2.5,1)", "3"), ("=CEILING(-2.5,2)", "-2"), ("=CEILING(2.5,-2)", "#NUM!"),
        ("=FLOOR(-2.5,2)", "-4"), ("=CEILING.MATH(-5.5,2)", "-4"), ("=CEILING.MATH(-5.5,2,1)", "-6"), ("=FLOOR.MATH(-5.5,2)", "-6"),
        ("=FLOOR.MATH(-5.5,2,1)", "-4"), ("=CEILING.PRECISE(-4.3,2)", "-4"), ("=FLOOR.PRECISE(4.3,-2)", "4"), ("=TRUNC(-8.9)", "-8"),
        ("=TRUNC(3.14159,3)", "3.141"), ("=INT(-8.9)", "-9"), ("=MOD(-3,2)", "1"), ("=MOD(3,-2)", "-1"), ("=MOD(5,0)", "#DIV/0!"),
        ("=QUOTIENT(-7,2)", "-3"), ("=GCD(24,36,48)", "12"), ("=LCM(4,6,10)", "60"), ("=FACT(10)", "3628800"), ("=FACT(-1)", "#NUM!"),
        ("=COMBIN(10,3)", "120"), ("=COMBINA(4,3)", "20"), ("=PERMUT(10,3)", "720"), ("=PERMUTATIONA(3,2)", "9"), ("=SUMSQ(3,4)", "25"),
        ("=SUMX2MY2(K1:K3,O1:O3)", "48"), ("=SUMX2PY2(K1:K3,O1:O3)", "76"), ("=SUMXMY2(K1:K3,O1:O3)", "30"), ("=PRODUCT(K1:K4)", "378"),
        ("=POWER(2,0.5)", "1.414213562"), ("=SQRT(-1)", "#NUM!"), ("=LN(EXP(2))", "2"), ("=LOG(8,2)", "3"), ("=LOG10(1000)", "3"), ("=EXP(1)", "2.718281828"),
        ("=SIN(PI()/6)", "0.5"), ("=COS(0)", "1"), ("=TAN(PI()/4)", "1"), ("=ASIN(1)", "1.570796327"), ("=ACOS(-1)", "3.141592654"), ("=ATAN(1)", "0.7853981634"),
        ("=ATAN2(1,1)", "0.7853981634"), ("=ATAN2(-1,-1)", "-2.35619449"), ("=ATAN2(0,0)", "#DIV/0!"), ("=SINH(1)", "1.175201194"), ("=COSH(1)", "1.543080635"),
        ("=TANH(0.5)", "0.4621171573"), ("=ASINH(1)", "0.881373587"), ("=ACOSH(2)", "1.316957897"), ("=ATANH(0.5)", "0.5493061443"),
        ("=COT(1)", "0.6420926159"), ("=COTH(1)", "1.313035285"), ("=CSC(1)", "1.188395106"), ("=CSCH(1)", "0.8509181282"), ("=SEC(1)", "1.850815718"),
        ("=SECH(1)", "0.6480542737"), ("=ACOT(2)", "0.463647609"), ("=ACOTH(2)", "0.5493061443"), ("=DEGREES(PI())", "180"), ("=RADIANS(180)", "3.141592654"),
        ("=SQRTPI(2)", "2.506628275"), ("=FACTDOUBLE(7)", "105"), ("=MULTINOMIAL(2,3,4)", "1260"), ("=ROMAN(1999)", "MCMXCIX"),
        ("=ARABIC(\"MCMXCIX\")", "1999"), ("=BASE(255,16,4)", "00FF"), ("=DECIMAL(\"FF\",16)", "255"), ("=SERIESSUM(2,1,1,{1,2,3})", "34"),
        ("=AND(RAND()>=0,RAND()<1)", "TRUE"), ("=AND(RANDBETWEEN(1,6)>=1,RANDBETWEEN(1,6)<=6)", "TRUE"),
        ("=SUBTOTAL(9,K1:K10)", "52"), ("=SUBTOTAL(1,K1:K10)", "5.2"), ("=SUBTOTAL(109,K1:K10)", "52"), ("=AGGREGATE(14,6,K1:K10,2)", "8"),
        ("=AGGREGATE(9,6,R1:R6)", "5"), ("=AGGREGATE(12,4,K1:K10)", "5.5"),
        // Statistics
        ("=MEDIAN(K1:K10)", "5.5"), ("=MODE.SNGL(K1:K10)", "7"), ("=MODE(K1:K10)", "7"), ("=ROWS(MODE.MULT({1,1,2,2,3}))", "2"),
        ("=STDEV.S(K1:K10)", "2.658320272"), ("=STDEV.P(K1:K10)", "2.521904043"), ("=VAR.S(K1:K10)", "7.066666667"), ("=VAR.P(K1:K10)", "6.36"),
        ("=STDEV(K1:K10)", "2.658320272"), ("=VAR(K1:K10)", "7.066666667"), ("=STDEVP(K1:K10)", "2.521904043"), ("=VARP(K1:K10)", "6.36"),
        ("=STDEVA(R1:R4)", "2.645751311"), ("=VARA(R1:R4)", "7"), ("=MAXA(R1:R4)", "5"), ("=MINA(R1:R4)", "0"), ("=LARGE(K1:K10,2)", "8"),
        ("=SMALL(K1:K10,3)", "3"), ("=LARGE(K1:K10,11)", "#NUM!"), ("=RANK.EQ(7,K1:K10)", "3"), ("=RANK.AVG(7,K1:K10)", "3.5"),
        ("=RANK.EQ(7,K1:K10,1)", "7"), ("=RANK(10,K1:K10)", "#N/A"), ("=PERCENTILE.INC(K1:K10,0.3)", "3.7"), ("=PERCENTILE.EXC(K1:K10,0.3)", "3.3"),
        ("=PERCENTILE(K1:K10,1)", "9"), ("=PERCENTILE.EXC(K1:K10,0.05)", "#NUM!"), ("=QUARTILE.INC(K1:K10,1)", "3.25"), ("=QUARTILE.EXC(K1:K10,3)", "7.25"),
        ("=QUARTILE(K1:K10,4)", "9"), ("=PERCENTRANK.INC(K1:K10,7)", "0.666"), ("=PERCENTRANK.INC(K1:K10,6.5)", "0.611"), ("=PERCENTRANK.EXC(K1:K10,4)", "0.363"),
        ("=PERCENTRANK(K1:K10,5.5,2)", "0.5"), ("=CORREL(N1:N10,O1:O10)", "0.9996697884"), ("=PEARSON(N1:N10,O1:O10)", "0.9996697884"),
        ("=SLOPE(N1:N10,O1:O10)", "2.007272727"), ("=INTERCEPT(N1:N10,O1:O10)", "0"), ("=RSQ(N1:N10,O1:O10)", "0.9993396858"),
        ("=STEYX(N1:N10,O1:O10)", "0.1656941322"), ("=FORECAST(11,N1:N10,O1:O10)", "22.08"), ("=FORECAST.LINEAR(0,N1:N10,O1:O10)", "0"),
        ("=TREND(N1:N10,O1:O10,12)", "24.08727273"), ("=GROWTH(N1:N10,O1:O10,11)", "32.06896302"), ("=INDEX(LINEST(N1:N10,O1:O10),1)", "2.007272727"),
        ("=INDEX(LINEST(N1:N10,O1:O10),2)", "0"), ("=INDEX(LINEST(N1:N10,O1:O10,TRUE,TRUE),3,1)", "0.9993396858"),
        ("=INDEX(LINEST(N1:N10,O1:O10,TRUE,TRUE),2,1)", "0.01824232357"), ("=INDEX(LINEST(N1:N10,O1:O10,TRUE,TRUE),4,1)", "12107.44371"),
        ("=INDEX(LINEST(N1:N10,O1:O10,TRUE,TRUE),5,2)", "0.2196363636"), ("=INDEX(LINEST(W1:W5,U1:V5),1)", "1.082524272"),
        ("=INDEX(LINEST(W1:W5,U1:V5),2)", "2.550485437"), ("=INDEX(LINEST(W1:W5,U1:V5),3)", "2.919417476"),
        ("=INDEX(LINEST(N1:N10,O1:O10,FALSE),1)", "2.007272727"), ("=INDEX(LOGEST(N1:N10,O1:O10),1)", "1.25708571"),
        ("=COVARIANCE.P(N1:N10,O1:O10)", "16.56"), ("=COVARIANCE.S(N1:N10,O1:O10)", "18.4"), ("=COVAR(N1:N10,O1:O10)", "16.56"),
        ("=COUNTBLANK(R1:R6)", "1"), ("=AVERAGEA(R1:R4)", "2"), ("=AVEDEV(K1:K10)", "2.2"), ("=DEVSQ(K1:K10)", "63.6"),
        ("=GEOMEAN(K1:K10)", "4.370046994"), ("=HARMEAN(K1:K10)", "3.364935238"), ("=KURT(K1:K10)", "-1.136080456"), ("=SKEW(K1:K10)", "-0.2235771321"),
        ("=SKEW.P(K1:K10)", "-0.1885367921"), ("=STANDARDIZE(5,4,2)", "0.5"),
        ("=NORM.DIST(1.5,1,2,TRUE)", "0.5987063257"), ("=NORM.DIST(1.5,1,2,FALSE)", "0.1933340584"), ("=NORM.INV(0.9,10,2)", "12.56310313"),
        ("=NORM.S.DIST(1.96,TRUE)", "0.9750021049"), ("=NORM.S.DIST(0.5,FALSE)", "0.3520653268"), ("=NORM.S.INV(0.975)", "1.959963985"),
        ("=NORMSDIST(-1)", "0.1586552539"), ("=NORMSINV(0.01)", "-2.326347874"), ("=NORMDIST(42,40,1.5,TRUE)", "0.9087887803"),
        ("=NORMINV(0.3,0,1)", "-0.5244005127"), ("=NORM.INV(1,0,1)", "#NUM!"), ("=T.DIST(1.5,10,TRUE)", "0.9177463368"),
        ("=T.DIST(1.5,10,FALSE)", "0.1274447943"), ("=T.DIST.2T(2.1,15)", "0.05305525615"), ("=T.DIST.RT(1.8,20)", "0.04348235089"),
        ("=TDIST(2,5,2)", "0.1019394788"), ("=T.INV(0.95,10)", "1.812461123"), ("=T.INV.2T(0.05,10)", "2.228138852"), ("=TINV(0.1,3)", "2.353363435"),
        ("=BINOM.DIST(3,10,0.3,FALSE)", "0.266827932"), ("=BINOM.DIST(3,10,0.3,TRUE)", "0.6496107184"), ("=BINOMDIST(5,8,0.5,TRUE)", "0.85546875"),
        ("=BINOM.INV(10,0.5,0.7)", "6"), ("=CRITBINOM(20,0.3,0.5)", "6"), ("=POISSON.DIST(3,2.5,FALSE)", "0.2137630172"),
        ("=POISSON.DIST(3,2.5,TRUE)", "0.7575761331"), ("=POISSON(0,1,FALSE)", "0.3678794412"), ("=EXPON.DIST(0.5,2,TRUE)", "0.6321205588"),
        ("=EXPON.DIST(0.5,2,FALSE)", "0.7357588823"), ("=EXPONDIST(1,1,TRUE)", "0.6321205588"), ("=CHISQ.DIST(3,4,TRUE)", "0.4421745996"),
        ("=CHISQ.DIST(3,4,FALSE)", "0.1673476201"), ("=CHISQ.DIST.RT(3,4)", "0.5578254004"), ("=CHIDIST(5,3)", "0.1717971443"),
        ("=CHISQ.INV(0.95,4)", "9.487729037"), ("=CHISQ.INV.RT(0.05,4)", "9.487729037"), ("=CHIINV(0.1,2)", "4.605170186"),
        ("=F.DIST(2,5,10,TRUE)", "0.8358050491"), ("=F.DIST(2,5,10,FALSE)", "0.1620057422"), ("=F.DIST.RT(2,5,10)", "0.1641949509"),
        ("=F.INV(0.9,5,10)", "2.521640686"), ("=F.INV.RT(0.1,5,10)", "2.521640686"), ("=GAMMA.DIST(2,3,1.5,TRUE)", "0.1506314438"),
        ("=GAMMA.DIST(2,3,1.5,FALSE)", "0.1562057115"), ("=GAMMA.INV(0.5,3,1.5)", "4.011090471"), ("=GAMMA(5)", "24"), ("=GAMMA(0.5)", "1.772453851"),
        ("=GAMMALN(10)", "12.80182748"), ("=BETA.DIST(0.4,2,3,TRUE)", "0.5248"), ("=BETA.DIST(0.4,2,3,FALSE)", "1.728"), ("=BETA.INV(0.5,2,3)", "0.3857275681"),
        ("=LOGNORM.DIST(2,0,1,TRUE)", "0.7558914042"), ("=LOGNORM.INV(0.5,1,0.5)", "2.718281828"), ("=WEIBULL.DIST(1.5,2,1,TRUE)", "0.8946007754"),
        ("=FISHER(0.5)", "0.5493061443"), ("=FISHERINV(0.5)", "0.4621171573"), ("=PHI(1)", "0.2419707245"), ("=GAUSS(1)", "0.3413447461"),
        ("=CONFIDENCE.NORM(0.05,2,50)", "0.5543615297"), ("=CONFIDENCE.T(0.05,2,50)", "0.568393711"), ("=ERF(1)", "0.8427007929"),
        ("=ERFC(1)", "0.1572992071"), ("=ERF(0,1)", "0.8427007929"),
        // Financial
        ("=PMT(0.05/12,360,200000)", "-1073.643246"), ("=PMT(0,10,1000)", "-100"), ("=PMT(0.06,10,-10000,0,1)", "1281.773191"),
        ("=IPMT(0.1/12,1,36,8000)", "-66.66666667"), ("=IPMT(0.1,3,3,8000)", "-292.4471299"), ("=PPMT(0.1/12,1,24,2000)", "-75.62318601"),
        ("=PPMT(0.08,10,10,200000,0,1)", "-25553.75321"), ("=PV(0.08/12,240,500)", "-59777.14585"), ("=FV(0.06/12,10,-200,-500,1)", "2581.403374"),
        ("=NPER(0.12/12,-100,-1000,10000,1)", "59.67386567"), ("=NPER(0,-100,1000)", "10"), ("=RATE(48,-200,8000)", "0.007701472488"),
        ("=RATE(12,-100,1000,0,0,0.1)", "0.02922854077"), ("=NPV(0.1,-10000,3000,4200,6800)", "1188.443412"), ("=NPV(0.08,P2:P6)+P1", "226.8134778"),
        ("=XNPV(0.09,P1:P6,Q1:Q6)", "388.4565423"), ("=IRR(P1:P6)", "0.1719433619"), ("=IRR({-70000,12000,15000,18000,21000},-0.1)", "-0.02124484827"),
        ("=XIRR(P1:P6,Q1:Q6)", "0.6007182858"), ("=MIRR(P1:P6,0.1,0.12)", "0.1454390903"), ("=SLN(30000,7500,10)", "2250"),
        ("=SYD(30000,7500,10,1)", "4090.909091"), ("=DDB(2400,300,10,1)", "480"), ("=DDB(2400,300,10,10)", "22.1225472"),
        ("=DB(1000000,100000,6,1,7)", "186083.3333"), ("=DB(1000000,100000,6,7,7)", "15845.09847"), ("=EFFECT(0.0525,4)", "0.05354266737"),
        ("=NOMINAL(0.053543,4)", "0.05250031987"), ("=CUMIPMT(0.09/12,360,125000,13,24,0)", "-11135.23213"),
        ("=CUMPRINC(0.09/12,360,125000,13,24,0)", "-934.1071234"), ("=CUMIPMT(0.09/12,360,125000,1,1,0)", "-937.5"),
        ("=FVSCHEDULE(1,{0.09,0.11,0.1})", "1.33089"), ("=PDURATION(0.025,2000,2200)", "3.859866163"), ("=RRI(96,10000,11000)", "0.0009933073763"),
        ("=ISPMT(0.1/12,1,36,8000000)", "-64814.81481"),
        // Information
        ("=ISBLANK(R3)", "TRUE"), ("=ISNUMBER(R4)", "TRUE"), ("=ISTEXT(R2)", "TRUE"), ("=ISLOGICAL(R1)", "TRUE"), ("=ISERROR(R5)", "TRUE"),
        ("=ISERR(R5)", "FALSE"), ("=ISNA(R5)", "TRUE"), ("=ISFORMULA(R5)", "TRUE"), ("=ISFORMULA(R4)", "FALSE"), ("=ISEVEN(-2.5)", "TRUE"),
        ("=ISODD(3)", "TRUE"), ("=ISEVEN(\"x\")", "#VALUE!"), ("=TYPE(5)", "1"), ("=TYPE(\"a\")", "2"), ("=TYPE(TRUE)", "4"), ("=TYPE(R5)", "16"),
        ("=TYPE({1,2})", "64"), ("=N(R1)", "1"), ("=ISREF(K1)", "TRUE"), ("=ISREF(5)", "FALSE"), ("=ERROR.TYPE(R5)", "7"), ("=ERROR.TYPE(1/0)", "2"),
        ("=CELL(\"address\",K3)", "$K$3"), ("=CELL(\"col\",M2)", "13"), ("=CELL(\"row\",M2)", "2"), ("=CELL(\"type\",L1)", "l"), ("=CELL(\"type\",R3)", "b"),
        ("=CELL(\"contents\",K2)", "7"), ("=SHEET()", "1"), ("=SHEETS()", "1"), ("=NA()", "#N/A"), ("=ISNA(XMATCH(99,K1:K10))", "TRUE"),
        // Engineering
        ("=CONVERT(1,\"mi\",\"km\")", "1.609344"), ("=CONVERT(100,\"C\",\"F\")", "212"), ("=CONVERT(1,\"lbm\",\"kg\")", "0.45359237"),
        ("=CONVERT(1,\"gal\",\"l\")", "3.785411784"), ("=CONVERT(1,\"hr\",\"mn\")", "60"), ("=CONVERT(1,\"atm\",\"Pa\")", "101325"),
        ("=CONVERT(1,\"kWh\",\"J\")", "3600000"), ("=CONVERT(1,\"byte\",\"bit\")", "8"), ("=CONVERT(1,\"m\",\"kg\")", "#N/A"),
        ("=CONVERT(1,\"ft2\",\"m2\")", "0.09290304"), ("=CONVERT(1,\"in3\",\"ml\")", "16.387064"), ("=CONVERT(60,\"mph\",\"km/h\")", "96.56064"),
        ("=CONVERT(0,\"K\",\"C\")", "-273.15"), ("=DEC2BIN(10)", "1010"), ("=DEC2BIN(-1)", "1111111111"), ("=DEC2BIN(10,8)", "00001010"),
        ("=DEC2BIN(512)", "#NUM!"), ("=BIN2DEC(\"1111111111\")", "-1"), ("=BIN2DEC(1010)", "10"), ("=DEC2HEX(255)", "FF"), ("=DEC2HEX(-1)", "FFFFFFFFFF"),
        ("=HEX2DEC(\"FF\")", "255"), ("=HEX2DEC(\"FFFFFFFFFF\")", "-1"), ("=DEC2OCT(64)", "100"), ("=OCT2DEC(\"777\")", "511"),
        ("=BIN2HEX(\"11111111\")", "FF"), ("=HEX2BIN(\"F\",8)", "00001111"), ("=OCT2HEX(\"17\")", "F"), ("=HEX2OCT(\"1F\")", "37"),
        ("=BIN2OCT(\"111\")", "7"), ("=OCT2BIN(\"7\")", "111"), ("=BITAND(13,25)", "9"), ("=BITOR(13,25)", "29"), ("=BITXOR(13,25)", "20"),
        ("=BITLSHIFT(4,2)", "16"), ("=BITRSHIFT(13,2)", "3"), ("=DELTA(5,5)", "1"), ("=GESTEP(3,5)", "0"),
    ]

    /// Data + one case per row in column A.
    static func functionWorkbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Functions"
        func put(_ a1: String, _ input: String) {
            var c = Cell()
            if input.hasPrefix("date:") {
                let parts = input.dropFirst(5).split(separator: "-").compactMap { Int($0) }
                c.value = .number(DateMath.serial(year: parts[0], month: parts[1], day: parts[2]) ?? 0)
                c.style.numberFormat = "yyyy-mm-dd"
                c.input = XLSX.inputText(for: c.value, style: c.style)
            } else {
                c.input = input
                c.value = input.hasPrefix("=") ? .empty : XLSX.constant(input)
            }
            wb.sheets[0][CellRef(a1)!] = c
        }
        for (a1, v) in functionData() { put(a1, v) }
        for (i, c) in functionCases.enumerated() {
            var cell = Cell()
            cell.input = "=" + Formula.serialize(try! Formula.parse(c.0))
            wb.sheets[0][CellRef(row: i, col: 0)] = cell
        }
        return wb
    }

    static func display(_ v: Value) -> String {
        switch v {
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let d): return String(format: "%.10g", d)
        default: return v.plain
        }
    }

    /// Checks every case with an expected value. Returns the number of failures.
    static func functions() -> Int {
        var failed = 0
        let wb = Calculator.recalculate(functionWorkbook())
        var checked = 0
        for (i, c) in functionCases.enumerated() {
            guard let expected = c.1 else { continue }
            checked += 1
            let got = display(wb.sheets[0][CellRef(row: i, col: 0)].value)
            if !same(got, expected) {
                failed += 1
                print("FAIL", c.0, "→", got, "(expected \(expected))")
            }
        }
        print(failed == 0 ? "ok  " : "FAIL", "function values: \(checked - failed)/\(checked) as expected")
        // Spilling
        var s = Workbook()
        func set(_ a1: String, _ input: String) {
            var c = Cell()
            c.input = input
            c.value = input.hasPrefix("=") ? .empty : XLSX.constant(input)
            s.sheets[0][CellRef(a1)!] = c
        }
        set("A1", "3"); set("A2", "1"); set("A3", "2")
        set("C1", "=SORT(A1:A3)"); set("D1", "=SEQUENCE(2,3)"); set("D5", "=C2*10"); set("H1", "=TRANSPOSE(A1:A3)")
        set("H3", "x"); set("H2", "=SEQUENCE(2)")
        set("J2", "=IF(A1:A3>1,\"y\",\"n\")"); set("K2", "=IFERROR(1/(A1:A3-1),\"e\")"); set("L2", "=LEN(A1:A3)&\"!\"")
        s = Calculator.recalculate(s)
        func v(_ a1: String) -> String { display(s.sheets[0][CellRef(a1)!].value) }
        let spillOK = [v("C1"), v("C2"), v("C3")] == ["1", "2", "3"] && v("F2") == "6" && v("D5") == "20"
            && [v("H1"), v("I1"), v("J1")] == ["3", "1", "2"] && v("J2") == "n" && v("K2") == "e" && v("L2") == "1!" && v("H2") == "#SPILL!" && s.sheets[0].spills[CellRef("C1")!] == CellRange("C1:C3")
        print(spillOK ? "ok  " : "FAIL", "dynamic arrays spill, #SPILL! when blocked, implicit intersection otherwise", spillOK ? "" : "\(v("C2")) \(v("F2")) \(v("D5")) \(v("I1")) \(v("H2"))")
        if !spillOK { failed += 1 }
        // Spills survive .xlsx and .ods (array formulas over their range) and recalculate after reopening.
        for (kind, data) in [("xlsx", XLSX.write(s)), ("ods", ODS.write(s))] {
            let back = (try? SpreadsheetFile.read(data)).map(Calculator.recalculate)
            let c = back?.sheets[0]
            let ok = c.map { display($0[CellRef("C3")!].value) == "3" && $0[CellRef("C2")!].input.isEmpty && $0.spills[CellRef("D1")!] == CellRange("D1:F2") } ?? false
            print(ok ? "ok  " : "FAIL", "spilled arrays round trip in .\(kind)")
            if !ok { failed += 1 }
        }
        let xml = String(decoding: (try? ZipArchive(data: XLSX.write(s)))?["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        let marked = xml.contains("<c r=\"C1\" cm=\"1\"><f t=\"array\" ref=\"C1:C3\">_xlfn._xlws.SORT(A1:A3)</f>")
        print(marked ? "ok  " : "FAIL", "dynamic array written with cm=\"1\" and _xlfn._xlws. prefix")
        if !marked { failed += 1 }
        // LET/LAMBDA via a defined name
        var l = Workbook()
        l.names["DOUBLE"] = "LAMBDA(x,x*2)"
        set2(&l, "A1", "=DOUBLE(21)")
        l = Calculator.recalculate(l)
        let lambdaOK = l.sheets[0][CellRef("A1")!].value == .number(42)
        print(lambdaOK ? "ok  " : "FAIL", "LAMBDA in a defined name")
        if !lambdaOK { failed += 1 }
        return failed
    }

    private static func set2(_ wb: inout Workbook, _ a1: String, _ input: String) {
        var c = Cell()
        c.input = input
        wb.sheets[0][CellRef(a1)!] = c
    }

    /// Equal as numbers within 1e-9 (relative), otherwise as text.
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let x = Double(a), let y = Double(b) { return abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) }
        return false
    }

    // MARK: - LibreOffice comparison

    /// `XLS42 --lo-compare [dir]`: writes the cases to .xlsx without results, lets LibreOffice compute them
    /// (headless, private profile), and compares with XLS42's values.
    static func loCompare(dir: String, soffice: String) -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // "ods": the same through an OpenDocument file (checks the ODF function names too).
        let ods = CommandLine.arguments.contains("ods")
        let xlsx = URL(fileURLWithPath: dir).appendingPathComponent(ods ? "functions.ods" : "functions.xlsx")
        let wb = functionWorkbook()
        try? (ods ? ODS.write(wb) : XLSX.write(wb)).write(to: xlsx)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: soffice)
        p.arguments = ["-env:UserInstallation=file://\(dir)/lo-profile", "--headless", "--convert-to",
                       "csv:Text - txt - csv (StarCalc):44,34,76,1,,1033,false,true,false,false,false", "--outdir", dir, xlsx.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { print("cannot run \(soffice)"); return 1 }
        p.waitUntilExit()
        guard let csv = try? String(contentsOfFile: dir + "/functions.csv", encoding: .utf8) else { print("no CSV from LibreOffice"); return 1 }
        let rows = parseCSV(csv)
        let ours = Calculator.recalculate(wb)
        var same = 0, errorsBoth = 0, differ: [String] = []
        for (i, c) in functionCases.enumerated() {
            let lo = i < rows.count && !rows[i].isEmpty ? rows[i][0] : ""
            let v = ours.sheets[0][CellRef(row: i, col: 0)].value
            let mine = display(v)
            // LibreOffice formats some results (percent for RATE/IRR, dates for DATE, booleans for MAXA).
            var loNum = Double(lo)
            if loNum == nil, lo.hasSuffix("%"), let d = Double(lo.dropLast()) { loNum = d / 100 }
            if loNum == nil, case let p = lo.split(separator: "/").compactMap({ Int($0) }), p.count == 3 { loNum = DateMath.serial(year: p[2], month: p[0], day: p[1]) }
            if loNum == nil, case .number = v, lo == "TRUE" || lo == "FALSE" { loNum = lo == "TRUE" ? nil : 0; if lo == "TRUE", case .number(let d) = v, d != 0 { loNum = d } }
            var ok = false
            if case .number(let d) = v, let loNum { ok = abs(d - loNum) <= 1e-9 * max(1, abs(d), abs(loNum)) }
            else if v.isError, lo.hasPrefix("#") || lo.hasPrefix("Err:") { ok = true; errorsBoth += 1 }
            else { ok = mine == lo || mine.uppercased() == lo.uppercased() && (lo == "TRUE" || lo == "FALSE") }
            if ok { same += 1 } else { differ.append("\(c.0)\n      XLS42: \(mine)\n      LibreOffice: \(lo)") }
            if CommandLine.arguments.contains("verbose") { print(ok ? "same" : "DIFF", c.0, "→", mine, "| LO:", lo) }
        }
        print("LibreOffice comparison: \(same) of \(functionCases.count) cases agree (\(errorsBoth) of them are errors in both)")
        for d in differ { print("DIFF", d) }
        return 0
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(ch) }
                continue
            }
            switch ch {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n": row.append(field); field = ""; rows.append(row); row = []
            case "\r": break
            default: field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
