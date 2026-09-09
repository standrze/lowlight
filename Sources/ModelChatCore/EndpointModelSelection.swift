import Foundation
import ModelTransport

/// Resolve a model before creating a session. Midnight Runner lists only its
/// loaded model; endpoints with several models still need a user selection.
public enum EndpointModelSelection {
    public static func resolve(
        requestedModel: String?,
        catalog: [OpenAIModel]?,
        allowsFallback: Bool = true
    ) throws -> String {
        let requested = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let catalog else {
            guard !requested.isEmpty else { throw EndpointModelSelectionError.modelRequired }
            return requested
        }
        let identifiers = Set(catalog.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard !identifiers.isEmpty else { throw EndpointModelSelectionError.noModels }
        if identifiers.contains(requested) { return requested }
        if !requested.isEmpty && !allowsFallback {
            throw EndpointModelSelectionError.modelUnavailable(requested)
        }
        guard identifiers.count == 1, let model = identifiers.first else {
            throw EndpointModelSelectionError.multipleModels
        }
        return model
    }
}

public enum EndpointModelSelectionError: LocalizedError, Equatable {
    case noModels
    case multipleModels
    case modelUnavailable(String)
    case modelRequired

    public var errorDescription: String? {
        switch self {
        case .noModels:
            "The server reports no available models. Load a model in the server, then use /connection reconnect."
        case .multipleModels:
            "The server reports several models. Use /model to choose one."
        case .modelUnavailable(let model):
            "Model \(model) is not available on this server. Use /model to choose one."
        case .modelRequired:
            "This endpoint does not provide a model list. Select one with /model NAME or launch with --model NAME."
        }
    }
}
