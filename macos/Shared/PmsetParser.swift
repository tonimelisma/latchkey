import Foundation

enum PmsetParser {
    /// Reads SleepDisabled from `pmset -g` output. pmset omits the line when it was never set.
    static func sleepDisabled(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }
}
