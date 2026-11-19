import Speech

enum SFSpeechRecognizerLocales {
    /// Languages the system can recognise ON THIS MAC (asking for the list needs no permission).
    static var all: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { (id: $0.identifier, name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
    }
}
