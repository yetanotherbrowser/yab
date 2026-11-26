import SwiftUI
import UIKit
import WebKit

/// An actual failed native navigation, retained only in its live tab.
struct PageLoadFailure: Equatable, Sendable {
    enum Kind: String, Sendable { case offline, connection, timeout, secureConnection, address, navigation, process, authentication }
    let id: UUID
    let url: URL?
    let kind: Kind
    let previousURL: URL?

    init(url: URL?, previousURL: URL? = nil, error: NSError) {
        id = UUID(); self.url = url; self.previousURL = previousURL
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet: kind = .offline
            case NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost: kind = .connection
            case NSURLErrorTimedOut: kind = .timeout
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired: kind = .secureConnection
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorBadURL, NSURLErrorUnsupportedURL: kind = .address
            default: kind = .navigation
            }
        } else { kind = .navigation }
    }

    init(processURL: URL?) { id = UUID(); url = processURL; kind = .process; previousURL = nil }

    init(authenticationURL: URL, previousURL: URL?) {
        id = UUID(); url = authenticationURL; kind = .authentication; self.previousURL = previousURL
    }

    /// What happened, in a person's words; the site is said on its own row.
    var title: String {
        switch kind {
        case .offline: "You're offline"
        case .connection, .timeout: "Not answering"
        case .secureConnection: "Can't connect securely"
        case .address: "Can't find this site"
        case .navigation: "Can't open page"
        case .process: "Page stopped"
        case .authentication: "Sign-in cancelled"
        }
    }
    var site: String {
        guard let url, let host = url.host else { return "This webpage" }
        return host + (url.port.map { ":\($0)" } ?? "")
    }
    var explanation: String {
        switch kind {
        case .offline: "\(site) will open when this \(DeviceWord.name) is back online."
        case .connection: "\(site) didn't respond. It may be down for a moment."
        case .timeout: "\(site) took too long to respond. Try again."
        case .secureConnection: "A secure connection to this website couldn't be established."
        case .address: "This website's address couldn't be reached. Check the address or try again."
        case .navigation: "This webpage couldn't finish loading. Try again or go back."
        case .process: "The webpage stopped responding. Try again or go back."
        case .authentication: "Website sign-in was cancelled. Try again to sign in or go back."
        }
    }
}

/// The WebKit callback is consumed once, including every cancellation path.
@MainActor
final class PageJavaScriptDialog {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let tab: Tab.ID
    weak var webView: WKWebView?
    let document: UUID
    let url: URL?
    let store: ObjectIdentifier
    let privateSession: UUID?
    let controller: UIAlertController
    private var completion: (@MainActor (String?) -> Void)?

    init(tab: Tab.ID, webView: WKWebView, document: UUID, privateSession: UUID?,
         site: String, message: String, kind: Kind, defaultText: String?, completion: @escaping @MainActor (String?) -> Void) {
        self.tab = tab; self.webView = webView; self.document = document
        url = webView.url; store = ObjectIdentifier(webView.configuration.websiteDataStore)
        self.privateSession = privateSession; self.completion = completion
        controller = UIAlertController(title: site, message: message, preferredStyle: .alert)
        if kind == .prompt {
            controller.addTextField { field in
                field.text = defaultText
                field.accessibilityLabel = "Website response"
                field.accessibilityIdentifier = "page.javascript.input"
            }
        }
    }

    func resolve(_ value: String?, animated: Bool) {
        guard let completion else { return }
        self.completion = nil
        // Complete after native dismissal so a page's next dialog can appear.
        if controller.presentingViewController != nil {
            controller.dismiss(animated: animated) { completion(value) }
        } else { completion(value) }
    }
}

/// The actual error pane covers the whole page area, so the page a failed
/// navigation started from never shows under the bars. Its words keep to the
/// page's hardware/chrome viewport (`insets`) and sit at its foot, in reach of
/// the thumb, over the toolbar (variant D of the 2026-10-13 concepts). Back is
/// the toolbar's: the pane has no second one.
struct PageLoadFailureView: View {
    let failure: PageLoadFailure
    var isPrivate = false
    var insets = EdgeInsets()
    let retry: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Favicon(icon: failure.url?.host() ?? "globe", host: failure.url?.host(), size: 30,
                                url: failure.url, isPrivate: isPrivate)
                        Text(failure.site).font(.subheadline)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    .padding(.bottom, 10)
                    .accessibilityElement(children: .combine)
                    Text(failure.title).font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("page.error.title")
                        .accessibilityAddTraits(.isHeader)
                    Text(failure.explanation).font(.body)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("page.error.reason")
                    Button(action: retry) {
                        Text("Retry").font(.body.weight(.semibold))
                        .foregroundStyle(Ink.surface)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Ink.primary, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(failure.url == nil)
                    .opacity(failure.url == nil ? 0.4 : 1)
                    .padding(.top, 18)
                    .accessibilityIdentifier("page.error.retry")
                }
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity,
                       minHeight: max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom),
                       alignment: .bottomLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaPadding(insets)
        .background(Ink.surface.ignoresSafeArea())
    }
}
