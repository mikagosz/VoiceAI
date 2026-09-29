import Foundation

let vocabulary = Vocabulary.defaults
let cases: [(String, String)] = [
    ("Zapytaj Klaudia o to", "Zapytaj Claude o to"),
    ("klaudia, zrób to", "Claude, zrób to"),
    ("Klaudiana zostaje", "Klaudiana zostaje"),
    ("Pytałem Klaudii wczoraj", "Pytałem Claude wczoraj"),
    ("Klod.", "Claude."),
    ("bez zmian", "bez zmian"),
]
var failed = 0
for (input, expected) in cases {
    let result = vocabulary.apply(to: input)
    if result != expected {
        failed += 1
        print("FAIL: \"\(input)\" → \"\(result)\", expected \"\(expected)\"")
    }
}
let broken = try? JSONDecoder().decode(Vocabulary.self, from: Data("{\"slowa\": [".utf8))
if broken != nil { failed += 1; print("FAIL: broken JSON decoded") }



// Claude's reply: last assistant text after the last user entry, first spoken paragraph.
let transcript = [
    #"{"type":"user","message":{"role":"user","content":"stare pytanie"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Stara odpowiedź."}]}}"#,
    #"{"type":"user","message":{"role":"user","content":"nowe pytanie"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```bash\nls\n```\n\n**Działa**, zobacz [notatkę](https://x.pl) i `plik.swift`.\nDruga linia.\n\nDrugi akapit."}]}}"#,
    #"{"type":"system","subtype":"x"}"#,
].joined(separator: "\n")
let reply = ClaudeHook.lastReply(in: transcript)
let spoken = ClaudeHook.spokenParagraph(from: reply)
var hookCases = 0
if reply.contains("Stara") { failed += 1; print("FAIL: read an older reply") }
hookCases += 1
if spoken != "Działa, zobacz notatkę i plik.swift. Druga linia. Resztę masz na ekranie." { failed += 1; print("FAIL: spoken \"\(spoken)\"") }
hookCases += 1
if ClaudeHook.spokenParagraph(from: "- **Punkt** pierwszy\n\ntekst") != "Punkt pierwszy Resztę masz na ekranie." { failed += 1; print("FAIL: list marker") }
hookCases += 1
let short = ClaudeHook.spokenParagraph(from: "Wersja 0.1.8 działa, np. tak. Koniec.")
if short != "Wersja 0.1.8 działa, np. tak. Koniec." { failed += 1; print("FAIL: short reply \"\(short)\"") }
hookCases += 1
let long = ClaudeHook.spokenParagraph(from: "Pierwsze. Drugie! Trzecie? Czwarte.")
if long != "Pierwsze. Drugie! Resztę masz na ekranie." { failed += 1; print("FAIL: long reply \"\(long)\"") }
hookCases += 1


// Whisper mode boost: quiet goes up to the target, loud stays, peaks clip at ±1.
func loudness(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot() }
var boostCases = 0
let quietVoice = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
if abs(loudness(Recorder.boosted(quietVoice, to: 0.05)) - 0.05) > 0.002 { failed += 1; print("FAIL: quiet not lifted to 0.05") }
boostCases += 1
let loudVoice = (0..<16_000).map { _ in Float.random(in: -0.3...0.3) }
if Recorder.boosted(loudVoice, to: 0.05) != loudVoice { failed += 1; print("FAIL: loud recording changed") }
boostCases += 1
if (Recorder.boosted([0.001, -0.001, 0.5], to: 0.05).map(abs).max() ?? 0) > 1 { failed += 1; print("FAIL: sample above 1") }
boostCases += 1


// Space between dictations: "…klawisz." + "Testy" must not glue together.
let spacing: [(Character?, String, Bool)] = [
    (".", "Testy", true), ("a", "dalej", true), (" ", "Testy", false), ("\n", "Testy", false),
    (nil, "Testy", false), ("(", "nawias", false), ("a", ", i dalej", false), ("„", "cytat", false),
]
for (previous, text, expected) in spacing where Paster.needsSpace(after: previous, text: text) != expected {
    failed += 1; print("FAIL: space after \(String(describing: previous)) before \"\(text)\" should be \(expected)")
}




// Wrong alphabet: Polish in Cyrillic is caught, Polish letters and a Russian word list are not.
if !Language.wrongScript("По актуальней можно алить только в жидко", language: "pl") { failed += 1; print("FAIL: Cyrillic in Polish not caught") }
if Language.wrongScript("Zażółć gęślą jaźń, 3 × 5 = 15 — „cytat”.", language: "pl") { failed += 1; print("FAIL: Polish letters taken as wrong alphabet") }
if Language.wrongScript("Привет", language: "ru") { failed += 1; print("FAIL: Russian word list flagged") }
let scriptCases = 3

// Journal: saved and read back, a broken file is never overwritten, Markdown export.
var journalCases = 0
let journalDir = FileManager.default.temporaryDirectory.appending(path: "voiceai-journal-\(UUID().uuidString)")
var dayParts = DateComponents(); dayParts.year = 2026; dayParts.month = 9; dayParts.day = 29; dayParts.hour = 11; dayParts.minute = 40
let entryDate = Calendar.current.date(from: dayParts)!
let first = Journal(directory: journalDir)
try? first.add("Pierwszy wpis", at: entryDate)
try? first.add("Drugi wpis", at: entryDate.addingTimeInterval(120))
if Journal(directory: journalDir).entries.map(\.text) != ["Pierwszy wpis", "Drugi wpis"] { failed += 1; print("FAIL: journal not read back") }
journalCases += 1
let exported = Journal.markdown(first.entries, locale: Locale(identifier: "pl_PL"))
if exported != "## wtorek, 29 września 2026\n\n- **11:40** Pierwszy wpis\n- **11:42** Drugi wpis\n" { failed += 1; print("FAIL: export\n\(exported)") }
journalCases += 1
if Journal.plainText(first.entries.reversed()) != "Pierwszy wpis\n\nDrugi wpis" { failed += 1; print("FAIL: plain text of chosen entries") }
journalCases += 1
try? "{ zepsute".write(to: journalDir.appending(path: "dziennik.json"), atomically: true, encoding: .utf8)
let brokenJournal = Journal(directory: journalDir)
if (try? brokenJournal.add("nie wolno")) != nil { failed += 1; print("FAIL: wrote over a broken journal") }
if (try? String(contentsOf: journalDir.appending(path: "dziennik.json"), encoding: .utf8)) != "{ zepsute" { failed += 1; print("FAIL: broken journal changed") }
journalCases += 1
// Removing from a journal broken after it was read must not write the old entries over it.
let removeDir = FileManager.default.temporaryDirectory.appending(path: "voiceai-journal-\(UUID().uuidString)")
let removing = Journal(directory: removeDir)
try? removing.add("Zostaje", at: entryDate)
try? "{ popsute".write(to: removing.file, atomically: true, encoding: .utf8)
if (try? removing.remove([removing.entries[0].id])) != nil { failed += 1; print("FAIL: removed from a broken journal") }
if (try? String(contentsOf: removing.file, encoding: .utf8)) != "{ popsute" { failed += 1; print("FAIL: broken journal overwritten by remove") }
journalCases += 1
// An edit made outside the app survives the next dictation into the journal.
try? FileManager.default.removeItem(at: removing.file)
let outside = Journal(directory: removeDir)
try? outside.add("Pierwszy", at: entryDate)
let other = Journal(directory: removeDir)
try? other.add("Z drugiej kopii", at: entryDate)
try? outside.add("Trzeci", at: entryDate)
if Journal(directory: removeDir).entries.map(\.text) != ["Pierwszy", "Z drugiej kopii", "Trzeci"] { failed += 1; print("FAIL: journal lost an outside edit") }
journalCases += 1
try? FileManager.default.removeItem(at: removeDir)
try? FileManager.default.removeItem(at: journalDir)


// Word counter: Polish plurals, words only, a week from Monday.
let plurals: [(Int, String)] = [(1, "1 słowo"), (2, "2 słowa"), (5, "5 słów"), (12, "12 słów"), (22, "22 słowa"), (0, "0 słów"), (114, "114 słów")]
for (count, expected) in plurals where Stats.wordsLabel(count, polish: true) != expected {
    failed += 1; print("FAIL: plural \(count) → \(Stats.wordsLabel(count, polish: true))")
}
var statsCases = plurals.count
if Stats.words(in: "Test, test — raz dwa 3 .") != 4 { failed += 1; print("FAIL: word count \(Stats.words(in: "Test, test — raz dwa 3 ."))") }
statsCases += 1
// A path, not a name: the preferences file lands in the temporary folder instead of
// ~/Library/Preferences, where every run used to leave one behind (23 files by 2026-09-29).
let suiteName = FileManager.default.temporaryDirectory.appending(path: "voiceai-check-\(UUID().uuidString)").path
let suite = UserDefaults(suiteName: suiteName)!
let counter = Stats(defaults: suite)
var weekParts = DateComponents(); weekParts.year = 2026; weekParts.month = 9; weekParts.day = 28; weekParts.hour = 12
let monday = Calendar.current.date(from: weekParts)!
counter.record("jeden dwa trzy", seconds: 2, at: monday.addingTimeInterval(-86_400))   // Sunday, last week
counter.record("cztery pięć", seconds: 1, at: monday)
counter.record("sześć siedem osiem", seconds: 2, at: monday.addingTimeInterval(86_400))
if counter.day(monday.addingTimeInterval(86_400)).words != 3 || counter.week(monday.addingTimeInterval(86_400)).words != 5 {
    failed += 1; print("FAIL: week \(counter.week(monday.addingTimeInterval(86_400)))")
}
statsCases += 1
if Stats.summary(Stats.Day(words: 400, seconds: 180), polish: true) != "400 słów · ~7 min zaoszczędzone" {
    failed += 1; print("FAIL: summary \(Stats.summary(Stats.Day(words: 400, seconds: 180)))")
}
statsCases += 1
// English interface: plain plurals, "saved", dates in English; the spoken ending follows the speech language.
if Stats.summary(Stats.Day(words: 400, seconds: 180), polish: false) != "400 words · ~7 min saved" || Stats.wordsLabel(1, polish: false) != "1 word" {
    failed += 1; print("FAIL: English summary \(Stats.summary(Stats.Day(words: 400, seconds: 180), polish: false))")
}
statsCases += 1
if !Journal.markdown(first.entries, locale: Locale(identifier: "en")).hasPrefix("## Tuesday, September 29, 2026\n\n- **11:40** Pierwszy") {
    failed += 1; print("FAIL: English journal \(Journal.markdown(first.entries, locale: Locale(identifier: "en")))")
}
statsCases += 1
if ClaudeHook.spokenParagraph(from: "Pierwsze. Drugie! Trzecie.", rest: ClaudeHook.restOnScreen(for: "en")) != "Pierwsze. Drugie! The rest is on screen." {
    failed += 1; print("FAIL: English ending")
}
statsCases += 1


// Per-app rules: no full stop in Claude, capital letter in Mail, own replacements, old files.
var appCases = 0
let claudeApp = "com.anthropic.claudefordesktop"
let appChecks: [(String?, String, String)] = [
    (claudeApp, "zrób commit.", "zrób commit"),
    (claudeApp, "czy działa?", "czy działa?"),
    (claudeApp, "no i…", "no i…"),
    ("com.apple.mail", "dzień dobry.", "Dzień dobry."),
    ("com.example.unknown", "bez zmian.", "bez zmian."),
    (nil, "Klaudia pisze.", "Claude pisze."),
]
var spaced = Vocabulary.defaults
spaced.aplikacje = ["a.b": AppRule(nazwa: "A", kropka: false, spacja: true)]
if spaced.finish("Zdanie.", for: "a.b") != "Zdanie " || spaced.finish("Zdanie ", for: "a.b") != "Zdanie " {
    failed += 1; print("FAIL: trailing space \"\(spaced.finish("Zdanie.", for: "a.b"))\"")
}
appCases += 1
for (app, raw, expected) in appChecks where Vocabulary.defaults.finish(raw, for: app) != expected {
    failed += 1; print("FAIL: \(app ?? "nil") \"\(raw)\" → \"\(Vocabulary.defaults.finish(raw, for: app))\"")
}
appCases += appChecks.count
let oldFile = #"{"jezyk":"pl","slowa":[],"zamiany":{"a":"b"},"aplikacje":{"x.y":{"nazwa":"X","zamiany":{"kot":"pies"}}}}"#
let decoded = try? JSONDecoder().decode(Vocabulary.self, from: Data(oldFile.utf8))
if decoded?.finish("kot a.", for: "x.y") != "pies b." { failed += 1; print("FAIL: partial app rule \(String(describing: decoded))") }
appCases += 1
let beforeApps = try? JSONDecoder().decode(Vocabulary.self, from: Data(#"{"jezyk":"pl","slowa":["X"],"zamiany":{}}"#.utf8))
if beforeApps?.appRules[claudeApp]?.kropka != false { failed += 1; print("FAIL: file without apps lost defaults") }
appCases += 1
let vocabDir = FileManager.default.temporaryDirectory.appending(path: "voiceai-vocab-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: vocabDir, withIntermediateDirectories: true)
try? #"{"jezyk":"pl","slowa":["Własne"],"zamiany":{"foo":"bar"}}"#.write(to: vocabDir.appending(path: "slownik.json"), atomically: true, encoding: .utf8)
let store = VocabularyStore(directory: vocabDir)
store.updateApps { $0["com.apple.mail"]?.kropka = false }
let saved = VocabularyStore(directory: vocabDir); saved.reload()
if saved.current.slowa != ["Własne"] || saved.current.zamiany != ["foo": "bar"] || saved.current.appRules["com.apple.mail"]?.kropka != false
    || saved.current.appRules[claudeApp] == nil {
    failed += 1; print("FAIL: options change lost something \(saved.current)")
}
appCases += 1
try? FileManager.default.removeItem(at: vocabDir)

// Files: subtitles, Whisper's tokens and file names that never overwrite.
var fileCases = 0
let fileTranscript = FileTranscript(lines: [.init(start: 0, end: 2.5, text: "Pierwsze."), .init(start: 3661.2, end: 3662.0004, text: "Drugie.")])
if fileTranscript.srt != "1\n00:00:00,000 --> 00:00:02,500\nPierwsze.\n\n2\n01:01:01,200 --> 01:01:02,000\nDrugie.\n" {
    failed += 1; print("FAIL: srt \(fileTranscript.srt.debugDescription)")
}
fileCases += 1
if fileTranscript.text != "Pierwsze. Drugie." { failed += 1; print("FAIL: file text") }
fileCases += 1
if FileTranscript.clean("<|startoftranscript|><|pl|><|0.00|> Dzień dobry.<|2.40|>") != "Dzień dobry." { failed += 1; print("FAIL: token clean") }
fileCases += 1
// Subtitles from word timings: sentence ends and pauses split, long text wraps into two lines.
func words(_ text: String, from start: Double, step: Double = 0.3) -> [FileTranscript.Word] {
    text.split(separator: " ").enumerated().map { i, w in .init(text: " " + w, start: start + Double(i) * step, end: start + Double(i) * step + 0.25) }
}
let filmWords = words("I don't like this. We're going against every protocol and guideline that you yourself have insisted on every single time", from: 1)
    + words("Why?", from: 12)
let subs = FileTranscript.cues(from: filmWords) { $0.replacingOccurrences(of: "protocol", with: "PROTOCOL") }
if subs.map(\.text) != ["I don't like this.", "We're going against every PROTOCOL and\nguideline that you yourself have insisted", "on every single time", "Why?"] {
    failed += 1; print("FAIL: cues \(subs.map(\.text))")
}
fileCases += 1
if subs[0].start != 1 || abs(subs[0].end - 2.15) > 0.001 || subs[3].start != 12 || abs(subs[3].end - 12.8) > 0.001 {
    failed += 1; print("FAIL: cue times \(subs.map { ($0.start, $0.end) })")
}
fileCases += 1
if subs.contains(where: { $0.text.split(separator: "\n").contains { $0.count > FileTranscript.maxLine } || $0.end - $0.start > FileTranscript.maxDuration }) {
    failed += 1; print("FAIL: cue too long")
}
fileCases += 1
let fileDir = FileManager.default.temporaryDirectory.appending(path: "voiceai-file-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
let source = fileDir.appending(path: "Wywiad.mp4")
if FileTranscript.freeName(for: source, extensions: ["txt", "srt"]).lastPathComponent != "Wywiad" { failed += 1; print("FAIL: first name") }
fileCases += 1
try? fileTranscript.write(nextTo: source)
try? fileTranscript.write(nextTo: source)
let written = (try? FileManager.default.contentsOfDirectory(atPath: fileDir.path).sorted()) ?? []
if written != ["Wywiad 2.srt", "Wywiad 2.txt", "Wywiad.srt", "Wywiad.txt"] { failed += 1; print("FAIL: no overwrite \(written)") }
fileCases += 1
// Only the subtitles are taken: the text must not keep the bare name while the subtitles get "2".
try? FileManager.default.removeItem(at: fileDir.appending(path: "Wywiad.txt"))
try? FileManager.default.removeItem(at: fileDir.appending(path: "Wywiad 2.txt"))
try? FileManager.default.removeItem(at: fileDir.appending(path: "Wywiad 2.srt"))
try? fileTranscript.write(nextTo: source)
let paired = (try? FileManager.default.contentsOfDirectory(atPath: fileDir.path).sorted()) ?? []
if paired != ["Wywiad 2.srt", "Wywiad 2.txt", "Wywiad.srt"] { failed += 1; print("FAIL: txt and srt not paired \(paired)") }
fileCases += 1
try? FileManager.default.removeItem(at: fileDir)
// A long recording is cut in its pause, not in the middle of loud sound.
var loudWithPause = [Float](repeating: 0.5, count: 1000)
for i in 700..<760 { loudWithPause[i] = 0.001 }
let cut = FileTranscript.quietestCut(in: loudWithPause, searchLast: 500, window: 40)
if !(700...720).contains(cut) { failed += 1; print("FAIL: cut at \(cut), not in the pause") }
fileCases += 1

print(failed == 0 ? "OK — \(cases.count + 1 + hookCases + boostCases + spacing.count + journalCases + statsCases + appCases + fileCases + scriptCases) cases" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
