import Combine
import SwiftUI
import UIKit
import WebKit

/// The chat of a `HephonAgentController`, with a spinner while it loads and a retry when it
/// cannot. Presented, it is a sheet at full height with a grabber:
///
///     presenter.present(HephonAgentViewController(controller: controller), animated: true)
///
/// Dismissing it (or removing it from its parent) hides the chat when `preload()` was called on
/// the controller, so the next open is immediate. Otherwise it disposes the controller.
@MainActor
public final class HephonAgentViewController: UIViewController {
    public let controller: HephonAgentController

    private let loading = UIActivityIndicatorView(style: .large)
    private let failed = UIStackView()
    private var state: AnyCancellable?
    private weak var webView: WKWebView?

    public init(controller: HephonAgentController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            // The chat scrolls inside the sheet instead of dragging it.
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported; use init(controller:)")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let overlay = UIView()
        overlay.backgroundColor = .systemBackground
        fill(overlay)
        loading.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(loading)
        buildFailure(in: overlay)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        state = controller.$pageState.sink { [weak self, weak overlay] state in
            overlay?.isHidden = state == .loaded
            self?.failed.isHidden = state != .failed
            if state == .loading {
                self?.loading.startAnimating()
            } else {
                self?.loading.stopAnimating()
            }
        }
    }

    /// The open is timed from here. The web view is the controller's: it may have been loaded
    /// ahead of this view, and a released chat comes back in a new one.
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.viewShown(by: self, at: Date())
        let webView = controller.webView()
        guard webView.superview !== view else {
            return
        }
        self.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        fill(webView, at: 0)
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true
            || (controller.kept && isInsideAViewThatIsGoing)
        {
            leave()
        }
    }

    /// A container this view is in (your own wrapper, a navigation or tab bar controller, at
    /// any depth) is dismissed or removed, as opposed to covered. Only a kept chat asks: it
    /// outlives the view, so it has to hear that it is hidden. In 1.0.0 a chat in such a
    /// container was not disposed there, and still is not.
    private var isInsideAViewThatIsGoing: Bool {
        var ancestor = parent
        while let container = ancestor {
            if container.isBeingDismissed || container.isMovingFromParent {
                return true
            }
            ancestor = container.parent
        }
        return false
    }

    /// The view is gone. A kept chat stays loaded in its web view, outside any window.
    fileprivate func leave() {
        controller.viewDismissed(by: self)
        if webView?.superview === view {
            webView?.removeFromSuperview()
        }
    }

    private func fill(_ child: UIView, at index: Int? = nil) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(child, at: index ?? view.subviews.count)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func buildFailure(in overlay: UIView) {
        let title = UILabel()
        title.text = "The assistant couldn't open"
        title.font = .preferredFont(forTextStyle: .headline)
        let detail = UILabel()
        detail.text = "Check your connection and try again."
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        for label in [title, detail] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        let retry = UIButton(type: .system)
        retry.setTitle("Try again", for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.addAction(UIAction { [weak self] _ in self?.controller.reload() }, for: .primaryActionTriggered)

        failed.axis = .vertical
        failed.alignment = .center
        failed.spacing = 8
        failed.setCustomSpacing(16, after: detail)
        [title, detail, retry].forEach(failed.addArrangedSubview)
        failed.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(failed)
        NSLayoutConstraint.activate([
            failed.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            failed.leadingAnchor.constraint(equalTo: overlay.layoutMarginsGuide.leadingAnchor),
            failed.trailingAnchor.constraint(equalTo: overlay.layoutMarginsGuide.trailingAnchor),
        ])
    }
}

/// `HephonAgentViewController` in SwiftUI, for a `.sheet` or a screen of its own:
///
///     .sheet(isPresented: $open) { HephonAgentView(controller: controller) }
///
/// Leaving the view hides the chat when `preload()` was called on the controller, and disposes
/// the controller otherwise.
public struct HephonAgentView: UIViewControllerRepresentable {
    public let controller: HephonAgentController

    public init(controller: HephonAgentController) {
        self.controller = controller
    }

    public func makeUIViewController(context _: Context) -> HephonAgentViewController {
        HephonAgentViewController(controller: controller)
    }

    public func updateUIViewController(_: HephonAgentViewController, context _: Context) {}

    public static func dismantleUIViewController(_ viewController: HephonAgentViewController, coordinator _: Void) {
        viewController.leave()
    }
}
