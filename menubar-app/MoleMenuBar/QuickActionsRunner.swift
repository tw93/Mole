import Foundation
import AppKit

class QuickActionsRunner {
    static let shared = QuickActionsRunner()

    private init() {}

    func runCommand(_ command: String) {
        // Ensure all operations happen on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Find the mole installation path
            let molePath = self.findMolePath()

            if molePath.isEmpty {
                self.showAlert(title: "Mole Not Found", message: "Could not locate the mole installation. Please ensure mole is installed.")
                return
            }

            // Open Terminal and run the command
            self.openInTerminal(command: command, molePath: molePath)
        }
    }

    private func findMolePath() -> String {
        // Check common installation paths
        let possiblePaths = [
            "/usr/local/bin/mo",
            "/opt/homebrew/bin/mo",
            NSHomeDirectory() + "/.local/bin/mo",
            // Also check for mole
            "/usr/local/bin/mole",
            "/opt/homebrew/bin/mole",
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try to find it using 'which' command
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["mo"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            print("Failed to find mo using which: \(error)")
        }

        return ""
    }

    private func openInTerminal(command: String, molePath: String) {
        // Create an AppleScript to open Terminal and run the command
        // Escape the command properly to prevent issues
        let escapedPath = molePath.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedPath)"
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                scriptObject.executeAndReturnError(&error)
                if let error = error {
                    print("AppleScript error: \(error)")
                    DispatchQueue.main.async {
                        self?.showAlert(title: "Failed to Launch Terminal", message: "Could not open Terminal to run command: \(error)")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self?.showAlert(title: "Failed to Launch Terminal", message: "Could not create AppleScript.")
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
