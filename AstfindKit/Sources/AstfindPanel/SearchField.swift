import AppKit
import QuartzCore

final class SearchEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PassiveProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SearchField: FlippedView, NSTextFieldDelegate {
    let input = NSTextField()
    let editor = SearchEditor()
    private let glass = NSImageView()
    private let clear = NSButton()
    private let imageButton = NSButton()
    private let personButton = NSButton()
    private let progress = PassiveProgressIndicator()
    private let chip = NSView()
    private let chipImage = NSImageView()
    private let chipClose = NSButton()
    var placeholder: String? { didSet { if placeholder != oldValue { localize() } } }
    private var selectionObserver: NSObjectProtocol?
    private var clearVisible = false, progressVisible = false
    var onSelectionChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onPickImage: (() -> Void)?
    var onPickPerson: (() -> Void)?
    var onClearImage: (() -> Void)?
    /// 图片入口可见性由语义模型能力决定（不可用时隐藏，不留死控件）。
    var imageEntryVisible = false { didSet { if imageEntryVisible != oldValue { updateAccessory(); needsLayout = true } } }
    /// 人物入口由全局开关 + 模型就绪决定。
    var personEntryVisible = false { didSet { if personEntryVisible != oldValue { updateAccessory(); needsLayout = true } } }
    var imagePreview: NSImage? { didSet { if imagePreview !== oldValue { updateImageChip() } } }
    /// 当前参考图是否来自“找人”入口；只影响占位文案。
    var personPreview = false { didSet { if personPreview != oldValue { applyPlaceholder() } } }
    var indexing = false { didSet { updateAccessory() } }
    var text: String {
        get { input.stringValue }
        set { input.stringValue = newValue; updateAccessory() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.image = Theme.symbol("magnifyingglass", size: 19, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        input.font = .systemFont(ofSize: 21); input.textColor = .labelColor
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.cell?.isScrollable = true; input.cell?.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.delegate = self
        editor.isFieldEditor = true
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in self?.onSelectionChange?() }
        editor.handleKey = { [weak self] event in self?.onKey?(event) ?? false }
        clear.isBordered = false; clear.image = Theme.symbol("xmark.circle.fill", size: 15, weight: .regular)
        clear.contentTintColor = .tertiaryLabelColor; clear.target = self; clear.action = #selector(clearText)
        imageButton.isBordered = false
        imageButton.image = Self.imageSearchIcon()
        imageButton.contentTintColor = .secondaryLabelColor; imageButton.imageScaling = .scaleProportionallyDown
        imageButton.target = self; imageButton.action = #selector(pickImage); imageButton.isHidden = true
        imageButton.setAccessibilityLabel(L10n.text("image.pick"))
        personButton.isBordered = false
        personButton.image = Theme.symbol("person.crop.circle", size: 19, weight: .regular)
        personButton.contentTintColor = .secondaryLabelColor; personButton.imageScaling = .scaleProportionallyDown
        personButton.target = self; personButton.action = #selector(pickPerson); personButton.isHidden = true
        personButton.setAccessibilityLabel(L10n.text("image.personPick"))
        chip.wantsLayer = true; chip.layer?.cornerRadius = 6; chip.layer?.cornerCurve = .continuous
        chip.layer?.masksToBounds = true; chip.layer?.borderWidth = 0.5
        chipImage.imageScaling = .scaleProportionallyUpOrDown
        chipClose.isBordered = false; chipClose.image = Theme.symbol("xmark.circle.fill", size: 12, weight: .regular)
        chipClose.contentTintColor = .secondaryLabelColor
        chipClose.target = self; chipClose.action = #selector(clearImage)
        chip.addSubview(chipImage); chip.addSubview(chipClose); chip.isHidden = true
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        [clear, progress].forEach { $0.wantsLayer = true; $0.alphaValue = 0 }
        [glass, input, clear, progress, imageButton, personButton, chip].forEach(addSubview)
        applyPlaceholder()
        updateAccessory()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func localize() {
        applyPlaceholder()
        imageButton.toolTip = L10n.text("image.pick")
        personButton.toolTip = L10n.text("image.personPick")
        chipClose.toolTip = L10n.text("image.clear")
    }
    private func applyPlaceholder() {
        let value = personPreview ? L10n.text("placeholder.person")
            : (imagePreview != nil ? L10n.text("placeholder.image") : (placeholder ?? L10n.text("placeholder")))
        input.placeholderAttributedString = NSAttributedString(string: value, attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chip.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func layout() {
        super.layout()
        let showImage = imageButtonVisible
        let showPerson = personButtonVisible
        let rightInset: CGFloat = (showImage && showPerson) ? 108 : ((showImage || showPerson) ? 84 : 54)
        if imagePreview != nil {
            chip.frame = NSRect(x: 14, y: (bounds.height - 40) / 2, width: 40, height: 40)
            chipImage.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            chipClose.frame = NSRect(x: 26, y: 0, width: 14, height: 14)
            input.frame = NSRect(x: 64, y: (bounds.height - 29) / 2, width: max(0, bounds.width - 118), height: 29)
        } else {
            glass.frame = NSRect(x: 24, y: (bounds.height - 22) / 2, width: 22, height: 22)
            input.frame = NSRect(x: 58, y: (bounds.height - 29) / 2, width: max(0, bounds.width - 58 - rightInset), height: 29)
        }
        clear.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 16) / 2, width: 16, height: 16)
        progress.frame = clear.frame
        var accessoryX = bounds.width - 70
        if showImage {
            imageButton.frame = NSRect(x: accessoryX, y: (bounds.height - 20) / 2, width: 20, height: 20)
            accessoryX -= 24
        }
        if showPerson {
            personButton.frame = NSRect(x: accessoryX, y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
    }
    func focus(selectAll: Bool = false) {
        window?.makeFirstResponder(input)
        if selectAll { input.selectText(nil) }
    }
    deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
    func controlTextDidEndEditing(_ obj: Notification) { onSelectionChange?() }
    func controlTextDidChange(_ obj: Notification) { updateAccessory(); onChange?() }
    @objc private func clearText() { text = ""; focus(); onChange?() }
    @objc private func pickImage() { onPickImage?() }
    @objc private func pickPerson() { onPickPerson?() }
    @objc private func clearImage() { onClearImage?() }
    private var imageButtonVisible: Bool { imageEntryVisible && imagePreview == nil && !indexing }
    private var personButtonVisible: Bool { personEntryVisible && imagePreview == nil && !indexing }
    private func updateImageChip() {
        let active = imagePreview != nil
        chip.isHidden = !active
        chipImage.image = imagePreview
        glass.isHidden = active
        applyPlaceholder()
        updateAccessory()
        needsLayout = true
    }
    private func accessory(_ view: NSView, visible: Bool) {
        let animate = window?.isVisible == true
        view.isHidden = false
        Theme.Motion.opacity(view, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        if let layer = view.layer {
            let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
            Theme.Motion.animate(layer, "transform.scale", to: visible ? 1 : Theme.Motion.accessoryScale, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        }
    }
    private func updateAccessory() {
        let showClear = !indexing && !text.isEmpty
        if clearVisible != showClear { clearVisible = showClear; accessory(clear, visible: showClear) }
        clear.isEnabled = showClear
        if progressVisible != indexing {
            progressVisible = indexing
            if indexing { progress.startAnimation(nil) }
            accessory(progress, visible: indexing)
            if !indexing {
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self] in
                    if self?.indexing == false { self?.progress.stopAnimation(nil) }
                }
            }
        }
        let showImage = imageButtonVisible
        if imageButton.isHidden == showImage {
            imageButton.isHidden = !showImage; imageButton.isEnabled = showImage
            imageButton.alphaValue = showImage ? 1 : 0
            needsLayout = true
        }
        let showPerson = personButtonVisible
        if personButton.isHidden == showPerson {
            personButton.isHidden = !showPerson; personButton.isEnabled = showPerson
            personButton.alphaValue = showPerson ? 1 : 0
            needsLayout = true
        }
    }

    /// 品牌化的以图搜图图标：照片卡在后、镜片在前（与 App 图标同构），细线模板。
    private static func imageSearchIcon() -> NSImage {
        let size: CGFloat = 19
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size / 18.0
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            NSColor.black.setStroke(); NSColor.black.setFill()
            let line: CGFloat = 1.15 * s

            let card = rect(0.9, 7.2, 8.8, 8.8)
            let cardPath = NSBezierPath(roundedRect: card, xRadius: 2.1 * s, yRadius: 2.1 * s)
            cardPath.lineWidth = line; cardPath.stroke()
            NSBezierPath(ovalIn: rect(2.9, 12.2, 1.7, 1.7)).fill()
            let mountain = NSBezierPath()
            mountain.move(to: point(2.1, 8.8))
            mountain.line(to: point(5.1, 11.8))
            mountain.line(to: point(6.8, 10.2))
            mountain.line(to: point(8.9, 12.8))
            mountain.lineWidth = line * 0.85; mountain.stroke()

            let center = point(11.9, 6.4), radius = 5.6 * s
            let lensRect = NSRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
            let handleStart = point(15.86, 2.44), handleEnd = point(17.8, 0.3)
            NSGraphicsContext.current?.compositingOperation = .clear
            let knockout = NSBezierPath(ovalIn: lensRect.insetBy(dx: -1.25 * s, dy: -1.25 * s))
            knockout.lineWidth = 2.9 * s; knockout.stroke()
            let handleKnockout = NSBezierPath()
            handleKnockout.move(to: handleStart); handleKnockout.line(to: handleEnd)
            handleKnockout.lineWidth = 3.9 * s; handleKnockout.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let lens = NSBezierPath(ovalIn: lensRect); lens.lineWidth = line * 1.05; lens.stroke()
            let handle = NSBezierPath()
            handle.move(to: handleStart); handle.line(to: handleEnd)
            handle.lineWidth = line * 1.05; handle.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
