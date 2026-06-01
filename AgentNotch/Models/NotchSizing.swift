// NotchSizing.swift
// Sizing constants and helpers for the notch UI

import SwiftUI

// MARK: - Fixed Sizes

/// Shadow padding around the window
let shadowPadding: CGFloat = 12

/// Extra bottom spacing to allow the closed-state glow to render fully
let closedNotchGlowPadding: CGFloat = 12

/// Open notch content size. Keep the closed notch compact, but leave enough
/// room for tool rows, usage, context, and footer content to remain readable.
let openNotchSize: CGSize = .init(width: 440, height: 320)

/// Window size (includes shadow padding)
let windowSize: CGSize = .init(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)

/// Corner radius for open/closed states
let cornerRadiusInsets = (
    opened: (top: CGFloat(12), bottom: CGFloat(14)),
    closed: (top: CGFloat(4), bottom: CGFloat(8))
)

// MARK: - Dynamic Sizing

/// Get the closed notch size for a screen
@MainActor
func getClosedNotchSize(screen: NSScreen? = nil) -> CGSize {
    let selectedScreen = screen ?? NSScreen.main

    var notchHeight: CGFloat = 32
    var notchWidth: CGFloat = 185

    if let screen = selectedScreen {
        // Calculate notch width from auxiliary areas
        if let topLeftPadding = screen.auxiliaryTopLeftArea?.width,
           let topRightPadding = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - topLeftPadding - topRightPadding + 4
        }

        // Get height from safe area or menu bar
        if screen.safeAreaInsets.top > 0 {
            // Mac with notch
            notchHeight = screen.safeAreaInsets.top
        } else {
            // Mac without notch - use menu bar height
            notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            if notchHeight < 24 { notchHeight = 32 }
        }
    }

    let compactWidth = min(112, max(92, notchWidth * 0.5))
    let compactHeight = min(24, max(20, (notchHeight + 2) * 0.65))
    return CGSize(width: compactWidth, height: compactHeight)
}

/// Get the screen frame
@MainActor
func getScreenFrame(_ screen: NSScreen? = nil) -> CGRect? {
    let selectedScreen = screen ?? NSScreen.main
    return selectedScreen?.frame
}
