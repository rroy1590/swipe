import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var viewModel: KeyboardViewModel?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

        let vm = KeyboardViewModel(
            proxyProvider: { [weak self] in self?.textDocumentProxy },
            nextInputModeHandler: { [weak self] in self?.advanceToNextInputMode() },
            openURLHandler: { [weak self] url in self?.openHostApp(url: url) }
        )
        self.viewModel = vm

        let rootView = KeyboardRootView(viewModel: vm)
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        let desiredHeight: CGFloat = 272
        let constraint = view.heightAnchor.constraint(equalToConstant: desiredHeight)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        self.heightConstraint = constraint

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        self.hostingController = hosting
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncHostContext()
        viewModel?.onAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel?.onDisappear()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncHostContext()
        viewModel?.refreshAutoShift()
    }

    private func syncHostContext() {
        viewModel?.hasFullAccess = hasFullAccess
        viewModel?.needsInputModeSwitchKey = needsInputModeSwitchKey
    }

    /// Launches the containing host app via its registered `swipe://` custom URL scheme
    /// when a cold-start handoff is needed to arm the microphone session.
    /// Uses dynamic selector lookup so the extension compiles cleanly under
    /// `APPLICATION_EXTENSION_API_ONLY = YES`.
    private func openHostApp(url: URL) {
        var responder: UIResponder? = self
        let openSelector = sel_registerName("openURL:options:completionHandler:")

        while let current = responder {
            if current.responds(to: openSelector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                if let impl = class_getMethodImplementation(type(of: current), openSelector) {
                    let function = unsafeBitCast(impl, to: OpenFunction.self)
                    function(current, openSelector, url as NSURL, [:], nil)
                    return
                }
            }
            responder = current.next
        }
    }
}
