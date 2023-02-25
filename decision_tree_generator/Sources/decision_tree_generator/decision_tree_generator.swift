import Foundation
import NtarCore
import ArgumentParser

@main
struct decision_tree_generator: ParsableCommand {

    @Argument(help: """
        fill this shit in better sometime later
        """)
    var json_config_file_names: [String]
    
    mutating func run() throws {
        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)

        Log.i("Starting")

        for json_config_file_name in json_config_file_names {
            Log.d("should read \(json_config_file_name)")
        }
    }
}
