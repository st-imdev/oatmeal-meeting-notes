import Foundation

enum ProgressReporter {
    /// Print a progress bar to stderr using \r to overwrite the line.
    static func report(fraction: Double, message: String) {
        let width = 30
        let filled = Int(fraction * Double(width))
        let empty = width - filled
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        let percent = Int(fraction * 100)
        let line = "\r[\(bar)] \(percent)%  \(message)"
        FileHandle.standardError.write(Data(line.utf8))

        if fraction >= 1.0 {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
