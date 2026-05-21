import SwiftUI

#if os(iOS)
import UIKit

/// Monospace journal panel — one native text view instead of hundreds of SwiftUI `Text` rows.
struct DiagnosticsJournalTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = UIColor(Demar.Color.label)
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let pinTop = view.contentOffset.y <= view.adjustedContentInset.top + 1
        view.text = text
        if pinTop {
            view.setContentOffset(
                CGPoint(x: 0, y: -view.adjustedContentInset.top),
                animated: false
            )
        }
    }
}

#elseif os(macOS)
import AppKit

struct DiagnosticsJournalTextView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(Demar.Color.label)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        guard textView.string != text else { return }
        let pinTop = scroll.contentView.bounds.origin.y <= 1
        textView.string = text
        textView.sizeToFit()
        if pinTop {
            scroll.contentView.scroll(to: .zero)
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }
}
#endif
