import AppKit
import SwiftUI

struct BatteryEnergyModeMenuAnchor: NSViewRepresentable {
    var controller: BatteryEnergyModeMenuController
    var batteryState: BatteryRuntimeState
    var openBatterySettings: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.anchorView = nsView
        controller.batteryState = batteryState
        controller.openBatterySettings = openBatterySettings
    }
}

@MainActor
final class BatteryEnergyModeMenuController: NSObject {
    weak var anchorView: NSView?
    var batteryState: BatteryRuntimeState?
    var openBatterySettings: (() -> Void)?
    private let popUpCell: NSPopUpButtonCell = {
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        cell.altersStateOfSelectedItem = false
        cell.arrowPosition = .noArrow
        cell.isBordered = false
        cell.isBezeled = false
        return cell
    }()

    func showMenu() {
        guard let anchorView, let batteryState else { return }
        let menu = menu(for: batteryState)
        let selectedItem = menu.item(
            withTag: batteryState.batteryStatus.powerSaveMode ? EnergyModeTag.powerSave : EnergyModeTag.automatic
        )
        popUpCell.menu = menu
        popUpCell.select(selectedItem)
        // Compensate the SwiftUI button layout so the popup cell frame matches the visible battery label.
        let cellFrame = anchorView.bounds.offsetBy(dx: 2, dy: 3)
        popUpCell.performClick(withFrame: cellFrame, in: anchorView)
    }

    private func menu(for batteryState: BatteryRuntimeState) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Energy Mode"))
        menu.addItem(makeEnergyModeItem(
            title: "Automatic", state: batteryState, powerSaveMode: false, tag: EnergyModeTag.automatic
        ))
        menu.addItem(makeEnergyModeItem(
            title: "Power Save", state: batteryState, powerSaveMode: true, tag: EnergyModeTag.powerSave
        ))
        menu.addItem(.separator())
        let batterySettingsItem = NSMenuItem(
            title: "Battery Settings...",
            action: #selector(openBatterySettings(_:)),
            keyEquivalent: ""
        )
        batterySettingsItem.target = self
        menu.addItem(batterySettingsItem)
        return menu
    }

    private func makeEnergyModeItem(
        title: String,
        state: BatteryRuntimeState,
        powerSaveMode: Bool,
        tag: Int
    ) -> NSMenuItem {
        var menuState = state
        menuState.batteryStatus.powerSaveMode = powerSaveMode
        let item = NSMenuItem(title: title, action: #selector(selectEnergyMode(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = .off
        item.image = BatteryIndicatorImage.make(state: menuState, usesSecondaryMask: false)
        return item
    }

    @objc private func selectEnergyMode(_ sender: NSMenuItem) {
        guard let batteryState else { return }

        let lowPowerMode: String
        switch sender.tag {
        case EnergyModeTag.automatic:
            lowPowerMode = "0"
        case EnergyModeTag.powerSave:
            lowPowerMode = "1"
        default:
            return
        }

        let powerSource = batteryState.batteryStatus.isOnACPower ? "-c" : "-b"
        let command = EnergyModeCommand(arguments: [powerSource, "lowpowermode", lowPowerMode])

        Task {
            let result = await Self.runEnergyModeCommand(command)
            if result.isSudoPermissionFailure {
                if showSudoersAlert() {
                    let installResult = await Self.runSudoersInstallScript(sudoersInstallScript())
                    if installResult.isSuccess {
                        let retryResult = await Self.runEnergyModeCommand(command)
                        if !retryResult.isSuccess {
                            showCommandFailureAlert(
                                title: "Energy Mode update failed",
                                command: retryResult.command.displayText,
                                output: retryResult.output
                            )
                        }
                    } else if !installResult.isUserCancelled {
                        showCommandFailureAlert(
                            title: "Permission setup failed",
                            command: sudoersInstallCommand(),
                            output: installResult.output
                        )
                    }
                }
            } else if !result.isSuccess {
                showCommandFailureAlert(
                    title: "Energy Mode update failed",
                    command: result.command.displayText,
                    output: result.output
                )
            }
        }
    }

    @objc private func openBatterySettings(_ sender: NSMenuItem) {
        openBatterySettings?()
    }

    private enum EnergyModeTag {
        static let automatic = 1
        static let powerSave = 2
    }

    private struct EnergyModeCommand: Sendable {
        let arguments: [String]

        var displayText: String {
            (["/usr/bin/sudo", "-n", "/usr/bin/pmset"] + arguments).joined(separator: " ")
        }
    }

    private struct EnergyModeCommandResult: Sendable {
        let command: EnergyModeCommand
        let exitCode: Int32
        let output: String

        var isSuccess: Bool {
            exitCode == 0
        }

        var isSudoPermissionFailure: Bool {
            exitCode == 1 && output.hasPrefix("sudo: ")
        }
    }

    private struct SudoersInstallResult: Sendable {
        let exitCode: Int32
        let output: String

        var isSuccess: Bool {
            exitCode == 0
        }

        var isUserCancelled: Bool {
            exitCode == 1 && output.contains("(-128)")
        }
    }

    private nonisolated static func runEnergyModeCommand(
        _ command: EnergyModeCommand
    ) async -> EnergyModeCommandResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/usr/bin/pmset"] + command.arguments
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let result = EnergyModeCommandResult(
                    command: command,
                    exitCode: process.terminationStatus,
                    output: output
                )
                if result.isSuccess {
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return result
                    }
                    await MainActor.run {
                        BatteryTrackerService.shared.refreshRuntimeState()
                    }
                }
                return result
            } catch {
                return EnergyModeCommandResult(
                    command: command,
                    exitCode: -1,
                    output: error.localizedDescription
                )
            }
        }.value
    }

    private nonisolated static func runSudoersInstallScript(
        _ script: String
    ) async -> SudoersInstallResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"\(script)\" with administrator privileges",
            ]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return SudoersInstallResult(exitCode: process.terminationStatus, output: output)
            } catch {
                return SudoersInstallResult(exitCode: -1, output: error.localizedDescription)
            }
        }.value
    }

    private func showSudoersAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "StillCore needs permission to change Energy Mode"
        alert.informativeText = "Run this command in Terminal once:"
        alert.accessoryView = makeCommandAccessoryView(command: sudoersInstallCommand())
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Set Up Automatically")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showCommandFailureAlert(title: String, command: String, output: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
        Command:
        \(command)

        Output:
        \(output.isEmpty ? "No output." : output)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func sudoersInstallCommand() -> String {
        "sudo sh -c \"\(sudoersInstallScript())\""
    }

    private func sudoersInstallScript() -> String {
        let sudoersLine = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -[bc] lowpowermode [01]"
        return "echo '\(sudoersLine)' > /etc/sudoers.d/stillcore-energy-mode && chmod 440 /etc/sudoers.d/stillcore-energy-mode"
    }

    private func makeCommandAccessoryView(command: String) -> NSView {
        let width: CGFloat = 320
        let textField = SelectingCommandTextField(wrappingLabelWithString: command)

        textField.frame.size.width = width
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.alignment = .left
        textField.drawsBackground = true
        textField.isSelectable = true
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.usesSingleLineMode = false
        textField.frame.size.height = ceil(textField.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        )).height ?? 100)

        return textField
    }

}

private final class SelectingCommandTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else {
            return false
        }

        if let editor = currentEditor() {
            editor.perform(#selector(NSText.selectAll(_:)), with: self, afterDelay: 0.0)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        currentEditor()?.selectAll(nil)
    }
}
