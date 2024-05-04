/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

/*

 Verbose Log functions:

   Log.verbose()
   Log.verbose("something happened")
   Log.verbose("something happened", somedata)
   Log.verbose(somedata)
   Log.verbose("something happened", [somedata, otherdata])
   Log.verbose([somedata, otherdata])

   or 

   Log.v()
   Log.v("something happened")
   Log.v("something happened", somedata)
   Log.v(somedata)
   Log.v("something happened", [somedata, otherdata])
   Log.v([somedata, otherdata])

 Debug Log functions:

   Log.debug()
   Log.debug("something happened")
   Log.debug("something happened", somedata)
   Log.debug(somedata)
   Log.debug("something happened", [somedata, otherdata])
   Log.debug([somedata, otherdata])

   or 

   Log.d()
   Log.d("something happened")
   Log.d("something happened", somedata)
   Log.d(somedata)
   Log.d("something happened", [somedata, otherdata])
   Log.d([somedata, otherdata])

 Info Log functions:

   Log.info()
   Log.info("something happened")
   Log.info("something happened", somedata)
   Log.info(somedata)
   Log.info("something happened", [somedata, otherdata])
   Log.info([somedata, otherdata])

   or 

   Log.i()
   Log.i("something happened")
   Log.i("something happened", somedata)
   Log.i(somedata)
   Log.i("something happened", [somedata, otherdata])
   Log.i([somedata, otherdata])

 Warn Log functions:

   Log.warn()
   Log.warn("something happened")
   Log.warn("something happened", somedata)
   Log.warn(somedata)
   Log.warn("something happened", [somedata, otherdata])
   Log.warn([somedata, otherdata])

   or 

   Log.w()
   Log.w("something happened")
   Log.w("something happened", somedata)
   Log.w(somedata)
   Log.w("something happened", [somedata, otherdata])
   Log.w([somedata, otherdata])

 Error Log functions:

   Log.error()
   Log.error("something happened")
   Log.error("something happened", somedata)
   Log.error(somedata)
   Log.error("something happened", [somedata, otherdata])
   Log.error([somedata, otherdata])
   Log.error(error) // can be any Error

   or 

   Log.e()
   Log.e("something happened")
   Log.e("something happened", somedata)
   Log.e(somedata)
   Log.e("something happened", [somedata, otherdata])
   Log.e([somedata, otherdata])
   Log.e(error) // can be any Error


 When called with no arguments, the above functions will simply record that an event
 of some type (debug, info, warn, error) occured at a specific time, in a particular file,
 function, and line number.

 While not required, arguments can be given in the format of a string, and/or some data.  

 In all cases, 'some data' is handled generically.

 If somedata is Encodable, handlers will be passed a LogData as such.
 Encodable log data will represent this data as json via the string description property.
 If somedata is CustomStringConvertible the description property will be used.
 Otherwise a string describing it will be used by handlers.

*/

public class Log {

    /*
        Handlers can be set during app startup in the app delegate as follows:

        Log.add(handler: ConsoleLogHandler(at: .info), for: .console)
        Log.add(handler: FileLogHandler(at: .debug), for: .file)

     */
    public static func add(handler: LogHandler, for outputType: Log.Output) {
        if handler.level < minimumLogLevel { minimumLogLevel = handler.level }
        Task { await gremlin.add(handler: handler, for: outputType) }
    }

    private static var minimumLogLevel: Log.Level = .error
    
    public enum Output {
        case console
        case file
        case alert
    }

    public static var name: String = "log"
    public static var nameSuffix: String?

    public static let dispatchGroup = DispatchGroup()
    
    public enum Level: String,
                       CustomStringConvertible,
                       CaseIterable,
                       Decodable
    {
        case verbose
        case debug
        case info
        case warn
        case error
        
        public static func <=(_ left: Level, right: Level) -> Bool {
            return left.num <= right.num
        }

        public static func <(_ left: Level, right: Level) -> Bool {
            return left.num < right.num
        }

        public static func >=(_ left: Level, right: Level) -> Bool {
            return left.num >= right.num
        }

        public static func >(_ left: Level, right: Level) -> Bool {
            return left.num > right.num
        }

        public static func ==(_ left: Level, right: Level) -> Bool {
            return left.num == right.num
        }

        public var emo: String {
            switch self {
            case .verbose:
                return "💦"
            case .debug:
                return "👩‍💻"
            case .info:
                return "🚩"
            case .warn:
                return "⚠️"
            case .error:
                return "☠️"
            }
        }

        public var description: String {
            switch self {
            case .verbose:
                return "VERBOSE"
            case .debug:
                return "DEBUG"
            case .info:
                return "INFO"
            case .warn:
                return "WARN"
            case .error:
                return "ERROR"
            }
        }

        private var num: Int {
            switch self {
            case .verbose:
                return 4
            case .debug:
                return 3
            case .info:
                return 2
            case .warn:
                return 1
            case .error:
                return 0
            }
        }
    }
}

extension Log {                 
    /*
       Log.verbose()
       Log.verbose("something happened")
     */
    public static func verbose(_ message: String? = nil,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, at: Level.verbose, file, function, line)
    }

    /*
       Log.verbose("something happened", somedata)
     */
    public static func verbose<T>(_ message: String? = nil,
                                _ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line) 
    {
        logInternal(message, with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.verbose(somedata)
     */
    public static func verbose<T>(_ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.verbose("something happened", [somedata, otherdata])
     */
    public static func verbose<T>(_ message: String? = nil,
                                _ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(message, with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.verbose([somedata, otherdata])
     */
    public static func verbose<T>(_ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .verbose, file, function, line)
    }
}

extension Log {                 
    /*
       Log.v()
       Log.v("something happened")
     */
    public static func v(_ message: String? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(message, at: Level.verbose, file, function, line)
    }

    /*
     Log.v("something happened", somedata)
     */
    public static func v<T>(_ message: String? = nil,
                            _ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line) 
    {
        logInternal(message, with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.v(somedata)
     */
    public static func v<T>(_ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.v("something happened", [somedata, otherdata])
     */
    public static func v<T>(_ message: String? = nil,
                            _ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .verbose, file, function, line)
    }
    
    /*
       Log.v([somedata, otherdata])
     */
    public static func v<T>(_ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .verbose, file, function, line)
    }
}


extension Log {                 
    /*
       Log.debug()
       Log.debug("something happened")
     */
    public static func debug(_ message: String? = nil,
                             file: String = #file,
                             function: String = #function,
                             line: Int = #line)
    {
        logInternal(message, at: Level.debug, file, function, line)
    }

    /*
       Log.debug("something happened", somedata)
     */
    public static func debug<T>(_ message: String? = nil,
                                _ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line) 
    {
        logInternal(message, with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.debug(somedata)
     */
    public static func debug<T>(_ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.debug("something happened", [somedata, otherdata])
     */
    public static func debug<T>(_ message: String? = nil,
                                _ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(message, with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.debug([somedata, otherdata])
     */
    public static func debug<T>(_ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .debug, file, function, line)
    }
}

extension Log {                 
    /*
       Log.d()
       Log.d("something happened")
     */
    public static func d(_ message: String? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(message, at: Level.debug, file, function, line)
    }

    /*
     Log.d("something happened", somedata)
     */
    public static func d<T>(_ message: String? = nil,
                            _ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line) 
    {
        logInternal(message, with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.d(somedata)
     */
    public static func d<T>(_ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.d("something happened", [somedata, otherdata])
     */
    public static func d<T>(_ message: String? = nil,
                            _ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .debug, file, function, line)
    }
    
    /*
       Log.d([somedata, otherdata])
     */
    public static func d<T>(_ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .debug, file, function, line)
    }
}

extension Log {                 // info
    /*
       Log.info()
       Log.info("something happened")
     */
    public static func info(_ message: String? = nil,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, at: .info, file, function, line)
    }

    /*
       Log.info("something happened", somedata)
     */
    public static func info<T>(_ message: String? = nil,
                               _ data: T?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, with: data, at: .info, file, function, line)
    }

    /*
       Log.info(somedata)
     */
    public static func info<T>(_ data: T?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(with: data, at: .info, file, function, line)
    }

    /*
       Log.info("something happened", [somedata, otherdata])
     */
    public static func info<T>(_ message: String? = nil,
                               _ data: [T]?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, with: data, at: .info, file, function, line)
    }

    /*
       Log.info([somedata, otherdata])
     */
    public static func info<T>(_ data: [T]?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(with: data, at: .info, file, function, line)
    }
}

extension Log {                 // i
    /*
       Log.i()
       Log.i("something happened")
     */
    public static func i(_ message: String? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(message, at: .info, file, function, line)
    }

    /*
       Log.i("something happened", somedata)
     */
    public static func i<T>(_ message: String? = nil,
                               _ data: T?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, with: data, at: .info, file, function, line)
    }

    /*
       Log.i(somedata)
     */
    public static func i<T>(_ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .info, file, function, line)
    }

    /*
       Log.i("something happened", [somedata, otherdata])
     */
    public static func i<T>(_ message: String? = nil,
                            _ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .info, file, function, line)
    }

    /*
       Log.i([somedata, otherdata])
     */
    public static func i<T>(_ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .info, file, function, line)
    }
}

extension Log {
    /*
       Log.warn()
       Log.warn("something happened")
     */
    public static func warn(_ message: String? = nil,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, at: .warn, file, function, line)
    }

    /*
       Log.warn("something happened", somedata)
     */
    public static func warn<T>(_ message: String? = nil,
                               _ data: T?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, with: data, at: .warn, file, function, line)
    }

    /*
       Log.warn(somedata)
     */
    public static func warn<T>(_ data: T?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(with: data, at: .warn, file, function, line)
    }

    /*
       Log.warn("something happened", [somedata, otherdata])
     */
    public static func warn<T>(_ message: String? = nil,
                               _ data: [T]?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(message, with: data, at: .warn, file, function, line)
    }

    /*
       Log.warn([somedata, otherdata])
     */
    public static func warn<T>(_ data: [T]?,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line)
    {
        logInternal(with: data, at: .warn, file, function, line)
    }
}

extension Log {
    /*
       Log.w()
       Log.w("something happened")
     */
    public static func w(_ message: String? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(message, at: .warn, file, function, line)
    }

    /*
       Log.w("something happened", somedata)
     */
    public static func w<T>(_ message: String? = nil,
                            _ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .warn, file, function, line)
    }

    /*
       Log.w(somedata)
     */
    public static func w<T>(_ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .warn, file, function, line)
    }

    /*
       Log.w("something happened", [somedata, otherdata])
     */
    public static func w<T>(_ message: String? = nil,
                            _ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .warn, file, function, line)
    }

    /*
       Log.w([somedata, otherdata])
     */
    public static func w<T>(_ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .warn, file, function, line)
    }
}

extension Log {
    /*
       Log.error()
       Log.error("something happened")
     */
    public static func error(_ message: String? = nil,
                             file: String = #file,
                             function: String = #function,
                             line: Int = #line)
    {
        logInternal(message,
                    at: .error,
                    file, function, line)
    }

    /*
       Log.error(error)
     */
    public static func error(_ error: Error? = nil,
                             file: String = #file,
                             function: String = #function,
                             line: Int = #line)
    {
        logInternal(at: .error, file, function, line)
    }

    /*
       Log.error(somedata)
       Log.error("something happened", somedata)
     */
    public static func error<T>(_ message: String? = nil,
                                _ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(message, with: data, at: .error, file, function, line)
    }

    /*
       Log.error("something happened", [somedata, otherdata])
     */
    public static func error<T>(_ data: T?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .error, file, function, line)
    }

    /*
       Log.error([somedata, otherdata])
     */
    public static func error<T>(_ message: String? = nil,
                                _ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(message, with: data, at: .error, file, function, line)
    }

    /*
       Log.error([somedata, otherdata])
     */
    public static func error<T>(_ data: [T]?,
                                file: String = #file,
                                function: String = #function,
                                line: Int = #line)
    {
        logInternal(with: data, at: .error, file, function, line)
    }

}

extension Log {
    /*
       Log.e()
       Log.e("something happened")
     */
    public static func e(_ message: String? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(message,
                    at: .error,
                    file, function, line)
    }

    /*
       Log.error(error)
     */
    public static func e(_ error: Error? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line)
    {
        logInternal(at: .error, file, function, line)
    }

    /*
       Log.e(somedata)
       Log.e("something happened", somedata)
     */
    public static func e<T>(_ message: String? = nil,
                            _ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .error, file, function, line)
    }

    /*
       Log.e("something happened", [somedata, otherdata])
     */
    public static func e<T>(_ data: T?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .error, file, function, line)
    }

    /*
       Log.e([somedata, otherdata])
     */
    public static func e<T>(_ message: String? = nil,
                            _ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(message, with: data, at: .error, file, function, line)
    }

    /*
       Log.e([somedata, otherdata])
     */
    public static func e<T>(_ data: [T]?,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line)
    {
        logInternal(with: data, at: .error, file, function, line)
    }
}

// after here are the internal implemenation details

fileprivate extension Log {
    static func logInternal(_ message: String? = nil,
                            at logLevel: Level,
                            _ file: String,
                            _ function: String,
                            _ line: Int)
    {
        logInternal(message, with: Optional<Int>.none, at: logLevel, file, function, line)
    }
        
    static func logInternal<T>(_ message: String? = nil,
                               with data: T? = Optional<T>.none,
                               at logLevel: Level,
                               _ file: String,
                               _ function: String,
                               _ line: Int)
    {
        let logTime = NSDate().timeIntervalSince1970
            
        Task {
            var string = ""
            
            if let message = message {
                string = message
            } else if data != nil {
                string = logLevel.description
            }
            
            var extraData: LogData?
            
            if let data = data {
                if let encodableData = data as? Encodable,
                   let encodableLogData = EncodableLogData(with: encodableData)
                {
                    // first we try to json encode any Encodable data
                    extraData = encodableLogData
                } else if let stringConvertibleData = data as? CustomStringConvertible {
                    // then we try the description of any CustomStringConvertible data
                    extraData = StringLogData(with: stringConvertibleData)
                } else {
                    // our final fallback for data we don't have a better way to encode
                    extraData = StringLogData(with: data)
                }
            }

            if logLevel > minimumLogLevel {
                await gremlin.log(string, at: logLevel,
                                  logTime: logTime, extraData: extraData,
                                  file, function, line)

            }
        }
    }

}

public struct LogHolder {
    let message: String
    let fileLocation: String
    let data: LogData?
    let logLevel: Log.Level
    let logTime: TimeInterval
}

public let gremlin = LogGremlin()

// this little guy just sits around and keeps the logs orderly by handling one log line at at time
public actor LogGremlin {

    public init() {
        Task {
            let foo = true
            while(foo) {
                if let log = await gremlin.nextLog() {
                    for handler in await gremlin.getHandlers().values {
                        if log.logLevel <= handler.level {
                            handler.log(message: log.message,
                                        at: log.fileLocation,
                                        with: log.data,
                                        at: log.logLevel,
                                        logTime: log.logTime)
                        }
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
    
    private var handlers: [Log.Output : LogHandler] = [:]

    private var pendingLogs: [LogHolder] = []

    public func getHandlers() -> [Log.Output : LogHandler] { handlers }

    private var minimumLogLevel: Log.Level = .error
    
    func add(handler: LogHandler, for outputType: Log.Output) {
        handlers[outputType] = handler
        if handler.level < minimumLogLevel { minimumLogLevel = handler.level }
    }

    public func pendingLogCount() -> Int { pendingLogs.count }
    
    func nextLog() -> LogHolder? {
        if pendingLogs.count > 0 { return pendingLogs.removeFirst() }
        return nil
    }

    func log(_ message: String,
             at logLevel: Log.Level,
             logTime: TimeInterval,             
             extraData: LogData? = nil,
             _ file: String,
             _ function: String,
             _ line: Int)
    {
        guard logLevel >= minimumLogLevel else { return }
        
        let filename = file.components(separatedBy: "/").last ?? file
        let fileLocation = "\(filename)@\(line)"

        pendingLogs.append(LogHolder(message: message,
                                     fileLocation: fileLocation,
                                     data: extraData,
                                     logLevel: logLevel,
                                     logTime: logTime))
        
    }
    
}


// after here is all testing code

#if DEBUG
// this is helpful when testing logging, to see a few test lines, and then avoid further spew 
public func LOG_ABORT() {
    Log.dispatchGroup.enter()
    TaskWaiter.shared.task {
        print("\n\n")
        print("☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️")
        print("☠️☠️☠️ was asked to abort ☠️☠️☠️")
        print("☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️☠️")
        print("\n\n")
        Log.dispatchGroup.leave()
        abort()
    }
}

fileprivate struct LogTest: Codable {
    let foo: String
    let bar: Int?
}
    
#else
public func LOG_ABORT() {}
#endif

extension Thread {
    var threadName: String {
        if isMainThread {
            return "Main Thread"
        } else {
            let desc = description
            if let start_idx = desc.firstIndex(of: "="),
               let end_idx = desc.firstIndex(of: ",")
            {
                // parsing a string like this for this VV number
                // <NSThread: 0x600001668900>{number = 11, name = (null)}
                let number = String(desc[start_idx..<end_idx]).dropFirst(2)
                return "Thread \(number)"
            } else {
                return description
            }
        }
    }
}
