#!/usr/bin/env bash
# Runs WordDiff's alignment against a set of assertions using the macOS Swift
# toolchain — no simulator, no test target.
#
#   ./transcriber/Tools/verify-worddiff.sh
#
# WordDiff is pure Foundation, so it can be compiled standalone; this script
# concatenates it with the `wordTokens` helper it depends on and the cases below.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${HERE}/../transcriber"
OUT="$(mktemp -d)/DiffTest.swift"

{
  echo 'import Foundation'
  sed -n '/^nonisolated extension String {/,/^}/p' "${APP}/Services/TranscriptionService.swift"
  sed -n '/^nonisolated enum WordDiff {/,$p' "${APP}/Utils/WordDiff.swift"
  cat <<'SWIFT'

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1 }
    print(condition ? "PASS \(label)" : "FAIL \(label)")
}

let same = WordDiff.align(transcripts: ["the quick brown fox", "the quick brown fox", "the quick brown fox"])
check(same.count == 4 && same.allSatisfy(\.agrees), "identical: 4 agreeing columns, got \(same.count)")
check(WordDiff.agreementRate(same) == 1.0, "identical: rate 1.0")

let punct = WordDiff.align(transcripts: ["Hello, world.", "hello world"])
check(punct.count == 2 && punct.allSatisfy(\.agrees), "punctuation/case ignored")

// A substitution must be one row, not a delete row plus an insert row.
let sub = WordDiff.align(transcripts: ["the quick brown fox", "the quick green fox"])
check(sub.count == 4, "substitution: 4 columns, got \(sub.count)")
check(sub.filter { !$0.agrees }.map(\.tokens) == [["brown", "green"]], "substitution: one row, got \(sub.filter { !$0.agrees }.map(\.tokens))")

let three = WordDiff.align(transcripts: ["ship it on friday", "ship it on tuesday", "ship it on friday"])
check(three.count == 4, "3-way: 4 columns, got \(three.count)")
check(three.filter { !$0.agrees }.map(\.tokens) == [["friday", "tuesday", "friday"]], "3-way: one substitution row, got \(three.filter { !$0.agrees }.map(\.tokens))")
check(three.allSatisfy { $0.tokens.count == 3 }, "3-way: 3 slots per column")
check(three.map(\.id) == Array(0..<three.count), "ids contiguous")

// Deletions still surface as a gap.
let del = WordDiff.align(transcripts: ["the quick brown fox", "the brown fox"])
check(del.count == 4, "deletion: 4 columns, got \(del.count)")
check(del.filter { !$0.agrees }.map(\.tokens) == [["quick", nil]], "deletion: gap row, got \(del.filter { !$0.agrees }.map(\.tokens))")

let ins = WordDiff.align(transcripts: ["brown fox", "the brown fox"])
check(ins.count == 3 && ins[0].tokens == [nil, "the"], "head insertion, got \(ins.map(\.tokens))")

// A multi-word difference stays readable: rows pair up in order.
let phrase = WordDiff.align(transcripts: ["we should ship the thing", "we shall shrink the thing"])
check(phrase.filter { !$0.agrees }.map(\.tokens) == [["should", "shall"], ["ship", "shrink"]], "multi-word run, got \(phrase.filter { !$0.agrees }.map(\.tokens))")

let uneven = WordDiff.align(transcripts: ["a cat sat", "a big cat sat"])
check(uneven.filter { !$0.agrees }.map(\.tokens) == [[nil, "big"]], "uneven run, got \(uneven.filter { !$0.agrees }.map(\.tokens))")

check(WordDiff.align(transcripts: ["", "hello"]).count == 1, "empty source")
check(WordDiff.agreementRate([]) == 0, "empty columns rate")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
if failures > 0 { exit(1) }
SWIFT
} > "${OUT}"

swift "${OUT}"
