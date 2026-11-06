//! Small, bounded spreadsheet expression evaluator. Raw cells remain authoritative.
use crate::{CellContent, SheetId, Workbook};
use std::collections::{HashMap, HashSet};

const MAX_DEPTH: usize = 128;
const MAX_STEPS: usize = 1_000_000;
const MAX_FORMULA: usize = 4096;

#[derive(Clone, Debug, PartialEq)]
enum Value {
    Number(f64),
    Text(String),
    Boolean(bool),
    Error(&'static str),
}
impl Value {
    fn display(self) -> String {
        match self {
            Self::Number(0.0) => "0".into(),
            Self::Number(n) => n.to_string(),
            Self::Text(s) => s,
            Self::Boolean(v) => {
                if v {
                    "TRUE".into()
                } else {
                    "FALSE".into()
                }
            }
            Self::Error(e) => e.into(),
        }
    }
}
struct Eval<'a> {
    book: &'a Workbook,
    cache: HashMap<(SheetId, usize, usize), Value>,
    visiting: HashSet<(SheetId, usize, usize)>,
    steps: usize,
    text_bytes: usize,
}
impl Eval<'_> {
    fn raw(&self, sheet: SheetId, row: usize, col: usize) -> Option<&str> {
        let s = self
            .book
            .history
            .current()
            .sheets
            .iter()
            .find(|s| s.id == sheet)?;
        if row >= s.rows || col >= s.cols {
            return None;
        }
        Some(s.cells.get(&(row, col)).map_or("", |c| c.text.raw()))
    }
    fn content(&self, sheet: SheetId, row: usize, col: usize) -> Option<&CellContent> {
        let s = self
            .book
            .history
            .current()
            .sheets
            .iter()
            .find(|s| s.id == sheet)?;
        s.cells.get(&(row, col)).map(|c| &c.text)
    }
    fn range_cell(
        &mut self,
        sheet: SheetId,
        row: usize,
        col: usize,
        depth: usize,
    ) -> Option<Value> {
        self.raw(sheet, row, col)?;
        if !matches!(
            self.content(sheet, row, col),
            Some(CellContent::Number(_) | CellContent::Date(_) | CellContent::Formula(_))
        ) {
            return None;
        }
        Some(self.cell(sheet, row, col, depth))
    }
    fn cell(&mut self, sheet: SheetId, row: usize, col: usize, depth: usize) -> Value {
        if self.raw(sheet, row, col).is_none() {
            return Value::Error("#REF!");
        }
        let key = (sheet, row, col);
        if let Some(v) = self.cache.get(&key) {
            return v.clone();
        }
        if self.visiting.contains(&key) {
            return Value::Error("#CYCLE!");
        }
        if depth > MAX_DEPTH || self.steps >= MAX_STEPS {
            return Value::Error("#LIMIT!");
        }
        self.steps += 1;
        self.visiting.insert(key);
        let raw = self.raw(sheet, row, col).unwrap().to_owned();
        let v = if matches!(self.content(sheet, row, col), Some(CellContent::Formula(_))) {
            let expr = raw.strip_prefix('=').unwrap();
            if expr.len() > MAX_FORMULA {
                Value::Error("#LIMIT!")
            } else {
                let mut p = Parser {
                    input: expr.as_bytes(),
                    pos: 0,
                    eval: self,
                    depth,
                    sheet,
                };
                let result = p.comparison();
                p.space();
                if p.pos != p.input.len() && !matches!(result, Value::Error(_)) {
                    Value::Error("#ERROR!")
                } else {
                    result
                }
            }
        } else if raw.trim().is_empty() {
            Value::Number(0.0)
        } else if matches!(self.content(sheet, row, col), Some(CellContent::Number(_))) {
            match raw.trim().parse::<f64>() {
                Ok(n) if n.is_finite() => Value::Number(n),
                _ => Value::Error("#VALUE!"),
            }
        } else if matches!(self.content(sheet, row, col), Some(CellContent::Date(_))) {
            match crate::display::parse_serial(&raw).or_else(|| raw.parse::<f64>().ok()) {
                Some(v) => finite(v),
                None => Value::Error("#VALUE!"),
            }
        } else if matches!(self.content(sheet, row, col), Some(CellContent::Boolean(_))) {
            Value::Boolean(raw.eq_ignore_ascii_case("true"))
        } else {
            Value::Text(raw.clone())
        };
        self.visiting.remove(&key);
        let v = match v {
            Value::Text(t)
                if t.len() > crate::MAX_TEXT
                    || self.text_bytes.saturating_add(t.len()) > crate::MAX_TEXT * 2 =>
            {
                Value::Error("#LIMIT!")
            }
            Value::Text(t) => {
                self.text_bytes += t.len();
                Value::Text(t)
            }
            v => v,
        };
        self.cache.insert(key, v.clone());
        v
    }
}
struct Parser<'a, 'b> {
    input: &'a [u8],
    pos: usize,
    eval: &'a mut Eval<'b>,
    depth: usize,
    sheet: SheetId,
}
impl Parser<'_, '_> {
    fn space(&mut self) {
        while self
            .input
            .get(self.pos)
            .is_some_and(u8::is_ascii_whitespace)
        {
            self.pos += 1;
        }
    }
    fn take(&mut self, c: u8) -> bool {
        self.space();
        if self.input.get(self.pos) == Some(&c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn comparison(&mut self) -> Value {
        let left = self.expr();
        self.space();
        let remaining = &self.input[self.pos..];
        let (op, len) = if remaining.starts_with(b"<=") {
            (0, 2)
        } else if remaining.starts_with(b">=") {
            (1, 2)
        } else if remaining.starts_with(b"<>") {
            (2, 2)
        } else if remaining.starts_with(b"=") {
            (3, 1)
        } else if remaining.starts_with(b"<") {
            (4, 1)
        } else if remaining.starts_with(b">") {
            (5, 1)
        } else {
            return left;
        };
        self.pos += len;
        let right = self.expr();
        let ordering = match (left, right) {
            (Value::Error(e), _) | (_, Value::Error(e)) => return Value::Error(e),
            (Value::Number(a), Value::Number(b)) => a.partial_cmp(&b),
            (Value::Text(a), Value::Text(b)) => Some(a.to_lowercase().cmp(&b.to_lowercase())),
            (Value::Boolean(a), Value::Boolean(b)) => Some(a.cmp(&b)),
            _ => return Value::Error("#VALUE!"),
        };
        let Some(order) = ordering else {
            return Value::Error("#NUM!");
        };
        let yes = match op {
            0 => order != std::cmp::Ordering::Greater,
            1 => order != std::cmp::Ordering::Less,
            2 => order != std::cmp::Ordering::Equal,
            3 => order == std::cmp::Ordering::Equal,
            4 => order == std::cmp::Ordering::Less,
            _ => order == std::cmp::Ordering::Greater,
        };
        Value::Boolean(yes)
    }
    fn expr(&mut self) -> Value {
        let mut v = self.additive();
        while self.take(b'&') {
            let right = self.additive();
            v = match (v, right) {
                (Value::Error(e), _) | (_, Value::Error(e)) => Value::Error(e),
                (a, b) => {
                    let a = a.display();
                    let b = b.display();
                    if a.len().saturating_add(b.len()) > crate::MAX_TEXT {
                        Value::Error("#LIMIT!")
                    } else {
                        Value::Text(a + &b)
                    }
                }
            }
        }
        v
    }
    fn additive(&mut self) -> Value {
        let mut v = self.term();
        loop {
            if self.take(b'+') {
                let r = self.term();
                v = calc(v, r, b'+');
            } else if self.take(b'-') {
                let r = self.term();
                v = calc(v, r, b'-');
            } else {
                return v;
            }
        }
    }
    fn term(&mut self) -> Value {
        let mut v = self.unary();
        loop {
            if self.take(b'*') {
                let r = self.unary();
                v = calc(v, r, b'*');
            } else if self.take(b'/') {
                let r = self.unary();
                v = calc(v, r, b'/');
            } else {
                return v;
            }
        }
    }
    fn unary(&mut self) -> Value {
        self.space();
        if self.depth >= MAX_DEPTH {
            return Value::Error("#LIMIT!");
        }
        if self.take(b'+') {
            self.depth += 1;
            let v = self.unary();
            self.depth -= 1;
            v
        } else if self.take(b'-') {
            self.depth += 1;
            let v = self.unary();
            self.depth -= 1;
            match v {
                Value::Number(n) => Value::Number(-n),
                Value::Boolean(v) => Value::Number(if v { -1.0 } else { 0.0 }),
                Value::Error(e) => Value::Error(e),
                Value::Text(_) => Value::Error("#VALUE!"),
            }
        } else {
            self.power()
        }
    }
    fn power(&mut self) -> Value {
        let left = self.primary();
        if self.take(b'^') {
            self.depth += 1;
            let right = self.unary();
            self.depth -= 1;
            calc(left, right, b'^')
        } else {
            left
        }
    }
    fn primary(&mut self) -> Value {
        self.space();
        if self.take(b'(') {
            self.depth += 1;
            let v = self.comparison();
            self.depth -= 1;
            return if self.take(b')') {
                v
            } else {
                Value::Error("#ERROR!")
            };
        }
        if self.input.get(self.pos) == Some(&b'"') {
            self.pos += 1;
            let mut result = String::new();
            loop {
                let Some(&ch) = self.input.get(self.pos) else {
                    return Value::Error("#ERROR!");
                };
                if ch == b'"' {
                    self.pos += 1;
                    if self.input.get(self.pos) == Some(&b'"') {
                        result.push('"');
                        self.pos += 1
                    } else {
                        break;
                    }
                } else {
                    let Ok(t) = std::str::from_utf8(&self.input[self.pos..]) else {
                        return Value::Error("#ERROR!");
                    };
                    let ch = t.chars().next().unwrap();
                    result.push(ch);
                    self.pos += ch.len_utf8();
                }
            }
            return Value::Text(result);
        }
        if self.input[self.pos..].starts_with(b"#REF!") {
            self.pos += 5;
            return Value::Error("#REF!");
        }
        let start = self.pos;
        if let Some((sheet, row, col)) = self.read_qualified_ref() {
            return self.eval.cell(sheet, row, col, self.depth + 1);
        }
        self.pos = start;
        if self.input.get(self.pos) == Some(&b'$')
            || self
                .input
                .get(self.pos)
                .is_some_and(u8::is_ascii_alphabetic)
        {
            if self.input.get(self.pos) == Some(&b'$') {
                self.pos += 1;
            }
            while self
                .input
                .get(self.pos)
                .is_some_and(u8::is_ascii_alphabetic)
            {
                self.pos += 1;
            }
            let letters_end = self.pos;
            if self.input.get(self.pos) == Some(&b'$') {
                self.pos += 1;
            }
            let digits_start = self.pos;
            while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
                self.pos += 1;
            }
            if self.pos > digits_start {
                return match reference(&self.input[start..self.pos]) {
                    Some((r, c)) => self.eval.cell(self.sheet, r, c, self.depth + 1),
                    None => Value::Error("#REF!"),
                };
            }
            let name = std::str::from_utf8(&self.input[start..letters_end])
                .unwrap_or("")
                .to_ascii_uppercase();
            if !self.take(b'(') {
                return match name.as_str() {
                    "TRUE" => Value::Boolean(true),
                    "FALSE" => Value::Boolean(false),
                    _ => Value::Error("#ERROR!"),
                };
            }
            self.depth += 1;
            if matches!(name.as_str(), "IF" | "IFERROR" | "AND" | "OR") {
                let value = self.lazy_conditional(&name);
                self.depth -= 1;
                return value;
            }
            let value = self.function(&name);
            self.depth -= 1;
            return value;
        }
        while self
            .input
            .get(self.pos)
            .is_some_and(|c| c.is_ascii_digit() || *c == b'.')
        {
            self.pos += 1;
        }
        if start == self.pos {
            return Value::Error("#ERROR!");
        }
        match std::str::from_utf8(&self.input[start..self.pos])
            .ok()
            .and_then(|s| s.parse::<f64>().ok())
        {
            Some(n) => finite(n),
            None => Value::Error("#ERROR!"),
        }
    }
    fn function(&mut self, name: &str) -> Value {
        if self.depth > MAX_DEPTH {
            return Value::Error("#LIMIT!");
        }
        if matches!(name, "COUNTIF" | "SUMIF" | "INDEX" | "MATCH" | "VLOOKUP") {
            return self.range_function(name);
        }
        if matches!(
            name,
            "LEN"
                | "LOWER"
                | "UPPER"
                | "TRIM"
                | "LEFT"
                | "RIGHT"
                | "MID"
                | "CONCAT"
                | "CONCATENATE"
                | "EXACT"
        ) {
            return self.text_function(name);
        }
        let aggregate = matches!(
            name,
            "SUM" | "AVERAGE" | "MIN" | "MAX" | "COUNT" | "COUNTA" | "PRODUCT"
        );
        let mut values = Vec::new();
        let mut nonempty = 0usize;
        if !self.take(b')') {
            loop {
                let start = self.pos;
                let reference = self.read_any_ref(self.sheet);
                let has_colon = reference.is_some() && self.take(b':');
                self.space();
                let single =
                    reference.is_some() && matches!(self.input.get(self.pos), Some(b',' | b')'));
                if aggregate && (has_colon || single) {
                    let a = reference.unwrap();
                    let b = if has_colon {
                        let Some(b) = self.read_any_ref(a.0) else {
                            return Value::Error("#ERROR!");
                        };
                        b
                    } else {
                        a
                    };
                    let Some(target) = self
                        .eval
                        .book
                        .history
                        .current()
                        .sheets
                        .iter()
                        .find(|s| s.id == a.0)
                    else {
                        return Value::Error("#REF!");
                    };
                    if a.0 != b.0
                        || a.1 > b.1
                        || a.2 > b.2
                        || b.1 >= target.rows
                        || b.2 >= target.cols
                    {
                        return Value::Error("#REF!");
                    }
                    for r in a.1..=b.1 {
                        for c in a.2..=b.2 {
                            self.eval.steps += 1;
                            if self.eval.steps > MAX_STEPS {
                                return Value::Error("#LIMIT!");
                            }
                            if !self.eval.raw(a.0, r, c).unwrap_or("").is_empty() {
                                nonempty += 1
                            }
                            match self.eval.range_cell(a.0, r, c, self.depth + 1) {
                                Some(Value::Number(n)) => values.push(n),
                                Some(Value::Error(e)) if name != "COUNT" && name != "COUNTA" => {
                                    return Value::Error(e)
                                }
                                _ => {}
                            }
                        }
                    }
                } else {
                    self.pos = start;
                    match self.comparison() {
                        Value::Number(n) => {
                            values.push(n);
                            nonempty += 1
                        }
                        Value::Error(e) => return Value::Error(e),
                        Value::Text(_) | Value::Boolean(_) => return Value::Error("#VALUE!"),
                    }
                }
                if self.take(b')') {
                    break;
                }
                if !self.take(b',') {
                    return Value::Error("#ERROR!");
                }
                if values.len() > MAX_STEPS {
                    return Value::Error("#LIMIT!");
                }
            }
        }
        if aggregate {
            return match name {
                "COUNT" => finite(values.len() as f64),
                "COUNTA" => finite(nonempty as f64),
                "SUM" => finite(values.iter().sum()),
                "PRODUCT" => finite(if values.is_empty() {
                    0.0
                } else {
                    values.iter().product()
                }),
                "AVERAGE" if values.is_empty() => Value::Error("#DIV/0!"),
                "AVERAGE" => finite(values.iter().sum::<f64>() / values.len() as f64),
                "MIN" => finite(values.iter().copied().reduce(f64::min).unwrap_or(0.0)),
                "MAX" => finite(values.iter().copied().reduce(f64::max).unwrap_or(0.0)),
                _ => Value::Error("#ERROR!"),
            };
        }
        let arg = |n: usize| values.get(n).copied();
        let one = values.len() == 1;
        match name {
            "DATE" if values.len() == 3 => {
                if values
                    .iter()
                    .any(|v| !v.is_finite() || v.abs() > 1_000_000.0)
                {
                    return Value::Error("#NUM!");
                }
                let y = values[0].trunc() as i32;
                let m = values[1].trunc() as i64;
                let d = values[2].trunc() as i64;
                let year = if (0..1900).contains(&y) { y + 1900 } else { y };
                let normalized = (year as i64) * 12 + m - 1;
                let y = normalized.div_euclid(12);
                let month = normalized.rem_euclid(12) + 1;
                let Some(date) = i32::try_from(y)
                    .ok()
                    .and_then(|y| chrono::NaiveDate::from_ymd_opt(y, month as u32, 1))
                    .and_then(|v| v.checked_add_signed(chrono::Duration::try_days(d - 1)?))
                else {
                    return Value::Error("#NUM!");
                };
                match crate::display::date_to_serial(date) {
                    Some(n) => finite(n),
                    None => Value::Error("#NUM!"),
                }
            }
            "YEAR" | "MONTH" | "DAY" if one => {
                use chrono::Datelike;
                match crate::display::serial_to_date(values[0]) {
                    Some(d) => finite(match name {
                        "YEAR" => d.year() as f64,
                        "MONTH" => d.month() as f64,
                        _ => d.day() as f64,
                    }),
                    None => Value::Error("#NUM!"),
                }
            }
            "PI" if values.is_empty() => finite(std::f64::consts::PI),
            "ABS" if one => finite(values[0].abs()),
            "SQRT" if one && values[0] >= 0.0 => finite(values[0].sqrt()),
            "SQRT" if one => Value::Error("#NUM!"),
            "SIN" if one => finite(values[0].sin()),
            "COS" if one => finite(values[0].cos()),
            "TAN" if one => finite(values[0].tan()),
            "EXP" if one => finite(values[0].exp()),
            "LOG10" if one && values[0] > 0.0 => finite(values[0].log10()),
            "LOG10" if one => Value::Error("#NUM!"),
            "RADIANS" if one => finite(values[0].to_radians()),
            "DEGREES" if one => finite(values[0].to_degrees()),
            "TRUNC" if one => finite(values[0].trunc()),
            "POWER" if values.len() == 2 => finite(values[0].powf(values[1])),
            "MOD" if values.len() == 2 && values[1] == 0.0 => Value::Error("#DIV/0!"),
            "MOD" if values.len() == 2 => {
                finite(values[0] - values[1] * (values[0] / values[1]).floor())
            }
            "LOG" if values.len() == 1 && values[0] > 0.0 => finite(values[0].log10()),
            "LOG"
                if values.len() == 2 && values[0] > 0.0 && values[1] > 0.0 && values[1] != 1.0 =>
            {
                finite(values[0].log(values[1]))
            }
            "LOG" => Value::Error("#NUM!"),
            "ROUNDUP" | "ROUNDDOWN" if values.len() == 2 => {
                let p = values[1].trunc().clamp(-308.0, 308.0) as i32;
                let factor = 10f64.powi(p);
                let n = values[0] * factor;
                finite(
                    (if name == "ROUNDUP" {
                        n.abs().ceil() * n.signum()
                    } else {
                        n.trunc()
                    }) / factor,
                )
            }
            "FACT" if one && values[0] >= 0.0 && values[0].trunc() <= 170.0 => {
                finite((1..=values[0].trunc() as u32).fold(1.0, |a, b| a * b as f64))
            }
            "FACT" if one => Value::Error("#NUM!"),
            "LN" if one && values[0] > 0.0 => finite(values[0].ln()),
            "LN" if one => Value::Error("#NUM!"),
            "INT" if one => finite(values[0].floor()),
            "SIGN" if one => finite(if values[0] == 0.0 {
                0.0
            } else {
                values[0].signum()
            }),
            "ROUND" if values.len() == 2 => {
                let p = arg(1).unwrap().trunc().clamp(-308.0, 308.0) as i32;
                let factor = 10f64.powi(p);
                finite((values[0] * factor).round() / factor)
            }
            _ => Value::Error("#ERROR!"),
        }
    }
    fn read_range(&mut self) -> Option<(SheetId, usize, usize, usize, usize)> {
        let first = self.read_any_ref(self.sheet)?;
        let last = if self.take(b':') {
            self.read_any_ref(first.0)?
        } else {
            first
        };
        if first.0 != last.0 || first.1 > last.1 || first.2 > last.2 {
            return None;
        }
        let sheet = self
            .eval
            .book
            .history
            .current()
            .sheets
            .iter()
            .find(|s| s.id == first.0)?;
        if last.1 >= sheet.rows || last.2 >= sheet.cols {
            return None;
        }
        Some((first.0, first.1, first.2, last.1, last.2))
    }
    fn range_function(&mut self, name: &str) -> Value {
        if name == "COUNTIF" || name == "SUMIF" {
            let Some(range) = self.read_range() else {
                return Value::Error("#REF!");
            };
            if !self.take(b',') {
                return Value::Error("#ERROR!");
            }
            let criterion = self.comparison();
            if let Value::Error(_) = criterion {
                return criterion;
            }
            let sum_range = if name == "SUMIF" && self.take(b',') {
                let Some(r) = self.read_range() else {
                    return Value::Error("#REF!");
                };
                Some(r)
            } else {
                None
            };
            if !self.take(b')') {
                return Value::Error("#ERROR!");
            }
            let mut total = 0.0;
            for r in range.1..=range.3 {
                for c in range.2..=range.4 {
                    self.eval.steps += 1;
                    if self.eval.steps > MAX_STEPS {
                        return Value::Error("#LIMIT!");
                    }
                    let raw = self.eval.raw(range.0, r, c).unwrap_or("").to_owned();
                    let value = self.eval.cell(range.0, r, c, self.depth + 1);
                    if let Value::Text(spec) = &criterion {
                        if spec.contains(['*', '?', '~']) {
                            let len = match &value {
                                Value::Text(t) => t.len(),
                                _ => raw.len(),
                            };
                            self.eval.steps = self
                                .eval
                                .steps
                                .saturating_add(spec.len().saturating_mul(len));
                            if self.eval.steps > MAX_STEPS {
                                return Value::Error("#LIMIT!");
                            }
                        }
                    }
                    if criterion_matches(&value, &raw, &criterion) {
                        if name == "COUNTIF" {
                            total += 1.0
                        } else {
                            let target = sum_range.unwrap_or(range);
                            let rr = target.1 + r - range.1;
                            let cc = target.2 + c - range.2;
                            if self.eval.raw(target.0, rr, cc).is_none() {
                                return Value::Error("#REF!");
                            }
                            match self.eval.cell(target.0, rr, cc, self.depth + 1) {
                                Value::Number(v) => total += v,
                                Value::Error(e) => return Value::Error(e),
                                _ => {}
                            }
                        }
                    }
                }
            }
            return finite(total);
        }
        if name == "INDEX" {
            let Some(range) = self.read_range() else {
                return Value::Error("#REF!");
            };
            if !self.take(b',') {
                return Value::Error("#ERROR!");
            }
            let row = self.comparison();
            let col = if self.take(b',') {
                self.comparison()
            } else {
                Value::Number(1.0)
            };
            if !self.take(b')') {
                return Value::Error("#ERROR!");
            }
            let (Value::Number(r), Value::Number(c)) = (row, col) else {
                return Value::Error("#VALUE!");
            };
            if r < 1.0
                || c < 1.0
                || r.trunc() > (range.3 - range.1 + 1) as f64
                || c.trunc() > (range.4 - range.2 + 1) as f64
            {
                return Value::Error("#REF!");
            }
            let rr = range.1 + r.trunc() as usize - 1;
            let cc = range.2 + c.trunc() as usize - 1;
            if rr > range.3 || cc > range.4 {
                return Value::Error("#REF!");
            }
            return self.eval.cell(range.0, rr, cc, self.depth + 1);
        }
        let needle = self.comparison();
        if let Value::Error(_) = needle {
            return needle;
        }
        if !self.take(b',') {
            return Value::Error("#ERROR!");
        }
        let Some(range) = self.read_range() else {
            return Value::Error("#REF!");
        };
        let arg = if self.take(b',') {
            self.comparison()
        } else if name == "MATCH" {
            Value::Number(1.0)
        } else {
            return Value::Error("#ERROR!");
        };
        let exact = if name == "VLOOKUP" && self.take(b',') {
            self.comparison()
        } else {
            Value::Boolean(true)
        };
        if !self.take(b')') {
            return Value::Error("#ERROR!");
        }
        if name == "MATCH" {
            let Value::Number(mode) = arg else {
                return Value::Error("#VALUE!");
            };
            let mode = if mode > 0.0 {
                1
            } else if mode < 0.0 {
                -1
            } else {
                0
            };
            if range.1 != range.3 && range.2 != range.4 {
                return Value::Error("#N/A");
            }
            let length = (range.3 - range.1).max(range.4 - range.2) + 1;
            let mut best: Option<(usize, Value)> = None;
            for i in 0..length {
                self.eval.steps += 1;
                if self.eval.steps > MAX_STEPS {
                    return Value::Error("#LIMIT!");
                }
                let r = range.1 + if range.1 == range.3 { 0 } else { i };
                let c = range.2 + if range.2 == range.4 { 0 } else { i };
                let value = self.eval.cell(range.0, r, c, self.depth + 1);
                let equal = lookup_equal(&needle, &value)
                    || mode == 0
                        && matches!((&needle,&value),(Value::Text(a),Value::Text(b)) if wildcard(a,b));
                if equal {
                    return Value::Number((i + 1) as f64);
                }
                if mode != 0 {
                    let candidate = lookup_order(&value, &needle).is_some_and(|o| {
                        if mode == 1 {
                            !o.is_gt()
                        } else {
                            !o.is_lt()
                        }
                    });
                    let improvement = best.as_ref().is_none_or(|(_, old)| {
                        lookup_order(&value, old).is_some_and(|o| {
                            if mode == 1 {
                                o.is_gt()
                            } else {
                                o.is_lt()
                            }
                        })
                    });
                    if candidate && improvement {
                        best = Some((i, value))
                    }
                }
            }
            if let Some((index, _)) = best {
                return Value::Number((index + 1) as f64);
            }
            Value::Error("#N/A")
        } else {
            let Value::Number(col) = arg else {
                return Value::Error("#VALUE!");
            };
            if col < 1.0 {
                return Value::Error("#VALUE!");
            }
            if col.trunc() > (range.4 - range.2 + 1) as f64 {
                return Value::Error("#REF!");
            }
            let approximate = match exact {
                Value::Number(n) => n != 0.0,
                Value::Boolean(v) => v,
                _ => return Value::Error("#VALUE!"),
            };
            let col = range.2 + col.trunc() as usize - 1;
            if col > range.4 {
                return Value::Error("#REF!");
            }
            let mut best: Option<(usize, Value)> = None;
            for r in range.1..=range.3 {
                self.eval.steps += 1;
                if self.eval.steps > MAX_STEPS {
                    return Value::Error("#LIMIT!");
                }
                let value = self.eval.cell(range.0, r, range.2, self.depth + 1);
                if lookup_equal(&needle, &value) {
                    return self.eval.cell(range.0, r, col, self.depth + 1);
                }
                if approximate
                    && lookup_order(&value, &needle).is_some_and(|o| !o.is_gt())
                    && best
                        .as_ref()
                        .is_none_or(|(_, b)| lookup_order(&value, b).is_some_and(|o| o.is_gt()))
                {
                    best = Some((r, value))
                }
            }
            if let Some((row, _)) = best {
                return self.eval.cell(range.0, row, col, self.depth + 1);
            }
            Value::Error("#N/A")
        }
    }
    fn text_function(&mut self, name: &str) -> Value {
        let mut args = Vec::new();
        if !self.take(b')') {
            loop {
                let v = self.comparison();
                if let Value::Error(_) = v {
                    return v;
                }
                args.push(v);
                if self.take(b')') {
                    break;
                }
                if !self.take(b',') || args.len() > 1024 {
                    return Value::Error("#ERROR!");
                }
            }
        }
        let string = |n: usize| args.get(n).cloned().map(Value::display);
        let number = |n: usize, default: usize| -> Option<usize> {
            match args.get(n) {
                None => Some(default),
                Some(Value::Number(v)) if *v >= 0.0 && v.is_finite() => {
                    Some(v.trunc().min(1_000_000.0) as usize)
                }
                _ => None,
            }
        };
        let result = match name {
            "LEN" if args.len() == 1 => Value::Number(string(0).unwrap().chars().count() as f64),
            "LOWER" if args.len() == 1 => Value::Text(string(0).unwrap().to_lowercase()),
            "UPPER" if args.len() == 1 => Value::Text(string(0).unwrap().to_uppercase()),
            "TRIM" if args.len() == 1 => Value::Text(
                string(0)
                    .unwrap()
                    .split(' ')
                    .filter(|x| !x.is_empty())
                    .collect::<Vec<_>>()
                    .join(" "),
            ),
            "CONCAT" | "CONCATENATE" => {
                let mut out = String::new();
                for arg in args {
                    let v = arg.display();
                    if out.len().saturating_add(v.len()) > crate::MAX_TEXT {
                        return Value::Error("#LIMIT!");
                    }
                    out.push_str(&v)
                }
                Value::Text(out)
            }
            "EXACT" if args.len() == 2 => Value::Boolean(string(0) == string(1)),
            "LEFT" | "RIGHT" if (1..=2).contains(&args.len()) => {
                let Some(count) = number(1, 1) else {
                    return Value::Error("#VALUE!");
                };
                let chars: Vec<_> = string(0).unwrap().chars().collect();
                let start = if name == "RIGHT" {
                    chars.len().saturating_sub(count)
                } else {
                    0
                };
                Value::Text(chars.into_iter().skip(start).take(count).collect())
            }
            "MID" if args.len() == 3 => {
                let Some(start) = number(1, 0).and_then(|v| v.checked_sub(1)) else {
                    return Value::Error("#VALUE!");
                };
                let Some(count) = number(2, 0) else {
                    return Value::Error("#VALUE!");
                };
                Value::Text(string(0).unwrap().chars().skip(start).take(count).collect())
            }
            _ => Value::Error("#ERROR!"),
        };
        match result {
            Value::Text(s) if s.len() > crate::MAX_TEXT => Value::Error("#LIMIT!"),
            other => other,
        }
    }
    fn read_qualified_ref(&mut self) -> Option<(SheetId, usize, usize)> {
        self.space();
        let start = self.pos;
        let name = if self.input.get(self.pos) == Some(&b'\'') {
            self.pos += 1;
            let mut name = Vec::new();
            loop {
                let ch = *self.input.get(self.pos)?;
                self.pos += 1;
                if ch == b'\'' {
                    if self.input.get(self.pos) == Some(&b'\'') {
                        name.push(ch);
                        self.pos += 1
                    } else {
                        break;
                    }
                } else {
                    name.push(ch)
                }
            }
            String::from_utf8(name).ok()?
        } else {
            let begin = self.pos;
            while self
                .input
                .get(self.pos)
                .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'.')
            {
                self.pos += 1
            }
            if begin == self.pos {
                self.pos = start;
                return None;
            }
            std::str::from_utf8(&self.input[begin..self.pos])
                .ok()?
                .to_string()
        };
        if self.input.get(self.pos) != Some(&b'!') {
            self.pos = start;
            return None;
        }
        self.pos += 1;
        let id = self
            .eval
            .book
            .history
            .current()
            .sheets
            .iter()
            .find(|s| s.name.eq_ignore_ascii_case(&name))
            .map(|s| s.id);
        let Some(id) = id else {
            self.pos = start;
            return None;
        };
        let Some((r, c)) = self.read_ref() else {
            self.pos = start;
            return None;
        };
        Some((id, r, c))
    }
    fn read_any_ref(&mut self, default: SheetId) -> Option<(SheetId, usize, usize)> {
        let start = self.pos;
        if let Some(v) = self.read_qualified_ref() {
            return Some(v);
        }
        self.pos = start;
        self.read_ref().map(|(r, c)| (default, r, c))
    }
    fn lazy_conditional(&mut self, name: &str) -> Value {
        let start = self.pos;
        let mut i = self.pos;
        let mut level = 0usize;
        let mut quoted = false;
        let mut sheet_quoted = false;
        let mut segments = Vec::new();
        let mut part = start;
        while i < self.input.len() {
            let ch = self.input[i];
            if ch == b'"' && !sheet_quoted {
                if quoted && self.input.get(i + 1) == Some(&b'"') {
                    i += 2;
                    continue;
                }
                quoted = !quoted
            } else if ch == b'\'' && !quoted {
                if sheet_quoted && self.input.get(i + 1) == Some(&b'\'') {
                    i += 2;
                    continue;
                }
                sheet_quoted = !sheet_quoted;
            } else if !quoted && !sheet_quoted {
                match ch {
                    b'(' => level += 1,
                    b')' if level == 0 => {
                        segments.push(&self.input[part..i]);
                        self.pos = i + 1;
                        break;
                    }
                    b')' => level -= 1,
                    b',' if level == 0 => {
                        segments.push(&self.input[part..i]);
                        part = i + 1
                    }
                    _ => {}
                }
            }
            i += 1
        }
        if self.pos == start {
            return Value::Error("#ERROR!");
        }
        if (name == "IF" && segments.len() != 3)
            || (name == "IFERROR" && segments.len() != 2)
            || ((name == "AND" || name == "OR") && segments.is_empty())
        {
            return Value::Error("#ERROR!");
        }
        let eval_arg = |this: &mut Self, idx: usize| {
            let mut p = Parser {
                input: segments[idx],
                pos: 0,
                eval: this.eval,
                depth: this.depth,
                sheet: this.sheet,
            };
            let v = p.comparison();
            p.space();
            if p.pos != p.input.len() {
                Value::Error("#ERROR!")
            } else {
                v
            }
        };
        if name == "AND" || name == "OR" {
            for i in 0..segments.len() {
                let value = eval_arg(self, i);
                let truth = match value {
                    Value::Number(v) => v != 0.0,
                    Value::Boolean(v) => v,
                    Value::Error(e) => return Value::Error(e),
                    _ => return Value::Error("#VALUE!"),
                };
                if name == "AND" && !truth {
                    return Value::Boolean(false);
                }
                if name == "OR" && truth {
                    return Value::Boolean(true);
                }
            }
            return Value::Boolean(name == "AND");
        }
        let first = eval_arg(self, 0);
        if name == "IFERROR" {
            if matches!(first, Value::Error(_)) {
                eval_arg(self, 1)
            } else {
                first
            }
        } else {
            match first {
                Value::Number(n) => eval_arg(self, if n != 0.0 { 1 } else { 2 }),
                Value::Boolean(v) => eval_arg(self, if v { 1 } else { 2 }),
                Value::Text(_) => Value::Error("#VALUE!"),
                e => e,
            }
        }
    }
    fn read_ref(&mut self) -> Option<(usize, usize)> {
        self.space();
        let start = self.pos;
        if self.input.get(self.pos) == Some(&b'$') {
            self.pos += 1;
        }
        while self
            .input
            .get(self.pos)
            .is_some_and(u8::is_ascii_alphabetic)
        {
            self.pos += 1;
        }
        if self.input.get(self.pos) == Some(&b'$') {
            self.pos += 1;
        }
        while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
            self.pos += 1;
        }
        reference(&self.input[start..self.pos])
    }
}
fn lookup_order(a: &Value, b: &Value) -> Option<std::cmp::Ordering> {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a.partial_cmp(b),
        (Value::Text(a), Value::Text(b)) => Some(a.to_lowercase().cmp(&b.to_lowercase())),
        (Value::Boolean(a), Value::Boolean(b)) => Some(a.cmp(b)),
        _ => None,
    }
}
fn lookup_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a == b,
        (Value::Text(a), Value::Text(b)) => a.eq_ignore_ascii_case(b),
        (Value::Boolean(a), Value::Boolean(b)) => a == b,
        _ => false,
    }
}
fn wildcard(pattern: &str, value: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let v: Vec<char> = value.to_lowercase().chars().collect();
    if p.len().saturating_mul(v.len()) > 100_000 {
        return false;
    }
    let mut previous = vec![false; v.len() + 1];
    previous[0] = true;
    let mut i = 0;
    while i < p.len() {
        let mut next = vec![false; v.len() + 1];
        let mut ch = p[i];
        let escaped = ch == '~' && i + 1 < p.len();
        if escaped {
            i += 1;
            ch = p[i]
        }
        if ch == '*' && !escaped {
            next[0] = previous[0];
            for j in 1..=v.len() {
                next[j] = previous[j] || next[j - 1]
            }
        } else {
            for j in 1..=v.len() {
                next[j] = previous[j - 1] && (ch == v[j - 1] || (ch == '?' && !escaped))
            }
        }
        previous = next;
        i += 1
    }
    previous[v.len()]
}
fn criterion_matches(value: &Value, raw: &str, criterion: &Value) -> bool {
    let Value::Text(spec) = criterion else {
        return lookup_equal(value, criterion);
    };
    let (op, body) = if let Some(v) = spec.strip_prefix(">=") {
        (0, v)
    } else if let Some(v) = spec.strip_prefix("<=") {
        (1, v)
    } else if let Some(v) = spec.strip_prefix("<>") {
        (2, v)
    } else if let Some(v) = spec.strip_prefix('>') {
        (3, v)
    } else if let Some(v) = spec.strip_prefix('<') {
        (4, v)
    } else if let Some(v) = spec.strip_prefix('=') {
        (5, v)
    } else {
        (5, spec.as_str())
    };
    if body.is_empty() && (op == 5 || op == 2) {
        return if op == 5 {
            raw.is_empty()
        } else {
            !raw.is_empty()
        };
    }
    let ordering = if let Ok(n) = body.parse::<f64>() {
        if let Value::Number(v) = value {
            v.partial_cmp(&n)
        } else {
            None
        }
    } else {
        Some(
            value
                .clone()
                .display()
                .to_lowercase()
                .cmp(&body.to_lowercase()),
        )
    };
    if (op == 5 || op == 2) && body.contains(['*', '?', '~']) {
        let matched = wildcard(body, &value.clone().display());
        return if op == 5 { matched } else { !matched };
    }
    let Some(ord) = ordering else { return false };
    match op {
        0 => !ord.is_lt(),
        1 => !ord.is_gt(),
        2 => !ord.is_eq(),
        3 => ord.is_gt(),
        4 => ord.is_lt(),
        _ => ord.is_eq(),
    }
}
fn reference(s: &[u8]) -> Option<(usize, usize)> {
    let clean: Vec<u8> = s.iter().copied().filter(|c| *c != b'$').collect();
    let s = clean.as_slice();
    let split = s.iter().position(u8::is_ascii_digit)?;
    if split == 0 {
        return None;
    }
    let mut col = 0usize;
    for c in &s[..split] {
        if !c.is_ascii_alphabetic() {
            return None;
        }
        col = col
            .checked_mul(26)?
            .checked_add((c.to_ascii_uppercase() - b'A' + 1) as usize)?;
    }
    let row = std::str::from_utf8(&s[split..])
        .ok()?
        .parse::<usize>()
        .ok()?;
    Some((row.checked_sub(1)?, col.checked_sub(1)?))
}
fn finite(n: f64) -> Value {
    if n.is_finite() {
        Value::Number(n)
    } else {
        Value::Error("#NUM!")
    }
}
fn calc(a: Value, b: Value, op: u8) -> Value {
    match (a, b) {
        (Value::Error(e), _) | (_, Value::Error(e)) => Value::Error(e),
        (Value::Number(a), Value::Number(b)) => match op {
            b'+' => finite(a + b),
            b'-' => finite(a - b),
            b'*' => finite(a * b),
            b'^' => finite(a.powf(b)),
            b'/' if b == 0.0 => Value::Error("#DIV/0!"),
            b'/' => finite(a / b),
            _ => Value::Error("#ERROR!"),
        },
        (Value::Boolean(a), Value::Number(b)) => calc(
            Value::Number(if a { 1.0 } else { 0.0 }),
            Value::Number(b),
            op,
        ),
        (Value::Number(a), Value::Boolean(b)) => calc(
            Value::Number(a),
            Value::Number(if b { 1.0 } else { 0.0 }),
            op,
        ),
        (Value::Boolean(a), Value::Boolean(b)) => calc(
            Value::Number(if a { 1.0 } else { 0.0 }),
            Value::Number(if b { 1.0 } else { 0.0 }),
            op,
        ),
        _ => Value::Error("#VALUE!"),
    }
}

pub(crate) fn display_grid(book: &Workbook) -> Vec<Vec<String>> {
    let mut eval = Eval {
        book,
        cache: HashMap::new(),
        visiting: HashSet::new(),
        steps: 0,
        text_bytes: 0,
    };
    (0..book.rows())
        .map(|r| {
            (0..book.cols())
                .map(|c| {
                    let raw = book.cell(r, c).unwrap();
                    if matches!(book.content(r, c), Some(CellContent::Formula(_))) {
                        eval.cell(book.active_sheet(), r, c, 0).display()
                    } else {
                        raw.to_owned()
                    }
                })
                .collect()
        })
        .collect()
}

pub(crate) fn display_cell(book: &Workbook, row: usize, col: usize) -> String {
    let mut eval = Eval {
        book,
        cache: HashMap::new(),
        visiting: HashSet::new(),
        steps: 0,
        text_bytes: 0,
    };
    eval.cell(book.active_sheet(), row, col, 0).display()
}
