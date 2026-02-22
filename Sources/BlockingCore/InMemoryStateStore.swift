import Foundation

public final class InMemoryStateStore: StateStore {
    private var currentState: AppState

    public init(initialState: AppState = AppState()) {
        self.currentState = initialState
    }

    public func load() throws -> AppState {
        currentState
    }

    public func save(_ state: AppState) throws {
        currentState = state
    }
}
