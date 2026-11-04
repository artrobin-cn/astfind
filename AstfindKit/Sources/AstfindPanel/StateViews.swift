import AppKit
import OilFindCore

final class StateView: FlippedView {
    enum State { case empty, indexing }
    let state: State
    private var diagnostic: QueryDiagnostic?
    private var hasNoAccess = false
    private(set) var count = 0
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = Theme.label(14, .medium, .secondaryLabelColor)
    private let noAccess = Theme.label(12, .regular, .secondaryLabelColor)
    let grant = NSButton(title: L10n.text("empty.grant"), target: nil, action: nil)
    private let body = Theme.label(12, .regular, .tertiaryLabelColor)
    init(_ state: State) {
        self.state = state
        super.init(frame: .zero); wantsLayer = true
        titleLabel.alignment = .center; body.alignment = .center
        [icon, spinner, titleLabel, body, noAccess, grant].forEach(addSubview)
        noAccess.stringValue = L10n.text("empty.noAccess"); noAccess.alignment = .center
        grant.target = self; grant.action = #selector(grantAccess); grant.bezelStyle = .rounded
        noAccess.isHidden = true; grant.isHidden = true
        body.maximumNumberOfLines = 2
        spinner.style = .spinning; spinner.controlSize = .regular
        icon.isHidden = state == .indexing; spinner.isHidden = state != .indexing
        switch state {
        case .empty:
            icon.image = Theme.symbol("magnifyingglass", size: 34, weight: .light); icon.contentTintColor = .tertiaryLabelColor
            titleLabel.stringValue = L10n.text("empty.title"); body.stringValue = L10n.text("empty.body")
        case .indexing:
            titleLabel.stringValue = L10n.text("indexing.title"); updateCount(0); spinner.startAnimation(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func grantAccess() { Permissions.openSettings() }
    func configure(diagnostic: QueryDiagnostic?, hasNoAccess: Bool) {
        self.diagnostic = diagnostic; self.hasNoAccess = hasNoAccess
        titleLabel.stringValue = L10n.text(diagnostic == nil ? "empty.title" : "diag.title")
        body.stringValue = diagnostic.map(L10n.diagnostic) ?? L10n.text("empty.body")
        noAccess.isHidden = !hasNoAccess; grant.isHidden = !hasNoAccess; needsLayout = true
    }
    func updateCount(_ count: Int) { self.count = count; body.stringValue = L10n.text("indexing.body", Presentation.countText(count)) }
    func localize() {
        noAccess.stringValue = L10n.text("empty.noAccess"); grant.title = L10n.text("empty.grant")
        switch state {
        case .empty: configure(diagnostic: diagnostic, hasNoAccess: hasNoAccess)
        case .indexing: titleLabel.stringValue = L10n.text("indexing.title"); updateCount(count)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let iconSize: CGFloat = state == .indexing ? 32 : 34
        let total = iconSize + 14 + 20 + 6 + 36 + (grant.isHidden ? 0 : 64)
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        spinner.frame = icon.frame; y += iconSize + 14
        titleLabel.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 20); y += 26
        body.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 36)
        noAccess.frame = NSRect(x: 24, y: y + 40, width: bounds.width - 48, height: 18)
        grant.frame = NSRect(x: (bounds.width - 150) / 2, y: y + 64, width: 150, height: 28)
    }
}

/// 以图搜图的空态/分析中/不可用/失败态：与文件搜索结果区共用同一块区域。
final class ImageStateView: FlippedView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = Theme.label(14, .medium, .secondaryLabelColor)
    private let body = Theme.label(12, .regular, .tertiaryLabelColor)
    private let action = NSButton(title: "", target: nil, action: nil)
    private var phase: ImageQueryPhase = .idle
    var personMode = false { didSet { if personMode != oldValue { apply() } } }
    var onChooseImage: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    init() {
        super.init(frame: .zero); wantsLayer = true
        titleLabel.alignment = .center; body.alignment = .center; body.maximumNumberOfLines = 2
        spinner.style = .spinning; spinner.controlSize = .regular
        action.bezelStyle = .rounded; action.target = self; action.action = #selector(performAction)
        [icon, spinner, titleLabel, body, action].forEach(addSubview)
        icon.contentTintColor = .tertiaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ phase: ImageQueryPhase) {
        self.phase = phase
        apply()
    }
    func localize() { apply() }

    private func apply() {
        let analyzing: Bool
        let showAction: Bool
        switch phase {
        case .analyzing:
            analyzing = true; showAction = false
            titleLabel.stringValue = personMode ? L10n.text("image.personAnalyzing.title") : L10n.text("image.analyzing.title")
            body.stringValue = personMode ? L10n.text("image.personAnalyzing.body") : L10n.text("image.analyzing.body")
        case .ready:
            analyzing = false; showAction = true
            icon.image = Theme.symbol(personMode ? "person.crop.circle.badge.questionmark" : "photo.on.rectangle.angled",
                                      size: 32, weight: .light)
            titleLabel.stringValue = personMode ? L10n.text("image.personEmpty.title") : L10n.text("image.empty.title")
            body.stringValue = personMode ? L10n.text("image.personEmpty.body") : L10n.text("image.empty.body")
            action.title = personMode ? L10n.text("image.personChooseAnother") : L10n.text("image.chooseAnother")
        case .unavailable(let reason):
            analyzing = false; showAction = true
            icon.image = Theme.symbol("exclamationmark.triangle", size: 30, weight: .light)
            titleLabel.stringValue = L10n.text("image.unavailable.title")
            body.stringValue = reason
            action.title = L10n.text("image.openSettings")
        case .failed(let reason):
            analyzing = false; showAction = true
            icon.image = Theme.symbol("exclamationmark.triangle", size: 30, weight: .light)
            titleLabel.stringValue = L10n.text("image.failed.title")
            body.stringValue = reason
            action.title = L10n.text("image.chooseAnother")
        case .idle:
            analyzing = false; showAction = false
            titleLabel.stringValue = ""; body.stringValue = ""
        }
        icon.isHidden = analyzing
        spinner.isHidden = !analyzing
        if analyzing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        action.isHidden = !showAction
        body.isHidden = phase == .idle
        needsLayout = true
    }

    @objc private func performAction() {
        switch phase {
        case .unavailable: onOpenSettings?()
        default: onChooseImage?()
        }
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 34
        let buttonHeight: CGFloat = action.isHidden ? 0 : 28
        let total = iconSize + 14 + 20 + 6 + 36 + (action.isHidden ? 0 : 12 + buttonHeight)
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        spinner.frame = icon.frame; y += iconSize + 14
        titleLabel.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 20); y += 26
        body.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 36); y += 42
        action.frame = NSRect(x: (bounds.width - 180) / 2, y: y, width: 180, height: buttonHeight)
    }
}
