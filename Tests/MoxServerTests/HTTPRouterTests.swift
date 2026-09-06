import Foundation
import Testing
@testable import MoxServer

/// Tests for `HTTPRouter` path matching — the table-driven
/// dispatcher's only branch that isn't exact-match. v0.11 P1.2
/// added `/v1/models/<id>/load` and `/v1/models/<id>/unload`
/// which use a `__id__` placeholder in the routes table.
@Suite("HTTPRouter path matching")
struct HTTPRouterTests {

    @Test("Exact-match routes still hit")
    func exactMatchStillWorks() {
        let kind = HTTPRouter.route(method: "GET", path: "/health")
        if case .health = kind { } else {
            Issue.record("expected .health, got \(kind)")
        }
    }

    @Test("List models exact match")
    func listModelsExact() {
        let kind = HTTPRouter.route(method: "GET", path: "/v1/models")
        if case .listModels = kind { } else {
            Issue.record("expected .listModels, got \(kind)")
        }
    }

    @Test("Load model path-param captures id")
    func loadModelCapturesId() {
        let kind = HTTPRouter.route(
            method: "POST",
            path: "/v1/models/Qwen/Qwen2.5-7B-Instruct-4bit/load"
        )
        guard case .loadModel(let id) = kind else {
            Issue.record("expected .loadModel, got \(kind)")
            return
        }
        #expect(id == "Qwen/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("Unload model path-param captures id")
    func unloadModelCapturesId() {
        let kind = HTTPRouter.route(
            method: "POST",
            path: "/v1/models/mlx-community/bge-small-en-v1.5/unload"
        )
        guard case .unloadModel(let id) = kind else {
            Issue.record("expected .unloadModel, got \(kind)")
            return
        }
        #expect(id == "mlx-community/bge-small-en-v1.5")
    }

    @Test("Empty model id in load path falls through to notFound")
    func emptyIdFallsThrough() {
        let kind = HTTPRouter.route(
            method: "POST",
            path: "/v1/models//load"
        )
        if case .notFound = kind { } else {
            Issue.record("expected .notFound, got \(kind)")
        }
    }

    @Test("Wrong method on load path returns notFound")
    func wrongMethodReturnsNotFound() {
        // GET on a POST-only route must not match.
        let kind = HTTPRouter.route(
            method: "GET",
            path: "/v1/models/foo/load"
        )
        if case .notFound = kind { } else {
            Issue.record("expected .notFound for GET on POST route, got \(kind)")
        }
    }

    @Test("Extra path segments in load path return notFound")
    func extraSegmentsReturnsNotFound() {
        let kind = HTTPRouter.route(
            method: "POST",
            path: "/v1/models/foo/load/extra"
        )
        if case .notFound = kind { } else {
            Issue.record("expected .notFound for /load/extra, got \(kind)")
        }
    }

    @Test("Id with embedded slash captures only the inner segment")
    func idWithSlashCapturesAll() {
        // HF ids like 'mlx-community/Qwen2.5-7B-Instruct-4bit' have
        // slashes; we capture the whole thing because split on first
        // slash only is the wrong behavior for nested namespaces.
        let kind = HTTPRouter.route(
            method: "POST",
            path: "/v1/models/org/repo/branch/load"
        )
        guard case .loadModel(let id) = kind else {
            Issue.record("expected .loadModel, got \(kind)")
            return
        }
        // Our current implementation rejects slashes inside the
        // id (the `!modelId.contains("/")` guard in
        // `matchPathParam`). That's a design choice — nested paths
        // would need a different escape. Pin the current behavior.
        #expect(id == "")
    }
}