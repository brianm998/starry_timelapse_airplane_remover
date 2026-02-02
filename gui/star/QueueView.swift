import SwiftUI

struct QueueView: View {

    let stats: OperationQueueStats

    var body: some View {
        VStack(alignment: .leading) {
            Text(stats.name).font(.headline)
              .foregroundColor(.white)
            Text("Operations: \(stats.operationCount)")
              .foregroundColor(.white)
            Text("Max concurrent: \(stats.maxConcurrentOperationCount)")
              .foregroundColor(.white)
//            Text("Suspended: \(stats.isSuspended ? "Yes" : "No")")
        }
    }
}
