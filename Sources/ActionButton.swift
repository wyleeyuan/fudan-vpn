import AppKit

/// 自绘按钮：圆角背景 + 居中文案，带 hover 与禁用态。
///
/// 用自绘而非 NSButton，是为了完全控制外观，不受系统按钮样式随版本变化的影响。
final class ActionButton: NSView {

    var onClick: (() -> Void)?

    private var title: String = ""
    private var hovering = false
    private let label = NSTextField(labelWithString: "")

    var isEnabled: Bool = true {
        didSet {
            needsDisplay = true
            refreshText()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        addSubview(label)
    }

    func setTitle(_ text: String) {
        title = text
        refreshText()
        needsDisplay = true
    }

    private func refreshText() {
        label.stringValue = title
        label.textColor = isEnabled ? .white : NSColor.white.withAlphaComponent(0.66)
        label.frame = NSRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17)
    }

    override func layout() {
        super.layout()
        refreshText()
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let base = isEnabled ? accent : accent.withAlphaComponent(0.32)
        let fill: NSColor
        if hovering && isEnabled {
            fill = base.blended(withFraction: 0.10, of: .white) ?? base
        } else {
            fill = base
        }

        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshText()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshText()
    }
}
