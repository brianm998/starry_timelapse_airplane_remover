/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

#if !os(macOS)
public extension UIViewController {
    static let alertDispatchQueue = DispatchQueue(label: "alerts")

    @discardableResult
    func show(alert: UIAlertController,
              animated: Bool = true,
              tryNumber: Int = 0,
              maxTries: Int = 10,
              completion: (() -> Void)? = nil) -> Bool
    {
        guard tryNumber < maxTries else { return false }
        
        if let _ = self.presentedViewController {
            UIViewController.alertDispatchQueue.asyncAfter(deadline: .now() + 0.5) {
                UIViewController.alertDispatchQueue.suspend()
                if !self.show(alert: alert, //on: selfviewController,
                              animated: animated, tryNumber: tryNumber + 1)
                {
                    UIViewController.alertDispatchQueue.resume()
                }
            }
            return false
        } else {
            if Thread.isMainThread {
                self.present(alert, animated: animated, completion: completion)
            } else {
                DispatchQueue.main.async {
                    self.present(alert, animated: animated, completion: completion)
                }
            }
            return true
        }
    }
}

public class AlertLogHandler: LogHandler {

    public var dispatchQueue: DispatchQueue { return UIViewController.alertDispatchQueue }
    public var level: Log.Level?
    private let dateFormatter = DateFormatter()

    public init(at level: Log.Level) {
        self.level = level
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    public func log(message: String,
                    at fileLocation: String,
                    on threadName: String,
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
        dispatchQueue.async {
            let dateString = self.dateFormatter.string(from: Date())

            var logString = "" 
            if let data = data {
                logString = "\(dateString)\n\(fileLocation)\n\(message)\n\(data.description)"
            } else {
                logString = "\(dateString)\n\(fileLocation)\n\(message)"
            }

            let threeEmos = logLevel.emo + logLevel.emo + logLevel.emo
            let alertTitle = "\(threeEmos)  \(logLevel)  \(threeEmos)"

            let alert = UIAlertController(title: alertTitle,
                                          message: logString,
                                          preferredStyle: .alert)
            let okAction = UIAlertAction(title: "Ok", style: .cancel) { action in
                // un-pause the dispatch queue
                self.dispatchQueue.resume()
            }
            alert.addAction(okAction)
            // pause the alert dispatch queue 
            self.dispatchQueue.suspend()

            // can't access the UIApplication.keyWindow property on a background thread
            DispatchQueue.main.async {
                if let vc = UIApplication.shared.keyWindow?.rootViewController {
                    // we have a view controller to show it on
                    if !vc.show(alert: alert) {
                        // if now alert was shown, resume the dispatch queue
                        self.dispatchQueue.resume()
                    }
                } else {
                    // can't show it now, try again in two seconds
                    self.dispatchQueue.asyncAfter(deadline: .now() + 2.0) {
                        self.log(message: message, at: fileLocation, with: data, at: logLevel)
                    }
                    self.dispatchQueue.resume()
                }
            }
        }
    }
}

#endif
