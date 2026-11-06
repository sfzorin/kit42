//! Small, bounded spreadsheet expression evaluator. Raw cells remain authoritative.
use crate::Workbook;

const MAX_DEPTH: usize = 128;
const MAX_STEPS: usize = 1_000_000;
const MAX_FORMULA: usize = 4096;

#[derive(Clone, Copy, Debug)]
enum Value {
    Number(f64),
    Error(&'static str),
}
impl Value {
    fn display(self) -> String {
        match self {
            Self::Number(0.0) => "0".into(),
            Self::Number(n) => n.to_string(),
            Self::Error(e) => e.into(),
        }
    }
}
struct Eval<'a> {
    book: &'a Workbook,
    cache: Vec<Option<Value>>,
    visiting: Vec<bool>,
    steps: usize,
}
impl Eval<'_> {
    // Range arguments ignore blank and plain text cells, but retain numeric
    // zero and evaluate formulas so their errors propagate.
    fn range_cell(&mut self, row: usize, col: usize, depth: usize) -> Option<Value> {
        let raw = self.book.cell(row, col).unwrap();
        if !raw.starts_with('=') {
            let trimmed = raw.trim();
            if trimmed.is_empty() || !trimmed.parse::<f64>().is_ok_and(f64::is_finite) {
                return None;
            }
        }
        Some(self.cell(row, col, depth))
    }
    fn cell(&mut self, row: usize, col: usize, depth: usize) -> Value {
        if row >= self.book.rows() || col >= self.book.cols() {
            return Value::Error("#REF!");
        }
        let i = row * self.book.cols() + col;
        if let Some(v) = self.cache[i] {
            return v;
        }
        if self.visiting[i] {
            return Value::Error("#CYCLE!");
        }
        if depth > MAX_DEPTH || self.steps >= MAX_STEPS {
            return Value::Error("#LIMIT!");
        }
        self.steps += 1;
        self.visiting[i] = true;
        let raw = self.book.cell(row, col).unwrap();
        let v = if let Some(expr) = raw.strip_prefix('=') {
            if expr.len() > MAX_FORMULA {
                Value::Error("#LIMIT!")
            } else {
                let mut p = Parser {
                    input: expr.as_bytes(),
                    pos: 0,
                    eval: self,
                    depth,
                };
                let result = p.expr();
                p.space();
                if p.pos != p.input.len() && matches!(result, Value::Number(_)) {
                    Value::Error("#ERROR!")
                } else {
                    result
                }
            }
        } else if raw.trim().is_empty() {
            Value::Number(0.0)
        } else {
            match raw.trim().parse::<f64>() {
                Ok(n) if n.is_finite() => Value::Number(n),
                _ => Value::Error("#VALUE!"),
            }
        };
        self.visiting[i] = false;
        self.cache[i] = Some(v);
        v
    }
}
struct Parser<'a, 'b> {
    input: &'a [u8],
    pos: usize,
    eval: &'a mut Eval<'b>,
    depth: usize,
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
    fn expr(&mut self) -> Value {
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
                e => e,
            }
        } else {
            self.primary()
        }
    }
    fn primary(&mut self) -> Value {
        self.space();
        if self.take(b'(') {
            self.depth += 1;
            let v = self.expr();
            self.depth -= 1;
            return if self.take(b')') {
                v
            } else {
                Value::Error("#ERROR!")
            };
        }
        let start = self.pos;
        if self
            .input
            .get(self.pos)
            .is_some_and(u8::is_ascii_alphabetic)
        {
            while self
                .input
                .get(self.pos)
                .is_some_and(u8::is_ascii_alphabetic)
            {
                self.pos += 1;
            }
            let letters_end = self.pos;
            while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
                self.pos += 1;
            }
            if self.pos > letters_end {
                return match reference(&self.input[start..self.pos]) {
                    Some((r, c)) => self.eval.cell(r, c, self.depth + 1),
                    None => Value::Error("#REF!"),
                };
            }
            let name = std::str::from_utf8(&self.input[start..letters_end])
                .unwrap_or("")
                .to_ascii_uppercase();
            if !matches!(name.as_str(), "SUM" | "AVERAGE" | "MIN" | "MAX") || !self.take(b'(') {
                return Value::Error("#ERROR!");
            }
            let Some(a) = self.read_ref() else {
                return Value::Error("#ERROR!");
            };
            if !self.take(b':') {
                return Value::Error("#ERROR!");
            }
            let Some(b) = self.read_ref() else {
                return Value::Error("#ERROR!");
            };
            if !self.take(b')') {
                return Value::Error("#ERROR!");
            }
            if a.0 > b.0
                || a.1 > b.1
                || b.0 >= self.eval.book.rows()
                || b.1 >= self.eval.book.cols()
            {
                return Value::Error("#REF!");
            }
            let mut acc = if name == "MIN" {
                f64::INFINITY
            } else if name == "MAX" {
                f64::NEG_INFINITY
            } else {
                0.0
            };
            let mut count = 0usize;
            for row in a.0..=b.0 {
                for col in a.1..=b.1 {
                    // A range traversal consumes budget even for cached cells.
                    self.eval.steps += 1;
                    if self.eval.steps > MAX_STEPS {
                        return Value::Error("#LIMIT!");
                    }
                    match self.eval.range_cell(row, col, self.depth + 1) {
                        Some(Value::Number(n)) => {
                            acc = match name.as_str() {
                                "MIN" => acc.min(n),
                                "MAX" => acc.max(n),
                                _ => acc + n,
                            };
                            count += 1;
                        }
                        Some(e) => return e,
                        None => {}
                    }
                }
            }
            if count == 0 {
                return if name == "AVERAGE" {
                    Value::Error("#DIV/0!")
                } else {
                    Value::Number(0.0)
                };
            }
            if name == "AVERAGE" {
                acc /= count as f64;
            }
            return finite(acc);
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
    fn read_ref(&mut self) -> Option<(usize, usize)> {
        self.space();
        let start = self.pos;
        while self
            .input
            .get(self.pos)
            .is_some_and(u8::is_ascii_alphabetic)
        {
            self.pos += 1;
        }
        while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
            self.pos += 1;
        }
        reference(&self.input[start..self.pos])
    }
}
fn reference(s: &[u8]) -> Option<(usize, usize)> {
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
            b'/' if b == 0.0 => Value::Error("#DIV/0!"),
            b'/' => finite(a / b),
            _ => Value::Error("#ERROR!"),
        },
    }
}

pub(crate) fn display_grid(book: &Workbook) -> Vec<Vec<String>> {
    let mut eval = Eval {
        book,
        cache: vec![None; book.rows() * book.cols()],
        visiting: vec![false; book.rows() * book.cols()],
        steps: 0,
    };
    (0..book.rows())
        .map(|r| {
            (0..book.cols())
                .map(|c| {
                    let raw = book.cell(r, c).unwrap();
                    if raw.starts_with('=') {
                        eval.cell(r, c, 0).display()
                    } else {
                        raw.to_owned()
                    }
                })
                .collect()
        })
        .collect()
}
