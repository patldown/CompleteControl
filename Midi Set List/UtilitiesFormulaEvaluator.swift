//
//  FormulaEvaluator.swift
//  Midi Set List
//
//  Recursive-descent math expression evaluator used for OSC and MIDI formula values.
//  Operators: + - * / ^ (power, right-associative), unary -, comparison (> >= < <= == !=), ternary (? :)
//  Functions: log log2 log10 exp sqrt abs pow min max floor ceil round clamp sin cos tan
//  Constants in context: pi, e, bpm (song tempo)
//

import Foundation

enum FormulaEvaluator {

    // MARK: - Public context

    struct Context {
        var variables: [String: Double]

        static let empty = Context(variables: [:])

        static func forSong(bpm: Int?) -> Context {
            var v: [String: Double] = ["pi": .pi, "e": M_E]
            v["bpm"] = bpm.map { Double($0) } ?? 0
            return Context(variables: v)
        }
    }

    // MARK: - Public API

    /// Evaluates the formula string with the given context.
    /// Returns nil if the formula is blank or contains a parse/runtime error.
    static func evaluate(_ formula: String, context: Context = .empty) -> Double? {
        let s = formula.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var ctx = context
        // Always inject math constants
        ctx.variables["pi"] = ctx.variables["pi"] ?? .pi
        ctx.variables["e"]  = ctx.variables["e"]  ?? M_E
        var p = Parser(tokens: tokenize(s), ctx: ctx)
        return try? p.expr()
    }

    /// Human-readable description of why a formula is invalid, or nil if valid.
    static func errorDescription(for formula: String, context: Context = .empty) -> String? {
        let s = formula.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var ctx = context
        ctx.variables["pi"] = ctx.variables["pi"] ?? .pi
        ctx.variables["e"]  = ctx.variables["e"]  ?? M_E
        var p = Parser(tokens: tokenize(s), ctx: ctx)
        do {
            _ = try p.expr()
            return nil
        } catch let e as EvalError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Tokenizer

    private enum Tok: Equatable {
        case num(Double), id(String)
        case plus, minus, star, slash, caret, lparen, rparen, comma
        case gt, ge, lt, le, eq, ne       // > >= < <= == !=
        case question, colon              // ? :
        case eof
    }

    private static func tokenize(_ s: String) -> [Tok] {
        var toks: [Tok] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case " ", "\t", "\n": i = s.index(after: i)
            case "+": toks.append(.plus);   i = s.index(after: i)
            case "-": toks.append(.minus);  i = s.index(after: i)
            case "*": toks.append(.star);   i = s.index(after: i)
            case "/": toks.append(.slash);  i = s.index(after: i)
            case "^": toks.append(.caret);  i = s.index(after: i)
            case "(": toks.append(.lparen); i = s.index(after: i)
            case ")": toks.append(.rparen); i = s.index(after: i)
            case ",": toks.append(.comma);  i = s.index(after: i)
            case "?": toks.append(.question); i = s.index(after: i)
            case ":": toks.append(.colon);    i = s.index(after: i)
            case ">":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "=" {
                    toks.append(.ge); i = s.index(after: next)
                } else {
                    toks.append(.gt); i = s.index(after: i)
                }
            case "<":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "=" {
                    toks.append(.le); i = s.index(after: next)
                } else {
                    toks.append(.lt); i = s.index(after: i)
                }
            case "=":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "=" {
                    toks.append(.eq); i = s.index(after: next)
                } else {
                    i = s.index(after: i)  // single = is not valid; skip
                }
            case "!":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "=" {
                    toks.append(.ne); i = s.index(after: next)
                } else {
                    i = s.index(after: i)  // single ! is not valid; skip
                }
            case "0"..."9", ".":
                var ns = ""
                while i < s.endIndex, (s[i].isNumber || s[i] == "." || s[i] == "e" || s[i] == "E") {
                    // Handle scientific notation like 1e-3
                    if (s[i] == "e" || s[i] == "E") {
                        let next = s.index(after: i)
                        if next < s.endIndex, s[next] == "-" || s[next] == "+" {
                            ns.append(s[i]); i = next
                            ns.append(s[i]); i = s.index(after: i)
                            continue
                        }
                    }
                    ns.append(s[i]); i = s.index(after: i)
                }
                if let v = Double(ns) { toks.append(.num(v)) }
            default:
                if c.isLetter || c == "_" {
                    var name = ""
                    while i < s.endIndex, s[i].isLetter || s[i].isNumber || s[i] == "_" {
                        name.append(s[i]); i = s.index(after: i)
                    }
                    toks.append(.id(name))
                } else {
                    i = s.index(after: i)
                }
            }
        }
        toks.append(.eof)
        return toks
    }

    // MARK: - Parser
    //
    // Grammar (highest to lowest precedence):
    //   expr       = ternary
    //   ternary    = comparison ('?' comparison ':' comparison)?
    //   comparison = add ((> | >= | < | <= | == | !=) add)*
    //   add        = term ((+ | -) term)*
    //   term       = power ((* | /) power)*
    //   power      = unary (^ power)?
    //   unary      = (- | +) unary | atom
    //   atom       = number | '(' expr ')' | ident '(' args ')' | ident

    private struct Parser {
        let tokens: [Tok]
        let ctx: Context
        var pos = 0

        var cur: Tok { pos < tokens.count ? tokens[pos] : .eof }
        mutating func eat() { pos += 1 }

        mutating func expr() throws -> Double {
            return try ternary()
        }

        // condition ? trueValue : falseValue  (non-zero condition = true)
        mutating func ternary() throws -> Double {
            let cond = try comparison()
            guard cur == .question else { return cond }
            eat()
            let t = try comparison()
            guard cur == .colon else { throw EvalError("Expected ':' in ternary expression") }
            eat()
            let f = try comparison()
            return cond != 0 ? t : f
        }

        // comparison operators return 1.0 (true) or 0.0 (false)
        mutating func comparison() throws -> Double {
            var v = try add()
            while cur == .gt || cur == .ge || cur == .lt || cur == .le || cur == .eq || cur == .ne {
                let op = cur; eat()
                let r = try add()
                switch op {
                case .gt: v = v > r  ? 1 : 0
                case .ge: v = v >= r ? 1 : 0
                case .lt: v = v < r  ? 1 : 0
                case .le: v = v <= r ? 1 : 0
                case .eq: v = v == r ? 1 : 0
                case .ne: v = v != r ? 1 : 0
                default: break
                }
            }
            return v
        }

        mutating func add() throws -> Double {
            var v = try term()
            while cur == .plus || cur == .minus {
                let op = cur; eat()
                let r = try term()
                v = op == .plus ? v + r : v - r
            }
            return v
        }

        mutating func term() throws -> Double {
            var v = try power()
            while cur == .star || cur == .slash {
                let op = cur; eat()
                let r = try power()
                if op == .slash {
                    guard r != 0 else { throw EvalError("Division by zero") }
                    v = v / r
                } else {
                    v = v * r
                }
            }
            return v
        }

        // power = unary (^ power)?  (right-associative)
        mutating func power() throws -> Double {
            let base = try unary()
            if cur == .caret { eat(); return Foundation.pow(base, try power()) }
            return base
        }

        mutating func unary() throws -> Double {
            if cur == .minus { eat(); return try -unary() }
            if cur == .plus  { eat(); return try  unary() }
            return try atom()
        }

        mutating func atom() throws -> Double {
            switch cur {
            case .num(let v): eat(); return v
            case .lparen:
                eat()
                let v = try expr()
                guard cur == .rparen else { throw EvalError("Missing closing ')'") }
                eat(); return v
            case .id(let name):
                eat()
                if cur == .lparen {
                    eat()
                    var args: [Double] = []
                    if cur != .rparen {
                        args.append(try expr())
                        while cur == .comma { eat(); args.append(try expr()) }
                    }
                    guard cur == .rparen else { throw EvalError("Missing ')' after \(name)") }
                    eat()
                    return try call(name, args: args)
                }
                if let v = ctx.variables[name] { return v }
                throw EvalError("Unknown variable '\(name)' — available: \(ctx.variables.keys.sorted().joined(separator: ", "))")
            default:
                throw EvalError("Unexpected token")
            }
        }

        // MARK: Function dispatch
        func call(_ name: String, args: [Double]) throws -> Double {
            func req(_ n: Int) throws {
                guard args.count == n else { throw EvalError("\(name)() needs \(n) argument\(n==1 ? "" : "s"), got \(args.count)") }
            }
            switch name.lowercased() {
            case "log":    try req(1); return Foundation.log(args[0])
            case "log2":   try req(1); return Foundation.log2(args[0])
            case "log10":  try req(1); return Foundation.log10(args[0])
            case "exp":    try req(1); return Foundation.exp(args[0])
            case "sqrt":   try req(1); return Foundation.sqrt(args[0])
            case "abs":    try req(1); return Swift.abs(args[0])
            case "floor":  try req(1); return Foundation.floor(args[0])
            case "ceil":   try req(1); return Foundation.ceil(args[0])
            case "round":  try req(1); return Foundation.round(args[0])
            case "sin":    try req(1); return Foundation.sin(args[0])
            case "cos":    try req(1); return Foundation.cos(args[0])
            case "tan":    try req(1); return Foundation.tan(args[0])
            case "pow":    try req(2); return Foundation.pow(args[0], args[1])
            case "min":    try req(2); return Swift.min(args[0], args[1])
            case "max":    try req(2); return Swift.max(args[0], args[1])
            case "clamp":
                guard args.count == 3 else { throw EvalError("clamp(x, lo, hi) needs 3 arguments") }
                return Swift.min(Swift.max(args[0], args[1]), args[2])
            // Logarithmic curve helpers
            case "lognorm":
                // lognorm(value, rangeMin, rangeMax) → 0..1 log-normalized
                guard args.count == 3 else { throw EvalError("lognorm(v, min, max) needs 3 arguments") }
                let (v, lo, hi) = (args[0], args[1], args[2])
                guard lo > 0, hi > lo else { throw EvalError("lognorm: min must be > 0 and < max") }
                return Foundation.log(v / lo) / Foundation.log(hi / lo)
            case "logmap":
                // logmap(norm, rangeMin, rangeMax) → value from 0..1 log-mapped
                guard args.count == 3 else { throw EvalError("logmap(norm, min, max) needs 3 arguments") }
                let (n, lo, hi) = (args[0], args[1], args[2])
                guard lo > 0, hi > lo else { throw EvalError("logmap: min must be > 0 and < max") }
                return lo * Foundation.pow(hi / lo, n)
            case "db":
                // db(amplitude) → dB  (20 * log10)
                try req(1); return 20.0 * Foundation.log10(args[0])
            case "ampfromdb":
                // ampFromDB(dB) → linear amplitude
                try req(1); return Foundation.pow(10.0, args[0] / 20.0)
            default:
                throw EvalError("Unknown function '\(name)'")
            }
        }
    }

    // MARK: - Error

    struct EvalError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
