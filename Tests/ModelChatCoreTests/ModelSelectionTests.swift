import ModelTransport
import Testing
@testable import ModelChatCore

@Suite
struct ModelSelectionTests {
    private let available = OpenAIModel(id: "loaded/model:4bit")
    private let other = OpenAIModel(id: "another-model")

    @Test
    func unsupportedCatalogPreservesAnExplicitModel() throws {
        for allowsFallback in [true, false] {
            #expect(
                try EndpointModelSelection.resolve(
                    requestedModel: "  configured/model:4bit\n",
                    catalog: nil,
                    allowsFallback: allowsFallback
                ) == "configured/model:4bit"
            )
        }
    }

    @Test(arguments: [nil, "", " \t\n"] as [String?])
    func unsupportedCatalogRequiresAnExplicitModel(requestedModel: String?) {
        for allowsFallback in [true, false] {
            #expect(throws: EndpointModelSelectionError.modelRequired) {
                try EndpointModelSelection.resolve(
                    requestedModel: requestedModel,
                    catalog: nil,
                    allowsFallback: allowsFallback
                )
            }
        }
    }

    @Test(arguments: [nil, "", " \t\n", "previous-model"] as [String?])
    func emptyCatalogReportsNoLoadedModels(requestedModel: String?) {
        for allowsFallback in [true, false] {
            #expect(throws: EndpointModelSelectionError.noModels) {
                try EndpointModelSelection.resolve(
                    requestedModel: requestedModel,
                    catalog: [],
                    allowsFallback: allowsFallback
                )
            }
        }
    }

    @Test
    func anExplicitAvailableModelWinsRegardlessOfCatalogOrder() throws {
        for catalog in [[available, other], [other, available]] {
            for allowsFallback in [true, false] {
                #expect(
                    try EndpointModelSelection.resolve(
                        requestedModel: available.id,
                        catalog: catalog,
                        allowsFallback: allowsFallback
                    ) == available.id
                )
            }
        }
    }

    @Test
    func surroundingWhitespaceIsRemovedBeforeMatching() throws {
        #expect(
            try EndpointModelSelection.resolve(
                requestedModel: "\t \(available.id) \n",
                catalog: [other, available],
                allowsFallback: false
            ) == available.id
        )
    }

    @Test(arguments: [nil, "", " \t\n"] as [String?])
    func aSoleAdvertisedModelIsSelectedWithoutARequest(requestedModel: String?) throws {
        for allowsFallback in [true, false] {
            #expect(
                try EndpointModelSelection.resolve(
                    requestedModel: requestedModel,
                    catalog: [available],
                    allowsFallback: allowsFallback
                ) == available.id
            )
        }
    }

    @Test
    func aStaleModelFallsBackToTheSoleAdvertisedModel() throws {
        #expect(
            try EndpointModelSelection.resolve(
                requestedModel: "previous-model",
                catalog: [available]
            ) == available.id
        )
    }

    @Test
    func aStrictRequestRejectsUnavailableModelsInAnyNonemptyCatalog() {
        for catalog in [[available], [available, other]] {
            #expect(throws: EndpointModelSelectionError.modelUnavailable("previous-model")) {
                try EndpointModelSelection.resolve(
                    requestedModel: " \tprevious-model\n",
                    catalog: catalog,
                    allowsFallback: false
                )
            }
        }
    }

    @Test(arguments: [nil, "", " \t\n"] as [String?])
    func multipleModelsRequireAChoiceWithoutARequest(requestedModel: String?) {
        for catalog in [[available, other], [other, available]] {
            for allowsFallback in [true, false] {
                #expect(throws: EndpointModelSelectionError.multipleModels) {
                    try EndpointModelSelection.resolve(
                        requestedModel: requestedModel,
                        catalog: catalog,
                        allowsFallback: allowsFallback
                    )
                }
            }
        }
    }

    @Test
    func aStaleModelDoesNotSilentlySelectTheFirstOfSeveralModels() {
        for catalog in [[available, other], [other, available]] {
            #expect(throws: EndpointModelSelectionError.multipleModels) {
                try EndpointModelSelection.resolve(
                    requestedModel: "previous-model",
                    catalog: catalog
                )
            }
        }
    }
}
