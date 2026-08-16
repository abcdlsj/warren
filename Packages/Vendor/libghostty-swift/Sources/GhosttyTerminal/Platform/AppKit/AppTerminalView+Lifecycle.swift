//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override open func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override open var acceptsFirstResponder: Bool {
            true
        }

        override open func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                focusDidBecomeFirstResponder()
                // First-responder ownership and key-window status are separate.
                // Preserve the binding intent in a non-key window, but keep the
                // Ghostty cursor visually inactive until didBecomeKey.
                core.setFocus(window?.isKeyWindow == true)
                onFocusChange?(true)
            }
            return result
        }

        override open func resignFirstResponder() -> Bool {
            let focusWindow = window
            let wasIntended = focusBinding?.isFocused == true
            let result = super.resignFirstResponder()
            if result {
                core.setFocus(false)
                focusDidResignFirstResponder(
                    from: focusWindow,
                    wasIntended: wasIntended
                )
            }
            return result
        }

        override open func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            if window != nil {
                // SwiftUI/AppKit can temporarily detach and reattach the terminal view while
                // diffing the view hierarchy. Rebuilding on every reattach discards Ghostty's
                // scrollback/state, so only create a new surface when one does not already exist.
                if surface == nil {
                    core.rebuildIfReady()
                } else {
                    core.synchronizeMetrics()
                }
                updateMetalLayerMetrics()
                updateColorScheme()
                core.startDisplayLink()
                core.requestImmediateTick()
                if focusBinding?.isFocused == true {
                    requestFocusMove()
                }

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                // Cross-display rescue: AppKit posts didChangeScreen when the
                // window's screen reference changes, even when the new screen
                // has the same backingScaleFactor (in which case
                // viewDidChangeBackingProperties does not fire). Listening
                // here lets us re-run metric sync on every screen transition
                // — required for the case where two displays share scale but
                // differ in geometry / color profile, and harmless when
                // viewDidChangeBackingProperties also fires for the
                // different-scale case.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
            } else {
                core.stopDisplayLink()
                core.setFocus(false)
            }
        }

        @objc func windowDidBecomeKey(_: Notification) {
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
            if !focused,
               focusBinding?.isFocused == true,
               let window,
               window.firstResponder == nil || window.firstResponder === window {
                requestFocusMove()
            }
        }

        @objc func windowDidResignKey(_: Notification) {
            // Key-window status and first-responder ownership are different axes.
            // Dim the cursor to its unfocused (hollow) state via the core — but do
            // NOT write "unfocused" back through the SwiftUI focus binding. The view
            // is still first responder; only the window went non-key. Reporting a
            // focus loss here clears the host's `@FocusState`, and if any host
            // re-render then runs `synchronizeFocus` while the window is non-key, it
            // strips first-responder status for real (`makeFirstResponder(nil)`) — so
            // on reactivation the cursor stays hollow until the user clicks. Ghostty's
            // own macOS app keeps window-key status as separate state for exactly this
            // reason; we mirror that by leaving the binding untouched on key loss.
            core.setFocus(false)
        }

        @objc func windowDidChangeScreen(_: Notification) {
            // Defer one runloop tick so AppKit's layout pass and the
            // window's new backingScaleFactor have both settled before we
            // re-derive metrics. Calling synchronously can race with the
            // layout pass and re-introduce the drift we're trying to fix.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateMetalLayerMetrics()
                core.synchronizeMetrics()
                core.requestImmediateTick()
            }
        }

        private func removeWindowObservers() {
            // Remove any existing key-window observers before registering for the
            // current window. AppKit can move the view directly between windows
            // without an intermediate nil attachment.
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: nil
            )
        }

        override open func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            core.fitToSize()
            core.requestImmediateTick()
        }

        override open func layout() {
            super.layout()
            core.fitToSize()
            core.requestImmediateTick()
            // A SwiftUI/AppKit host can leave this view at an intermediate frame
            // after an *animated or programmatic* grow (window zoom, sidebar
            // toggle): the last `layout()` we get carries mid-animation bounds and
            // no further pass arrives, so the surface stays sized to the stale,
            // smaller width and the content is boxed into a corner of the window.
            // Re-derive metrics one runloop later — by then the host's frame has
            // settled — so the final size is always captured. Coalesced so a burst
            // of layout passes schedules a single catch-up.
            scheduleSettleResync()
        }

        override open func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            // AppKit guarantees the frame is final here, so an interactive
            // window/split drag that ended between layout passes still lands at
            // the true size (the drag-out-to-grow case).
            core.fitToSize()
            core.requestImmediateTick()
        }

        /// Re-fit after the host layout settles. Fires twice, mirroring Muxy's
        /// resize hardening (`GhosttyTerminalNSView.updateMetalLayerSize`): once
        /// on the next runloop turn — covers a normal grow whose final frame
        /// lands immediately after this pass — and once ~120ms later, which
        /// covers an *animated* settle (sidebar toggle, fullscreen, window zoom)
        /// whose final frame arrives mid-animation and would otherwise leave the
        /// grid boxed at the stale width. Each leg is coalesced independently so
        /// a burst of layout passes schedules a single catch-up per leg.
        private func scheduleSettleResync() {
            if !settleResyncScheduled {
                settleResyncScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    settleResyncScheduled = false
                    resyncAfterLayoutSettle()
                }
            }
            settleResyncLateWorkItem?.cancel()
            let late = DispatchWorkItem { [weak self] in self?.resyncAfterLayoutSettle() }
            settleResyncLateWorkItem = late
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: late)
        }

        /// Flush any pending layout so the view's `bounds` are the settled size —
        /// the way Muxy calls `layoutSubtreeIfNeeded()` before reading its backing
        /// size — then re-derive the grid metrics and paint. This runs off the
        /// layout pass (a later runloop turn), so forcing layout here is safe and
        /// guarantees `viewSize()` never measures a half-applied intermediate frame.
        private func resyncAfterLayoutSettle() {
            layoutSubtreeIfNeeded()
            core.fitToSize()
            core.requestImmediateTick()
        }

        override open func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateMetalLayerMetrics()
            core.fitToSize()
            core.requestImmediateTick()
        }

        public func fitToSize() {
            core.fitToSize()
        }

        func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.sanitizedScaleFactor()
            // Write to the actually-attached backing layer (not just the
            // cached `metalLayer` ivar). The render pipeline can swap
            // `self.layer` to an IOSurfaceLayer for IOSurface-backed
            // compositing; once that happens the cached CAMetalLayer
            // reference is detached from the view tree and writes to its
            // contentsScale are no-ops as far as what's visible. The
            // observable symptom is text rendered at half size after the
            // window crosses to a display with a different
            // backingScaleFactor.
            layer?.contentsScale = scale
            if let metal = layer as? CAMetalLayer {
                metal.drawableSize = CGSize(
                    width: bounds.width * scale,
                    height: bounds.height * scale
                )
            }
            // Mirror to the cached ivar in case anything else still
            // reads through it during a transitional layout pass.
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        func enforceMetalLayerScale() {
            let scale = core.sanitizedScaleFactor()
            if let layer, layer.contentsScale != scale {
                layer.contentsScale = scale
            }
            if let metalLayer, metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
            }
        }

        /// macOS counterpart of `UITerminalView.detachOrphanedSurfaceLayers`,
        /// run on every surface teardown via `onSurfaceLayersOrphaned`. On
        /// macOS ghostty installs its renderer by *replacing* the backing
        /// layer with an IOSurfaceLayer (sublayers are the iOS shape), and
        /// `ghostty_surface_free` leaves that layer attached, frozen on its
        /// last frame. Restoring the view's own CAMetalLayer detaches the
        /// orphan; sublayers are left alone — any here belong to consumers.
        func detachOrphanedSurfaceLayers() {
            if let metalLayer, let layer, layer !== metalLayer {
                layer.delegate = nil
                self.layer = metalLayer
                updateMetalLayerMetrics()
            }
        }

        override open func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            if let controller,
               let viewState = delegate as? TerminalViewState,
               viewState.controller === controller
            {
                // viewDidMoveToWindow / viewDidChangeEffectiveAppearance can
                // run inside a SwiftUI update. adopt() publishes objectWillChange
                // synchronously, so defer it one main-actor hop like the other
                // TerminalViewState delegate writes.
                Task { @MainActor [weak viewState] in
                    viewState?.adopt(terminalColorScheme: scheme)
                }
            } else {
                controller?.setColorScheme(scheme)
            }
        }
    }
#endif
