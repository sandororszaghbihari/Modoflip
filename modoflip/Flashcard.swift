//
//  Flashcard.swift
//  ModoFlip
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - MODEL

struct Flashcard: Identifiable, Hashable, Codable {
    let id: UUID
    var lesson: String
    var question: String
    var answer: String

    // tanulási adatok
    var timesShown: Int = 0
    var timesGood: Int = 0
    var timesGreat: Int = 0
    var timesWeak: Int = 0
    var lastRating: Rating? = nil
    var nextDue: Date = .init(timeIntervalSince1970: 0) // egyszerű ütemezéshez

    enum Rating: String, Codable { case great, good, weak }
}

struct DeckFile: Codable {
    var cards: [Flashcard]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - STORE

@MainActor
final class FlashcardStore: ObservableObject {
    @Published var allCards: [Flashcard] = []
    @Published var selectedLessons: Set<String> = []
    @Published var showAnswers = false
    @Published var currentCard: Flashcard? = nil
    @Published var showOnlyDueCards = true // Csak esedékes kártyákat mutat
    @Published var stats: Stats = .init()
    @Published var cycleCompleted = false // Jelzi, ha körbeértünk a kártyákon
    
    // Nyomon követi, hogy mely kártyákat mutattuk már meg ebben a ciklusban
    private var seenInCycle: Set<UUID> = []
    
    // Számláló a "Csak esedékes" módhoz - hány különböző kártyát mutattunk már meg ebben a munkamenetben
    private var dueCardsSeen: Set<UUID> = []
    
    // Kártya számláló információk
    var totalCardsInPool: Int {
        filteredCards.count
    }
    
    var currentCardIndex: Int {
        if showOnlyDueCards {
            // "Csak esedékes" módban: hány különböző kártyát mutattunk már meg
            return dueCardsSeen.count
        } else {
            // "Minden kártya" módban: hány kártyát mutattunk már meg ebben a ciklusban
            return seenInCycle.count
        }
    }

    struct Stats {
        var total: Int = 0
        var byLesson: [String:Int] = [:]
        var weak: Int = 0
        var good: Int = 0
        var great: Int = 0
        var shown: Int = 0
        var accuracy: Double = 0
    }

    // Súlyozás a kiválasztáshoz (spaced-repetition, egyszerűsített)
    private let weightWeak = 5
    private let weightGood = 2
    private let weightGreat = 1

    // Fájl elérési utak
    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! }
    private var deckPath: URL { documentsURL.appendingPathComponent("deck.json") }
    private var backupsURL: URL { documentsURL.appendingPathComponent("backups", isDirectory: true) }

    init() {
        Task { await load() }
    }

    // MARK: Load & Save

    func load() async {
        do {
            if FileManager.default.fileExists(atPath: deckPath.path) {
                let data = try Data(contentsOf: deckPath)
                let deck = try JSONDecoder().decode(DeckFile.self, from: data)
                allCards = deck.cards
            } else {
                // Ha nincs deck.json, létrehozzuk minta kártyákkal
                allCards = sampleCards()
                saveDeck()
            }
            recomputeStats()
            pickNext()
        } catch {
            print("Load error: \(error)")
            allCards = sampleCards()
            recomputeStats()
            saveDeck()
            pickNext()
        }
    }

    private func saveDeck() {
        let deck = DeckFile(cards: allCards)
        if let data = try? JSONEncoder().encode(deck) {
            try? data.write(to: deckPath, options: .atomic)
        }
    }

    // CSV import: lecseréli a paklit, majd deck.json-ba menti
    func replaceCSV(with url: URL) async throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        allCards = parseCSV(text: text)
        recomputeStats()
        saveDeck()
        pickNext()
    }

    // MARK: CSV Parser (lesson;question;answer vagy tabok)
    private func parseCSV(text: String) -> [Flashcard] {
        var out: [Flashcard] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for raw in lines {
            let line = String(raw)
            let parts = line.split(separator: ";", omittingEmptySubsequences: false)
            let cols: [Substring]
            if parts.count >= 3 {
                cols = parts.map { $0 }
            } else {
                let tabs = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard tabs.count >= 3 else { continue }
                cols = tabs
            }
            let lesson = String(cols[0]).trimmed
            let q = String(cols[1]).trimmed
            let a = String(cols[2]).trimmed
            out.append(Flashcard(id: UUID(), lesson: lesson, question: q, answer: a))
        }
        return out
    }

    // MARK: Selection & SR

    var lessons: [String] {
        Array(Set(allCards.map { $0.lesson })).sorted()
    }

    var filteredCards: [Flashcard] {
        let pool = allCards.filter { selectedLessons.isEmpty || selectedLessons.contains($0.lesson) }
        if showOnlyDueCards {
            let now = Date()
            return pool.filter { $0.nextDue <= now }
        } else {
            return pool
        }
    }
    
    // Következő esedékes kártya dátuma
    var nextDueDate: Date? {
        let pool = allCards.filter { selectedLessons.isEmpty || selectedLessons.contains($0.lesson) }
        let futureCards = pool.filter { $0.nextDue > Date() }
        guard !futureCards.isEmpty else { return nil }
        return futureCards.map { $0.nextDue }.min()
    }

    func pickNext() {
        showAnswers = false
        let pool = filteredCards
        guard !pool.isEmpty else { currentCard = nil; return }

        // Szűrjük ki azokat a kártyákat, amiket már láttunk ebben a ciklusban (ha "Minden kártya" módban vagyunk)
        var availableCards: [Flashcard]
        if !showOnlyDueCards {
            availableCards = pool.filter { !seenInCycle.contains($0.id) }
            // Ha nincs több elérhető kártya, újrakezdjük
            if availableCards.isEmpty && !pool.isEmpty {
                seenInCycle = []
                cycleCompleted = true
                availableCards = pool
            }
        } else {
            availableCards = pool
        }

        // súlyozott véletlen választás
        var weighted: [(Flashcard, Int)] = []
        for card in availableCards {
            let w: Int
            switch card.lastRating {
            case .weak: w = weightWeak
            case .good: w = weightGood
            case .great: w = weightGreat
            case .none: w = weightGood // új kártya: közepes súly
            }
            weighted.append((card, max(w, 1)))
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        let r = Int.random(in: 0..<max(total,1))
        var acc = 0
        var chosen = weighted.first!.0
        for (c,w) in weighted {
            acc += w
            if r < acc { chosen = c; break }
        }
        currentCard = chosen
        
        // Ha új kártyát választottunk, töröljük a cycleCompleted flag-et
        if currentCard != nil {
            cycleCompleted = false
        }
        
        // Hozzáadjuk a kiválasztott kártyát a látottakhoz
        if !showOnlyDueCards {
            seenInCycle.insert(chosen.id)
        } else {
            // "Csak esedékes" módban: hozzáadjuk a látottakhoz, ha még nem láttuk
            dueCardsSeen.insert(chosen.id)
        }
    }
    
    // Újrakezdi a ciklust (pl. amikor változik a szűrő)
    func resetCycle() {
        seenInCycle = []
        cycleCompleted = false
        dueCardsSeen = []
    }

    func reveal() { showAnswers = true }

    func rate(_ rating: Flashcard.Rating) {
        guard let card = currentCard, let idx = allCards.firstIndex(where: { $0.id == card.id }) else { return }
        var c = allCards[idx]
        c.timesShown += 1
        switch rating {
            case .weak: c.timesWeak += 1
            case .good: c.timesGood += 1
            case .great: c.timesGreat += 1
        }
        c.lastRating = rating
        // egyszerű ütemezés: weak → 0.5 nap, good → 2 nap, great → 5 nap
        let days: Double = (rating == .weak) ? 0.5 : (rating == .good ? 2 : 5)
        c.nextDue = Calendar.current.date(byAdding: .day, value: Int(days.rounded()), to: Date()) ?? Date()

        allCards[idx] = c
        recomputeStats()
        saveDeck()
        pickNext()
    }

    func recomputeStats() {
        stats.total = allCards.count
        stats.byLesson = Dictionary(grouping: allCards, by: { $0.lesson }).mapValues(\.count)
        stats.weak = allCards.reduce(0) { $0 + $1.timesWeak }
        stats.good = allCards.reduce(0) { $0 + $1.timesGood }
        stats.great = allCards.reduce(0) { $0 + $1.timesGreat }
        stats.shown = allCards.reduce(0) { $0 + $1.timesShown }
        let correct = stats.good + stats.great
        stats.accuracy = stats.shown > 0 ? Double(correct) / Double(stats.shown) : 0
    }

    // MARK: CRUD

    func addCard(lesson: String, question: String, answer: String) {
        let card = Flashcard(id: UUID(), lesson: lesson.trimmed, question: question, answer: answer)
        allCards.append(card)
        recomputeStats()
        saveDeck()
    }

    func updateCard(_ card: Flashcard, lesson: String, question: String, answer: String) {
        guard let idx = allCards.firstIndex(where: { $0.id == card.id }) else { return }
        var c = allCards[idx]
        c.lesson = lesson.trimmed
        c.question = question
        c.answer = answer
        allCards[idx] = c
        recomputeStats()
        saveDeck()
    }

    func deleteCard(_ card: Flashcard) {
        allCards.removeAll { $0.id == card.id }
        recomputeStats()
        saveDeck()
    }

    // MARK: Deck Management

    // Deck exportálása JSON formátumban
    func exportDeck() -> URL? {
        guard let data = try? JSONEncoder().encode(DeckFile(cards: allCards)) else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("deck.json")
        try? data.write(to: tempURL)
        return tempURL
    }

    // Deck importálása JSON fájlból
    func importDeck(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let deck = try JSONDecoder().decode(DeckFile.self, from: data)
        allCards = deck.cards
        recomputeStats()
        saveDeck()
        pickNext()
    }

    // Új üres deck létrehozása
    func createNewDeck() {
        allCards = []
        selectedLessons = []
        recomputeStats()
        saveDeck()
        pickNext()
    }

    // Új minta deck létrehozása
    func createSampleDeck() {
        allCards = sampleCards()
        selectedLessons = []
        recomputeStats()
        saveDeck()
        pickNext()
    }

    // Deck törlése (visszaállítja minta kártyákra)
    func deleteDeck() {
        createSampleDeck()
    }

    // Deck fájl létezésének ellenőrzése
    var deckExists: Bool {
        FileManager.default.fileExists(atPath: deckPath.path)
    }
    
    // MARK: Backup Management
    
    // Biztonsági mentés létrehozása
    func createBackup() throws {
        // Létrehozzuk a backups mappát, ha nem létezik
        try? FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        
        // Dátum és idő formátum: YYYY-MM-DD_HH-mm
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateString = formatter.string(from: Date())
        let backupFileName = "deck_backup_\(dateString).json"
        let backupPath = backupsURL.appendingPathComponent(backupFileName)
        
        // Másoljuk a jelenlegi deck.json-t
        let deck = DeckFile(cards: allCards)
        guard let data = try? JSONEncoder().encode(deck) else {
            throw NSError(domain: "BackupError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nem sikerült kódolni a decket"])
        }
        try data.write(to: backupPath, options: .atomic)
    }
    
    // Biztonsági mentések listázása
    func listBackups() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("deck_backup_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // Legújabb elöl
    }
    
    // Biztonsági mentés visszaállítása
    func restoreBackup(from url: URL) throws {
        // Betöltjük a backup-ot
        let data = try Data(contentsOf: url)
        let deck = try JSONDecoder().decode(DeckFile.self, from: data)
        
        // Átmásoljuk az éles deck.json-ba
        guard let deckData = try? JSONEncoder().encode(deck) else {
            throw NSError(domain: "RestoreError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nem sikerült kódolni a decket"])
        }
        try deckData.write(to: deckPath, options: .atomic)
        
        // Betöltjük az éles decket
        allCards = deck.cards
        recomputeStats()
        resetCycle()
        pickNext()
    }
    
    // Biztonsági mentés törlése
    func deleteBackup(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    // Backup fájlnév formázása (olvasható formátum)
    func formatBackupName(_ url: URL) -> String {
        let fileName = url.lastPathComponent
        // deck_backup_2024-01-15_14-30.json -> 2024-01-15 14:30
        if fileName.hasPrefix("deck_backup_") && fileName.hasSuffix(".json") {
            let datePart = String(fileName.dropFirst("deck_backup_".count).dropLast(".json".count))
            let parts = datePart.split(separator: "_")
            if parts.count == 2 {
                let date = String(parts[0])
                let time = String(parts[1]).replacingOccurrences(of: "-", with: ":")
                return "\(date) \(time)"
            }
        }
        return fileName
    }

    // Minta kártyák (ha nincs fájl)
    private func sampleCards() -> [Flashcard] {
        [
            Flashcard(id: UUID(), lesson: "OOP", question: "OOP 4 pillére?", answer: "Encapsulation, Inheritance, Polymorphism, Abstraction"),
            Flashcard(id: UUID(), lesson: "OOP", question: "Különbség class és struct között Swiftben?", answer: "class = reference, öröklés; struct = value, gyors, nem öröklődik"),
            Flashcard(id: UUID(), lesson: "Swift", question: "Mi az a protocol oriented programming?", answer: "Viselkedés protokollokkal + extensionökben, kevesebb öröklés")
        ]
    }
}

// MARK: - VIEWS

struct ContentView: View {
    @EnvironmentObject var store: FlashcardStore
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                LessonPicker()
                CardFilterToggle()
                CardProgressView()
                if store.cycleCompleted {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Körbeértünk! Újrakezdjük a ciklust.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .transition(.opacity)
                }
                if let card = store.currentCard {
                    FlashcardView(
                        card: card,
                        showAnswer: store.showAnswers,
                        onReveal: { store.reveal() },
                        onRate: { store.rate($0) }
                    )
                    .frame(maxHeight: 360)
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        if store.showOnlyDueCards {
                            ContentUnavailableView("Nincs esedékes kártya",
                                                   systemImage: "checkmark.seal",
                                                   description: Text("Válassz leckét vagy importálj CSV-t."))
                            if let nextDue = store.nextDueDate {
                                VStack(spacing: 4) {
                                    Text("Következő esedékes kártya:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(nextDue, style: .relative)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.blue)
                                }
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                            }
                        } else {
                            ContentUnavailableView("Nincs kártya",
                                                   systemImage: "rectangle.stack",
                                                   description: Text("Válassz leckét vagy importálj CSV-t."))
                        }
                    }
                }
                StatsView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink {
                            ManageCardsView()
                        } label: {
                            Label("Kártyák kezelése", systemImage: "square.and.pencil")
                        }
                        NavigationLink {
                            DeckManagementView()
                        } label: {
                            Label("Deck kezelése", systemImage: "folder")
                        }
                    } label: {
                        Label("Kezelés", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { Task { store.pickNext() } } label: {
                        Label("Következő", systemImage: "arrow.right.circle")
                    }
                }
            }
            .navigationTitle("ModoFlip")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .text, .data],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    Task { try? await store.replaceCSV(with: url) }
                }
            }
        }
    }
}

struct LessonPicker: View {
    @EnvironmentObject var store: FlashcardStore
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(store.lessons, id: \.self) { lesson in
                    let selected = store.selectedLessons.contains(lesson)
                    Button {
                        if selected { store.selectedLessons.remove(lesson) }
                        else { store.selectedLessons.insert(lesson) }
                        store.resetCycle()
                        store.pickNext()
                    } label: {
                        Text(lesson)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(selected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.12))
                            .foregroundColor(selected ? .blue : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(.horizontal)
        }
    }
}

struct CardFilterToggle: View {
    @EnvironmentObject var store: FlashcardStore
    
    var body: some View {
        HStack {
            Toggle(isOn: $store.showOnlyDueCards) {
                Label(
                    store.showOnlyDueCards ? "Csak esedékes kártyák" : "Minden kártya",
                    systemImage: store.showOnlyDueCards ? "clock.fill" : "square.stack.fill"
                )
                .font(.subheadline)
            }
            .onChange(of: store.showOnlyDueCards) { _ in
                store.resetCycle()
                store.pickNext()
            }
        }
        .padding(.horizontal)
    }
}

struct CardProgressView: View {
    @EnvironmentObject var store: FlashcardStore
    
    var body: some View {
        let total = store.totalCardsInPool
        let current = store.currentCardIndex
        
        if total > 0 {
            HStack {
                Image(systemName: "list.number")
                    .foregroundStyle(.secondary)
                Text("Kártyák: \(current) / \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let progress = min(Double(current) / Double(total), 1.0)
                ProgressView(value: progress)
                    .frame(width: 100)
                    .tint(.green)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.05))
        }
    }
}

struct FlashcardView: View {
    let card: Flashcard
    let showAnswer: Bool
    var onReveal: ()->Void
    var onRate: (Flashcard.Rating)->Void

    var body: some View {
        VStack(spacing: 12) {
            Text(card.lesson.uppercased())
                .font(.caption).foregroundStyle(.secondary)
            Text(card.question)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
            Spacer()
            if showAnswer {
                ScrollView {
                    Text(card.answer)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
                .frame(maxHeight: 140)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button { onRate(.weak) }  label: { rateLabel("Gyenge", "hand.thumbsdown") }
                        .buttonStyle(.bordered)
                    Button { onRate(.good) }  label: { rateLabel("Jó", "hand.thumbsup") }
                        .buttonStyle(.borderedProminent)
                    Button { onRate(.great) } label: { rateLabel("Kiváló", "star.fill") }
                        .tint(.orange)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button(action: onReveal) {
                    Label("Megfordít", systemImage: "arrow.2.squarepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private func rateLabel(_ title: String, _ system: String) -> some View {
        Label(title, systemImage: system)
            .frame(minWidth: 90)
    }
}

struct StatsView: View {
    @EnvironmentObject var store: FlashcardStore
    var body: some View {
        let s = store.stats
        VStack(alignment: .leading, spacing: 8) {
            Text("Statisztika")
                .font(.headline)
            HStack {
                stat("Kártyák", "\(s.total)")
                stat("Megjelenések", "\(s.shown)")
                stat("Pontosság", String(format: "%.0f%%", s.accuracy*100))
            }
            HStack {
                stat("Gyenge", "\(s.weak)")
                stat("Jó", "\(s.good)")
                stat("Kiváló", "\(s.great)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(store.lessons, id: \.self) { l in
                        let c = s.byLesson[l] ?? 0
                        Text("\(l): \(c)")
                            .font(.caption)
                            .padding(6)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Management (CRUD UI)

struct ManageCardsView: View {
    @EnvironmentObject var store: FlashcardStore
    @State private var search = ""

    var filtered: [Flashcard] {
        let base = store.allCards
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.lesson.localizedCaseInsensitiveContains(search) ||
            $0.question.localizedCaseInsensitiveContains(search) ||
            $0.answer.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { card in
                NavigationLink {
                    CardEditorView(mode: .edit(card))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.lesson).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("#\(card.timesShown)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(card.question).lineLimit(2)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .onDelete { idxSet in
                idxSet.map { filtered[$0] }.forEach { store.deleteCard($0) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Kártyák kezelése")
        .toolbar {
            NavigationLink {
                CardEditorView(mode: .create)
            } label: {
                Label("Új kártya", systemImage: "plus.circle.fill")
            }
        }
    }
}

struct CardEditorView: View {
    enum Mode { case create, edit(Flashcard) }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: FlashcardStore

    let mode: Mode

    @State private var lesson: String = ""
    @State private var useNewLesson = false
    @State private var newLesson: String = ""

    @State private var question: String = ""
    @State private var answer: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Lecke választó / létrehozó
                Text("Lecke").font(.caption).foregroundStyle(.secondary)
                if useNewLesson {
                    HStack {
                        TextField("Új lecke neve", text: $newLesson)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            useNewLesson = false
                            lesson = newLesson
                        } label: { Text("Használom") }
                    }
                } else {
                    Picker("Lecke", selection: $lesson) {
                        ForEach(store.lessons, id: \.self) { l in
                            Text(l).tag(l)
                        }
                        Text("➕ Új lecke…").tag("__NEW__")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: lesson) { value in
                        if value == "__NEW__" {
                            useNewLesson = true
                            newLesson = ""
                            lesson = ""
                        }
                    }
                }

                // Kérdés
                Text("Kérdés").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    TextEditor(text: $question)
                        .frame(minHeight: 140, maxHeight: 140) // fix 140 magas, belül scroll
                }
                .frame(maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

                // Válasz
                Text("Válasz").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    TextEditor(text: $answer)
                        .frame(minHeight: 180, maxHeight: 180)
                }
                .frame(maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

                Spacer(minLength: 12)
                HStack {
                    Button(role: .cancel) { dismiss() } label: {
                        Label("Mégse", systemImage: "xmark")
                    }
                    Spacer()
                    Button {
                        let finalLesson = useNewLesson ? newLesson : lesson
                        guard !finalLesson.trimmed.isEmpty,
                              !question.trimmed.isEmpty,
                              !answer.trimmed.isEmpty else { return }
                        switch mode {
                        case .create:
                            store.addCard(lesson: finalLesson, question: question, answer: answer)
                        case .edit(let card):
                            store.updateCard(card, lesson: finalLesson, question: question, answer: answer)
                        }
                        dismiss()
                    } label: {
                        Label(mode.isCreate ? "Hozzáadás" : "Mentés", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle(mode.isCreate ? "Új kártya" : "Kártya szerkesztése")
        .onAppear {
            if case .edit(let c) = mode {
                lesson = c.lesson
                question = c.question
                answer = c.answer
            } else {
                lesson = store.lessons.first ?? ""
            }
        }
    }
}

private extension CardEditorView.Mode {
    var isCreate: Bool {
        if case .create = self { return true } else { return false }
    }
}

// MARK: - Deck Management View

struct DeckManagementView: View {
    @EnvironmentObject var store: FlashcardStore
    @State private var showingJSONImporter = false
    @State private var showingCSVImporter = false
    @State private var showingDeleteAlert = false
    @State private var showingNewDeckAlert = false
    @State private var showingSampleDeckAlert = false
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var backups: [URL] = []
    @State private var showingRestoreAlert = false
    @State private var backupToRestore: URL?
    @State private var backupToDelete: URL?
    @State private var showingDeleteBackupAlert = false
    @State private var showingBackupShareSheet = false
    @State private var backupToShare: URL?
    
    var body: some View {
        List {
            Section("Deck információk") {
                HStack {
                    Text("Kártyák száma")
                    Spacer()
                    Text("\(store.stats.total)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Leckék száma")
                    Spacer()
                    Text("\(store.lessons.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Deck fájl")
                    Spacer()
                    Text(store.deckExists ? "Létezik" : "Nem létezik")
                        .foregroundStyle(store.deckExists ? .green : .orange)
                }
            }
            
            Section("Deck műveletek") {
                Button {
                    showingNewDeckAlert = true
                } label: {
                    Label("Új üres deck", systemImage: "plus.circle")
                }
                
                Button {
                    showingSampleDeckAlert = true
                } label: {
                    Label("Minta deck létrehozása", systemImage: "doc.badge.plus")
                }
                
                Button {
                    showingJSONImporter = true
                } label: {
                    Label("Deck importálása (JSON)", systemImage: "square.and.arrow.down")
                }
                
                Button {
                    if let url = store.exportDeck() {
                        exportURL = url
                        showingExportSheet = true
                    }
                } label: {
                    Label("Deck exportálása (JSON)", systemImage: "square.and.arrow.up")
                }
                .disabled(!store.deckExists || store.allCards.isEmpty)
                
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Deck törlése", systemImage: "trash")
                }
                .disabled(!store.deckExists)
            }
            
            Section("CSV importálás") {
                Button {
                    showingCSVImporter = true
                } label: {
                    Label("CSV importálása", systemImage: "doc.text")
                }
            }
            
            Section("Biztonsági mentések") {
                Button {
                    do {
                        try store.createBackup()
                        backups = store.listBackups()
                    } catch {
                        print("Backup error: \(error)")
                    }
                } label: {
                    Label("Deck biztonsági mentése", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!store.deckExists || store.allCards.isEmpty)
                
                if !backups.isEmpty {
                    ForEach(backups, id: \.self) { backupURL in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.formatBackupName(backupURL))
                                    .font(.subheadline)
                                Text(backupURL.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button {
                                    backupToShare = backupURL
                                    showingBackupShareSheet = true
                                } label: {
                                    Label("Megosztás", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    backupToRestore = backupURL
                                    showingRestoreAlert = true
                                } label: {
                                    Label("Visszaállítás", systemImage: "arrow.counterclockwise")
                                }
                                Button(role: .destructive) {
                                    backupToDelete = backupURL
                                    showingDeleteBackupAlert = true
                                } label: {
                                    Label("Törlés", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                } else {
                    Text("Nincs biztonsági mentés")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Deck kezelése")
        .onAppear {
            backups = store.listBackups()
        }
        .fileImporter(
            isPresented: $showingJSONImporter,
            allowedContentTypes: [UTType.json, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task {
                    do {
                        try await store.importDeck(from: url)
                    } catch {
                        print("Import error: \(error)")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task {
                    do {
                        try await store.replaceCSV(with: url)
                    } catch {
                        print("CSV import error: \(error)")
                    }
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showingBackupShareSheet) {
            if let url = backupToShare, FileManager.default.fileExists(atPath: url.path) {
                ShareSheet(items: [url])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            } else {
                VStack {
                    Text("Nem sikerült megosztani a fájlt")
                        .padding()
                }
                .presentationDetents([.height(200)])
            }
        }
        .alert("Új üres deck", isPresented: $showingNewDeckAlert) {
            Button("Mégse", role: .cancel) { }
            Button("Létrehozás", role: .destructive) {
                store.createNewDeck()
            }
        } message: {
            Text("Az új üres deck létrehozása törli az összes jelenlegi kártyát. Biztosan folytatod?")
        }
        .alert("Minta deck létrehozása", isPresented: $showingSampleDeckAlert) {
            Button("Mégse", role: .cancel) { }
            Button("Létrehozás", role: .destructive) {
                store.createSampleDeck()
            }
        } message: {
            Text("A minta deck létrehozása lecseréli az összes jelenlegi kártyát minta kártyákra. Biztosan folytatod?")
        }
        .alert("Deck törlése", isPresented: $showingDeleteAlert) {
            Button("Mégse", role: .cancel) { }
            Button("Törlés", role: .destructive) {
                store.deleteDeck()
            }
        } message: {
            Text("A deck törlése visszaállítja a minta kártyákat. Biztosan folytatod?")
        }
        .alert("Biztonsági mentés visszaállítása", isPresented: $showingRestoreAlert) {
            Button("Mégse", role: .cancel) { }
            Button("Visszaállítás", role: .destructive) {
                if let backupURL = backupToRestore {
                    do {
                        try store.restoreBackup(from: backupURL)
                        backups = store.listBackups()
                    } catch {
                        print("Restore error: \(error)")
                    }
                }
            }
        } message: {
            if let backupURL = backupToRestore {
                Text("A biztonsági mentés visszaállítása lecseréli a jelenlegi decket. Biztosan folytatod?\n\n\(store.formatBackupName(backupURL))")
            } else {
                Text("A biztonsági mentés visszaállítása lecseréli a jelenlegi decket. Biztosan folytatod?")
            }
        }
        .alert("Biztonsági mentés törlése", isPresented: $showingDeleteBackupAlert) {
            Button("Mégse", role: .cancel) { }
            Button("Törlés", role: .destructive) {
                if let backupURL = backupToDelete {
                    do {
                        try store.deleteBackup(at: backupURL)
                        backups = store.listBackups()
                    } catch {
                        print("Delete backup error: \(error)")
                    }
                }
            }
        } message: {
            if let backupURL = backupToDelete {
                Text("Biztosan törölni szeretnéd ezt a biztonsági mentést?\n\n\(store.formatBackupName(backupURL))")
            } else {
                Text("Biztosan törölni szeretnéd ezt a biztonsági mentést?")
            }
        }
    }
}

// ShareSheet helper a deck exportáláshoz
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // iPad támogatás
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView()
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
