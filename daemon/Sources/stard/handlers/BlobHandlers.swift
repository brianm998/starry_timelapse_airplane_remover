import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf

/// `Blob.*`: what the Blob Processing window reads and writes (see [BlobSteps]).
enum BlobHandlers {
    static func getSteps(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            let request = try Star_V1_GetBlobStepsRequest(serializedBytes: payload)
            let response = BlobSteps.response(for: Mapping.detectionType(from: request.detectionType))
            try await transport.respond(id: id, payload: response.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func setCustomSteps(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            let request = try Star_V1_SetCustomBlobStepsRequest(serializedBytes: payload)
            guard let custom = DetectionType.custom.blobProcessor as? CustomBlobProcessor else {
                await transport.sendError(id: id, message: "the custom detection type is not available", code: 500)
                return
            }
            let response = try BlobSteps.apply(request, to: custom)
            try await transport.respond(id: id, payload: response.serializedData())
        } catch let failure as BlobSteps.Failure {
            await transport.sendError(id: id, message: failure.description, code: 400)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
