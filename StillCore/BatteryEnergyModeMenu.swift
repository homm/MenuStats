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

    @objc private func selectEnergyMode(_ sender: NSMenuItem) {}

    @objc private func openBatterySettings(_ sender: NSMenuItem) {
        openBatterySettings?()
    }

    private enum EnergyModeTag {
        static let automatic = 1
        static let powerSave = 2
    }
}
