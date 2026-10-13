import Foundation

/// What the Help window says: each section is a picture of the app with numbered points and the same
/// numbers in the steps next to it. Polish source like the rest of VoiceAI; the English text is in
/// Localizable.xcstrings (Tests/main.swift checks that every string has its translation).
enum HelpContent {
    /// Which picture stands next to the section; drawn by the app itself in HelpWindow.swift.
    enum Picture { case dictate, icon, menu, settings, vocabulary, journal, files, replies, model }

    struct Section {
        let title: String
        let lead: String
        /// Numbered like the points on the picture: the first step is point 1.
        let steps: [String]
        /// The longer description, folded under "Więcej".
        let more: String?
        let picture: Picture
    }

    struct Card {
        let symbol: String
        let title: String
        let text: String
    }

    static let title = "Pierwsze kroki z VoiceAI"
    static let intro = "Trzymasz klawisz, mówisz, puszczasz — tekst pojawia się tam, gdzie stoi kursor. Mowę rozpoznaje Whisper na tym Macu, bez internetu."

    static let sections: [Section] = [
        Section(title: "Trzymaj klawisz i mów",
                lead: "Dyktujesz do każdego programu: do maila, notatki, czatu czy Terminala.",
                steps: ["Kliknij tam, gdzie ma się pojawić tekst.",
                        "Trzymaj prawy ⌥. Pasek na dole ekranu pokazuje, do którego programu i okna trafi tekst.",
                        "Mów — fala idzie za Twoim głosem. Puść klawisz, a po chwili tekst stoi w miejscu kursora."],
                more: "Inny klawisz wciśnięty w trakcie (np. ⌥A dla „ą”) anuluje nagranie, więc zwykłe pisanie nigdy nie zaczyna dyktowania. Przy pierwszym uruchomieniu VoiceAI pobiera model Whisper (ok. 1,5 GB) i prosi o dwie zgody: Mikrofon i Dostępność — bez Dostępności nie usłyszy klawisza i nie wklei tekstu. Ze słuchawkami Bluetooth odczekaj pół sekundy po wciśnięciu klawisza, zanim zaczniesz mówić: słuchawki potrzebują chwili, żeby włączyć mikrofon.",
                picture: .dictate),
        Section(title: "Ikona w pasku menu",
                lead: "Fala w pasku menu mówi, co właśnie robi VoiceAI.",
                steps: ["Spokojna fala — gotowy, możesz dyktować.",
                        "Kolorowa i ruchoma — nagrywa i idzie za Twoim głosem.",
                        "Granatowe tło — włączony tryb szeptu.",
                        "Przygaszona — nie ma mikrofonu."],
                more: "Gdy Whisper rozpoznaje mowę, przez falę przebiega jaśniejsza fala. Wygląd ikony — małe kółko albo szeroka pastylka — zmienisz w Ustawieniach.",
                picture: .icon),
        Section(title: "Menu VoiceAI",
                lead: "Kliknij ikonę: stan, ostatnie dyktowania i wszystkie polecenia są w jednym miejscu.",
                steps: ["Stan i to, ile dziś podyktowałeś — z czasem zaoszczędzonym na pisaniu.",
                        "Ostatnie dyktowania. Kliknięcie kopiuje tekst.",
                        "Pliki, słownik, tryb szeptu i czytanie odpowiedzi.",
                        "Dziennik, Ustawienia i ta Pomoc."],
                more: "Czas zaoszczędzony liczony jest wobec pisania 40 słów na minutę, minus czas mówienia.",
                picture: .menu),
        Section(title: "Ustawienia dyktowania",
                lead: "W menu wybierz Ustawienia… — zmiany działają od razu, bez zapisywania.",
                steps: ["Mikrofon, z którego nagrywa VoiceAI. Zmień… otwiera Dźwięk w Ustawieniach systemowych.",
                        "Klawisz dyktowania: prawy albo lewy ⌥, prawy ⌘, ⌃, ⇧ lub fn.",
                        "Język, w którym mówisz.",
                        "Tryb szeptu — gdy obok ktoś śpi."],
                more: "W trybie szeptu VoiceAI łapie dużo cichszy głos i podgłaśnia nagranie, zanim odda je Whisperowi. Pasek z poziomem głosu można wyłączyć — wtedy zostaje sama ikona w pasku menu.",
                picture: .settings),
        Section(title: "Słownik",
                lead: "Naucz VoiceAI nazw, których Whisper nie zna, i popraw to, co wciąż przekręca.",
                steps: ["słowa — podpowiedź pisowni: nazwy, marki, skróty.",
                        "zamiany — co Whisper rozpoznał źle i co ma stać zamiast tego.",
                        "aplikacje — kropka na końcu, wielka litera i spacja osobno dla każdego programu."],
                more: "Menu → Edytuj słownik… otwiera plik slownik.json w TextEdit. VoiceAI czyta go przed każdym dyktowaniem, więc zmiana działa od razu. Pliku z błędem VoiceAI nie nadpisze — do czasu poprawki działa poprzednia wersja. Reguły aplikacji ustawisz też w Ustawieniach, w sekcji Aplikacje.",
                picture: .vocabulary),
        Section(title: "Dziennik",
                lead: "Dyktujesz, a nie ma gdzie pisać — na biurku albo w Finderze? Tekst trafia do dziennika i nic nie ginie.",
                steps: ["Wpisy pogrupowane według dni.",
                        "Każdy wpis z godziną. Zaznacz kilka i naciśnij ⌘C, żeby skopiować tylko je.",
                        "Kopiuj wszystko albo Eksportuj… — jako Markdown, np. do Obsidiana."],
                more: "Dziennik otworzysz z menu (Dziennik…). Tekst może też trafić na biurko jako plik — to ustawienie „Gdy nie ma pola tekstowego” w Ustawieniach.",
                picture: .journal),
        Section(title: "Pliki audio i wideo",
                lead: "Nagranie rozmowy albo film zamienisz w tekst i napisy.",
                steps: ["Menu → Przepisz plik audio lub wideo… albo upuść pliki na ikonę VoiceAI.",
                        "Tekst (.txt) i napisy (.srt) pojawiają się obok pliku i niczego nie nadpisują."],
                more: "Kilka plików VoiceAI przepisuje po kolei, a postęp widać w menu. Długie nagrania czyta po dziesięć minut naraz. Dyktowanie czeka, aż plik się skończy.",
                picture: .files),
        Section(title: "Odpowiedzi Claude'a na głos",
                lead: "Gdy pracujesz z Claude Code, VoiceAI może czytać na głos początek każdej odpowiedzi.",
                steps: ["Czytaj odpowiedzi na głos — włącza i wyłącza czytanie.",
                        "Głos: każdy zainstalowany głos systemowy w języku mowy.",
                        "Tempo, wysokość tonu i głośność. Posłuchaj odtwarza próbkę."],
                more: "Odpowiedzi przekazuje hook Stop w ~/.claude/settings.json — gotowe polecenie jest w README programu. VoiceAI czyta dwa pierwsze zdania; wciśnięcie klawisza dyktowania przerywa czytanie. Lepsze głosy pobierzesz w Ustawieniach systemowych → Dostępność → Czytaj i mów.",
                picture: .replies),
        Section(title: "Porządkowanie i tłumaczenie",
                lead: "Opcjonalny model językowy, też na tym Macu: porządkuje tekst albo tłumaczy dyktowanie na inny język.",
                steps: ["Pobierz — model pobiera się dopiero na Twoje żądanie.",
                        "Tłumacz dyktowanie na: mówisz po polsku, tekst ląduje np. po angielsku.",
                        "Porządkuj tekst: bez „yyy” i powtórzeń, z interpunkcją."],
                more: "Model zajmuje ok. 2,7 GB i zwalnia pamięć po 10 minutach bez użycia. Porządkowanie czasem zmienia sens zdania, dlatego jest domyślnie wyłączone. Dodaj własny model… przyjmuje dowolny model MLX z Hugging Face albo folder z dysku.",
                picture: .model),
    ]

    static let goodToKnow = "Dobrze wiedzieć"
    static let cards: [Card] = [
        Card(symbol: "lock.shield", title: "Wszystko zostaje na tym Macu",
             text: "To, co mówisz, nie wychodzi z komputera. Do internetu VoiceAI łączy się tylko po modele i po numer nowej wersji."),
        Card(symbol: "arrow.triangle.2.circlepath", title: "Aktualizacje",
             text: "Raz w miesiącu VoiceAI sprawdza, czy jest nowa wersja. Instaluje ją dopiero, gdy klikniesz „Zainstaluj”."),
        Card(symbol: "globe", title: "Język",
             text: "VoiceAI mówi po polsku i angielsku. Język programu i język mowy ustawiasz w Ustawieniach osobno."),
        Card(symbol: "trash", title: "Odinstalowanie",
             text: "Ustawienia → Odinstaluj VoiceAI… przenosi do Kosza program, modele, słownik i dziennik — zaznaczasz, co usunąć."),
    ]

    // Texts of the pictures, made up for Help: none of them comes from this Mac.
    static let sampleApp = "Notatki"
    static let sampleWindow = "Lista zakupów"
    static let sampleNote = "Kup mleko, chleb i kawę. Zadzwoń do serwisu w sprawie roweru."
    static let sampleHistory = ["Kup mleko, chleb i kawę.", "Spotkanie przesuwamy na czwartek, godzina dziesiąta.",
                                "Dzięki, wszystko działa."]
    static let sampleJournal = ["Pomysł na weekend: rower nad jezioro.", "Zadzwonić do mamy przed piątkiem.",
                                "Kupić baterie do pilota.", "Lista na jutro: poczta, apteka, piekarnia."]
    static let sampleFile = "Wywiad"
    static let sampleWords = ["VoiceAI", "Whisper", "Obsidian", "Fractal 8"]
    static let sampleSwaps = ["Łisper": "Whisper", "obsydian": "Obsidian"]

    static let more = "Więcej"
    static let less = "Mniej"
    /// The line under the Fractal 8 Dev signature — the same as under the title on fractal8.eu.
    static let signatureLine = "Natywne programy dla macOS, budowane według jednego wzoru."

    /// Every string of the window, for the translation check.
    static var allStrings: [String] {
        var all = [title, intro, goodToKnow, more, less, signatureLine, sampleApp, sampleWindow, sampleNote, sampleFile]
        all += sampleHistory + sampleJournal
        for s in sections { all += [s.title, s.lead] + s.steps + (s.more.map { [$0] } ?? []) }
        for c in cards { all += [c.title, c.text] }
        return all
    }
}
