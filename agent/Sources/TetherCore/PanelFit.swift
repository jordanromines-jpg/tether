import Foundation

/// How tall the menu-bar status panel may be, so it always fits below the menu bar.
/// The panel grows with each connected device, activity entry and passkey; past this height its middle scrolls.
public enum PanelFit {
    /// Space kept free below the menu bar (for the popover arrow) and above the screen's bottom edge.
    public static let screenMargin: Double = 24
    /// The scrolling middle never gets shorter than this, even on a very small screen.
    public static let minBodyHeight: Double = 120

    /// Tallest the whole panel may be on a screen whose usable height (menu bar and Dock excluded) is `visibleHeight`.
    public static func maxPanelHeight(visibleHeight: Double) -> Double {
        max(0, visibleHeight - screenMargin)
    }

    /// Tallest the scrolling middle may be, once the header and footer (which never scroll) have their room.
    public static func maxBodyHeight(maxPanelHeight: Double, header: Double, footer: Double) -> Double {
        max(minBodyHeight, maxPanelHeight - header - footer)
    }
}
