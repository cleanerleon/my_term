import Foundation

private final class AsyncResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}
func runAsync<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
    let box = AsyncResultBox<Value>(), done = DispatchSemaphore(value: 0)
    let task = Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    guard done.wait(timeout: .now() + 30) == .success else { task.cancel(); throw CheckFailure(description: "异步集成检查超时") }
    return try box.result!.get()
}
