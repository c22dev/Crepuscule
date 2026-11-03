// Crepuscule - SystemCodeAction.swift
// Constantin Clerc (c22dev) - 0.1
// uses the private BarcodeSupport framework for system code actions (not app store safe)
import Foundation
import ObjectiveC
import UIKit

@objc private protocol BCSQRCodeParserAPI: NSObjectProtocol {
    @objc(parseCodeFromString:completionHandler:)
    func parseCode(fromString string: String, completionHandler: @escaping (AnyObject?, NSError?) -> Void)
}

@objc private protocol BCSActionAPI: NSObjectProtocol {
    @objc func performAction()
    @objc optional func showActionPicker()
}

@MainActor
final class SystemCodeAction {
    let raw: String
    let title: String
    let subtitle: String?
    let systemImage: String?
    private let action: NSObject
    private let presenter = Presenter()

    private init?(raw: String, action: NSObject) {
        func string(_ key: String) -> String? {
            guard action.responds(to: NSSelectorFromString(key)) else { return nil }
            return (action.value(forKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if action.responds(to: NSSelectorFromString("isInvalidDataAction")), (action.value(forKey: "isInvalidDataAction") as? Bool) == true { return nil }
        guard let title = string("localizedDefaultActionTitle") ?? string("shortDescription") else { return nil }
        self.raw = raw
        self.action = action
        self.title = title
        let detail = string("localizedDefaultActionDescription") ?? string("contentPreviewString")
        self.subtitle = detail == title ? nil : detail
        self.systemImage = string("actionIconSystemImageName").flatMap { UIImage(systemName: $0) == nil ? nil : $0 }
        if action.responds(to: NSSelectorFromString("setDelegate:")) { action.setValue(presenter, forKey: "delegate") }
    }

    var hasMoreOptions: Bool {
        guard action.responds(to: NSSelectorFromString("showActionPicker")), action.responds(to: NSSelectorFromString("actionPickerItems")) else { return false }
        return ((action.value(forKey: "actionPickerItems") as? [Any])?.count ?? 0) > 1
    }

    private static var active: SystemCodeAction?

    func perform() {
        Self.active = self
        unsafeBitCast(action, to: BCSActionAPI.self).performAction()
    }

    func showOptions() {
        Self.active = self
        unsafeBitCast(action, to: BCSActionAPI.self).showActionPicker?()
    }

    private static let parser: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/BarcodeSupport.framework/BarcodeSupport", RTLD_NOW)
        guard let cls = NSClassFromString("BCSQRCodeParser") as? NSObject.Type else { return nil }
        let shared = NSSelectorFromString("sharedParser")
        let parser = cls.responds(to: shared) ? cls.perform(shared)?.takeUnretainedValue() as? NSObject : nil
        guard let parser, parser.responds(to: NSSelectorFromString("parseCodeFromString:completionHandler:")) else { return nil }
        return parser
    }()

    static var isAvailable: Bool { parser != nil }

    static func resolve(_ raw: String, completion: @escaping @MainActor (SystemCodeAction?) -> Void) {
        guard let parser else { return completion(nil) }
        unsafeBitCast(parser, to: BCSQRCodeParserAPI.self).parseCode(fromString: raw) { action, _ in
            let box = UncheckedBox(value: action as? NSObject)
            Task { @MainActor in completion(box.value.flatMap { SystemCodeAction(raw: raw, action: $0) }) }
        }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

private final class Presenter: NSObject {
    @objc(presentingViewControllerForAction:)
    func presentingViewController(for action: Any?) -> UIViewController? { Self.top() }

    @objc(presentingViewForAction:)
    func presentingView(for action: Any?) -> UIView? { Self.top()?.view }

    @objc(sourceRectForPopoverActionPicker:)
    func sourceRect(for picker: Any?) -> CGRect {
        guard let view = Self.top()?.view else { return .zero }
        return CGRect(x: view.bounds.midX, y: view.bounds.maxY - 140, width: 1, height: 1)
    }

    @objc(actionPickerItemsForAction:proposedItems:)
    func actionPickerItems(for action: Any?, proposedItems items: Any?) -> Any? { items }

    @objc(actionDidUpdateTitle:)
    func actionDidUpdateTitle(_ title: Any?) {}

    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }
}
