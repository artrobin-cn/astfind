import AppKit

/// 合影参考图的多脸选择条：点击候选脸切换主脸并重新查询。
final class FacePickerBar: FlippedView {
    var onSelect: ((Int) -> Void)?
    private let label = Theme.label(11, .regular, .secondaryLabelColor)
    private let stack = NSStackView()
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.stringValue = L10n.text("image.personChooseFace")
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        addSubview(label)
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func localize() {
        label.stringValue = L10n.text("image.personChooseFace")
    }

    func configure(previews: [NSImage], selected: Int) {
        for button in buttons { stack.removeArrangedSubview(button); button.removeFromSuperview() }
        buttons = previews.enumerated().map { index, image in
            let button = NSButton()
            button.isBordered = false
            button.image = image
            button.imageScaling = .scaleProportionallyUpOrDown
            button.tag = index
            button.target = self
            button.action = #selector(pick(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = index == selected ? 2 : 1
            button.layer?.borderColor = (index == selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            button.setAccessibilityLabel("参考人脸 \(index + 1)")
            button.toolTip = "参考人脸 \(index + 1)"
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 36),
                button.heightAnchor.constraint(equalToConstant: 36)
            ])
            stack.addArrangedSubview(button)
            return button
        }
        isHidden = previews.count < 2
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: (bounds.height - 18) / 2, width: 96, height: 18)
        let width = CGFloat(buttons.count) * 36 + CGFloat(max(0, buttons.count - 1)) * 8 + 4
        stack.frame = NSRect(x: 118, y: (bounds.height - 36) / 2, width: width, height: 36)
    }

    @objc private func pick(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}
