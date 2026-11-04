import AppKit
import Kit42

// OpenDocument presentation (.odp). (stub, replaced by the full reader/writer)
enum ODPReader {
    static func read(_ data: Data) throws -> Deck { throw DeckError.invalid("ODP not yet supported") }
}

enum ODPWriter {
    static func data(_ deck: Deck) -> Data { Data() }
}
