import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
@Suite(.serialized)
struct StatusIconTests {
    typealias Look = StatusIconView.Look

    /// Every look the icon can show, with a representative visual.
    static let allVisuals: [(String, StatusVisual)] = [
        ("Needs input", StatusVisual(activity: .needsInput, unread: false, agent: .claude)),
        ("Error", StatusVisual(activity: .error, unread: true, agent: .shell)),
        ("Done, unread", StatusVisual(activity: .done, unread: true, agent: .claude)),
        ("Working", StatusVisual(activity: .working, unread: false, agent: .opencode)),
        ("Done", StatusVisual(activity: .done, unread: false, agent: .claude)),
        ("Exited", StatusVisual(activity: .exited, unread: false, agent: .shell)),
        ("Idle · shell", StatusVisual(activity: .idle, unread: false, agent: .shell)),
        ("Idle · Claude", StatusVisual(activity: .idle, unread: false, agent: .claude)),
        ("Idle · OpenCode", StatusVisual(activity: .idle, unread: false, agent: .opencode)),
        ("Idle · PI", StatusVisual(activity: .idle, unread: false, agent: .pi)),
        ("Closed (quiet)", StatusVisual(activity: .idle, unread: false, agent: .claude, quiet: true)),
    ]

    /// Runs `body` with motion switched on/off and Reduce Motion set, restoring the globals afterwards.
    func withMotion(enabled: Bool, reduced: Bool = false, _ body: () throws -> Void) rethrows {
        let (wasEnabled, wasReduced) = (Motion.enabled, Motion.reduced)
        Motion.enabled = enabled
        if Motion.reduced != reduced { Motion.setReduced(reduced) }
        defer {
            Motion.enabled = wasEnabled
            if Motion.reduced != wasReduced { Motion.setReduced(wasReduced) }
        }
        try body()
    }

    /// Loops need a visible window; this one is never ordered in, so `onScreen` stands in for visibility.
    func hosted(_ slot: CGFloat = 16, onScreen: Bool = true) -> (StatusIconView, NSWindow) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let v = StatusIconView(slot: slot)
        v.forceOnScreen = onScreen
        w.contentView?.addSubview(v)
        return (v, w)
    }

    /// An animated change under a fresh session, so the flap guard of earlier steps never interferes:
    /// the re-seed keeps the current look (no-op) and only starts a new history.
    func step(_ v: StatusIconView, to visual: StatusVisual) {
        let id = UUID()
        if let current = v.visual { v.apply(current, session: id, animated: false) }
        v.apply(visual, session: id, animated: true)
    }

    func haloAlpha(_ v: StatusIconView) -> CGFloat { v.halo.backgroundColor?.alpha ?? -1 }

    func keys(_ l: CALayer) -> Set<String> { Set(l.animationKeys() ?? []) }

    func loops(_ v: StatusIconView) -> Set<String> {
        keys(v.arc).intersection([StatusIconView.spinKey]).union(keys(v.halo).intersection([StatusIconView.pingKey]))
    }

    func visibleParts(_ v: StatusIconView) -> StatusIconView.Parts {
        var p: StatusIconView.Parts = []
        if !v.halo.isHidden { p.insert(.halo) }
        if !v.track.isHidden && !v.arc.isHidden { p.insert(.ring) }
        if !v.disc.isHidden { p.insert(.disc) }
        if !v.glyph.isHidden { p.insert(.glyph) }
        return p
    }

    // MARK: API compatibility

    @Test func legacyShimLabelsAndSizes() {
        let v = StatusIconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        for a in [Activity.idle, .working, .needsInput, .done, .error, .exited] {
            for unread in [false, true] {
                for agent in AgentKind.allCases {
                    v.update(activity: a, unread: unread, agent: agent)
                }
            }
        }
        let labels: [(Activity, Bool, String)] = [
            (.needsInput, true, "Needs input"), (.working, false, "Working"), (.done, true, "Done, unread"),
            (.done, false, "Done"), (.error, false, "Error"), (.exited, false, "Exited"), (.idle, false, "Idle"),
        ]
        for (a, unread, label) in labels {
            v.update(activity: a, unread: unread, agent: .claude)
            #expect(v.accessibilityLabel() == label)
        }
        v.layout()
        v.viewDidChangeEffectiveAppearance()
        #expect(v.isAccessibilityElement(), "VoiceOver must see the label")
        #expect(v.accessibilityRole() == .image)
        #expect(v.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(StatusIconView().slot == 16)
        #expect(StatusIconView().intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(StatusIconView(slot: 14).intrinsicContentSize == NSSize(width: 14, height: 14))
        #expect(StatusIconView(frame: NSRect(x: 0, y: 0, width: 14, height: 14)).slot == 14)
        #expect(StatusIconView(frame: .zero).slot == 16)
    }

    @Test func staticHelpersStayCompatible() {
        for agent in AgentKind.allCases {
            #expect(StatusIconView.agentSymbol(agent) == GlyphCache.agentSymbol(agent))
        }
        #expect(StatusIconView.style(activity: .needsInput, unread: false, agent: .claude).0 == "questionmark.bubble.fill")
        #expect(StatusIconView.style(activity: .needsInput, unread: false, agent: .claude).1 == Theme.tokens.status.needsInput.fill)
        #expect(StatusIconView.style(activity: .working, unread: false, agent: .claude).2 == "Working")
        #expect(StatusIconView.style(activity: .done, unread: true, agent: .claude).2 == "Done, unread")
        #expect(StatusIconView.style(activity: .done, unread: false, agent: .claude).0 == "checkmark")
        #expect(StatusIconView.style(activity: .error, unread: false, agent: .claude).0 == "exclamationmark.triangle.fill")
        #expect(StatusIconView.style(activity: .exited, unread: false, agent: .claude).2 == "Exited")
        #expect(StatusIconView.style(activity: .idle, unread: false, agent: .pi).0 == GlyphCache.agentSymbol(.pi))
    }

    // MARK: States

    @Test func everyStateRendersInEverySlot() {
        withMotion(enabled: false) {
            for slot: CGFloat in [16, 14, 28] {
                let (v, w) = hosted(slot)
                defer { w.close() }
                v.frame = NSRect(x: 4, y: 4, width: slot, height: slot)
                v.layoutSubtreeIfNeeded()
                #expect(v.intrinsicContentSize == NSSize(width: slot, height: slot))
                #expect(v.stage.bounds.size == CGSize(width: slot, height: slot))
                #expect(v.stage.position == CGPoint(x: slot / 2, y: slot / 2))
                #expect(abs(v.halo.bounds.width - slot) < 0.01)
                #expect(abs(v.disc.bounds.width - 12 * slot / 16) < 0.01)
                #expect(v.glyph.bounds.width == StatusIconArt.canvas(slot))
                #expect(v.arc.contents != nil)
                #expect(v.showsHalo == (slot < 20), "preview tiles draw no halo")
                #expect(v.artScale == w.backingScaleFactor)
                for (name, visual) in Self.allVisuals {
                    v.apply(visual, session: UUID(), animated: false)
                    let look = Look(visual)
                    #expect(v.look == look, "\(name)")
                    #expect(v.visual == visual)
                    #expect(visibleParts(v) == v.parts(for: look), "\(name) @\(slot)")
                    #expect(v.accessibilityLabel() == look.label)
                    if look.parts.contains(.glyph) {
                        let img = v.glyph.contents.map { $0 as! CGImage }
                        let side = StatusIconArt.canvas(slot) * w.backingScaleFactor
                        #expect(img?.width == Int(side.rounded()), "\(name) @\(slot) glyph art")
                    }
                    #expect(loops(v).isEmpty, "motion off: no loops")
                }
            }
        }
    }

    @Test func needsInputHaloIsStaticWithoutMotion() {
        withMotion(enabled: false) {
            let v = StatusIconView()
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(v.halo.opacity == StatusIconView.staticHalo.opacity)
            #expect(abs(v.halo.transform.m11 - StatusIconView.staticHalo.scale) < 0.001)
            // Amber at α 0.40 under the layer opacity: the static halo is an effective 0.12 glow, not a coin.
            #expect(abs(haloAlpha(v) - 0.40) < 0.001)
            #expect(abs(haloAlpha(v) * CGFloat(v.halo.opacity) - 0.12) < 0.001)
            v.update(activity: .working, unread: false, agent: .claude)
            #expect(v.halo.isHidden)
            #expect(v.halo.opacity == 0)
        }
    }

    @Test func calmGlyphsFollowQuietAndSurface() {
        withMotion(enabled: false) {
            let v = StatusIconView()
            v.apply(StatusVisual(activity: .idle, unread: false, agent: .claude), session: nil, animated: false)
            let loud = v.glyph.contents.map { $0 as! CGImage }
            v.apply(StatusVisual(activity: .idle, unread: false, agent: .claude, quiet: true), session: nil, animated: false)
            let quiet = v.glyph.contents.map { $0 as! CGImage }
            #expect(loud != nil && quiet != nil)
            #expect(loud !== quiet, "quiet uses the quaternary color")
            v.apply(StatusVisual(activity: .done, unread: false, agent: .claude, quiet: true), session: nil, animated: false)
            #expect(v.look == .doneSeen(quiet: true))
            v.surface = .card
            #expect(v.glyph.contents != nil)
            // Same visual twice is a no-op.
            let before = v.glyph.contents.map { $0 as! CGImage }
            v.apply(StatusVisual(activity: .done, unread: false, agent: .claude, quiet: true), session: nil, animated: true)
            #expect(v.glyph.contents.map { $0 as! CGImage } === before)
        }
    }

    // MARK: Loops

    @Test func loopsRunOnlyForWorkingAndNeedsInput() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            for (name, visual) in Self.allVisuals {
                v.apply(visual, session: nil, animated: false)
                switch Look(visual) {
                case .working: #expect(loops(v) == [StatusIconView.spinKey], "\(name)")
                case .needsInput: #expect(loops(v) == [StatusIconView.pingKey], "\(name)")
                default: #expect(loops(v).isEmpty, "\(name)")
                }
            }
            v.update(activity: .working, unread: false, agent: .claude)
            let spin = v.arc.animation(forKey: StatusIconView.spinKey)
            #expect(spin?.repeatCount == .infinity)
            #expect(spin?.duration == StatusIconView.spinPeriod)
            #expect(spin?.isRemovedOnCompletion == false)
            #expect(spin?.preferredFrameRateRange.maximum == 30)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            let ping = v.halo.animation(forKey: StatusIconView.pingKey)
            #expect(ping?.duration == StatusIconView.pingPeriod)
            #expect(ping?.repeatCount == .infinity)
            #expect(v.halo.opacity == 0, "L2 drives the halo; model rests invisible")
        }
    }

    @Test func loopsNeedAWindowAndRearmOnMove() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            v.update(activity: .working, unread: false, agent: .claude)
            #expect(loops(v) == [StatusIconView.spinKey])
            v.removeFromSuperview()
            #expect(loops(v).isEmpty)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(loops(v).isEmpty, "detached views never loop")
            w.contentView?.addSubview(v)
            #expect(loops(v) == [StatusIconView.pingKey])
        }
    }

    @Test func loopsWaitUntilTheIconCanBeSeen() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted(onScreen: false)
            defer { w.close() }
            // A cell configured while its window is not visible (launch, occluded, app hidden) does not loop.
            v.update(activity: .working, unread: false, agent: .claude)
            #expect(!v.loopsAllowed)
            #expect(loops(v).isEmpty)
            // The shared occlusion observer re-syncs it; the window is still not visible here.
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            #expect(loops(v).isEmpty)
            v.forceOnScreen = true
            #expect(loops(v) == [StatusIconView.spinKey])
            // Once visible, an occlusion change re-arms a loop that went missing, for this window only.
            v.arc.removeAnimation(forKey: StatusIconView.spinKey)
            let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
            StatusIconView.occlusionChanged(nil)
            #expect(loops(v).isEmpty)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            #expect(loops(v) == [StatusIconView.spinKey])
            // Hidden directly or through an ancestor: no loop; unhidden: back.
            v.isHidden = true
            #expect(loops(v).isEmpty)
            v.isHidden = false
            #expect(loops(v) == [StatusIconView.spinKey])
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            w.contentView?.addSubview(box)
            box.addSubview(v)
            box.isHidden = true
            #expect(loops(v).isEmpty)
            box.isHidden = false
            #expect(loops(v) == [StatusIconView.spinKey])
            // Only looks that loop are tracked by the observer.
            let tracked = StatusIconView.looperCount
            v.update(activity: .idle, unread: false, agent: .claude)
            #expect(StatusIconView.looperCount == tracked - 1)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(StatusIconView.looperCount == tracked)
            v.prepareForReuse()
            #expect(StatusIconView.looperCount == tracked - 1)
        }
    }

    @Test func pausedLoopsAreRemovedAndRestored() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            v.update(activity: .working, unread: false, agent: .claude)
            v.setLoopsPaused(true)
            #expect(v.loopsPaused)
            #expect(loops(v).isEmpty)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(loops(v).isEmpty)
            v.setLoopsPaused(false)
            #expect(loops(v) == [StatusIconView.pingKey])
        }
    }

    @Test func reduceMotionUsesStaticForms() {
        withMotion(enabled: true, reduced: true) {
            let (v, w) = hosted()
            defer { w.close() }
            v.update(activity: .working, unread: false, agent: .claude)
            #expect(loops(v).isEmpty)
            #expect(!v.arc.isHidden && !v.track.isHidden, "static arc + track still read as in progress")
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(loops(v).isEmpty)
            #expect(v.halo.opacity == StatusIconView.staticHalo.opacity)
            // Turning Reduce Motion off live re-arms the ping.
            Motion.setReduced(false)
            #expect(loops(v) == [StatusIconView.pingKey])
            #expect(v.halo.opacity == 0)
            Motion.setReduced(true)
            #expect(loops(v).isEmpty)
        }
    }

    @Test func haloSuppressedKeepsAStaticHaloWithoutPing() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted(onScreen: false)
            defer { w.close() }
            v.haloSuppressed = true
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(loops(v).isEmpty)
            #expect(v.halo.opacity == StatusIconView.staticHalo.opacity)
            // Not visible: the change jumps (nothing to see) and L2 waits for the window.
            v.haloSuppressed = false
            #expect(!keys(v.halo).contains("settle"))
            #expect(loops(v).isEmpty)
            #expect(v.halo.opacity == 0)
            v.forceOnScreen = true
            #expect(loops(v) == [StatusIconView.pingKey])
            // On screen, the change settles instead of jumping, and the ping waits for the next period.
            v.haloSuppressed = true
            #expect(keys(v.halo).contains("settle"))
            #expect(loops(v).isEmpty)
            v.haloSuppressed = false
            #expect(keys(v.halo).contains(StatusIconView.pingKey))
            // Irrelevant outside needs input.
            v.update(activity: .working, unread: false, agent: .claude)
            v.haloSuppressed = true
            #expect(loops(v) == [StatusIconView.spinKey])
        }
    }

    @Test func previewTilesDrawNoHalo() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted(28)
            defer { w.close() }
            #expect(!v.showsHalo)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(v.halo.isHidden, "no second ping beside the sidebar row's")
            #expect(loops(v).isEmpty)
            #expect(!v.glyph.isHidden)
            v.haloSuppressed = true
            #expect(v.halo.isHidden && loops(v).isEmpty)
            v.haloSuppressed = false
            // The entrance pops but never bursts; leaving needs input never fades a halo.
            v.update(activity: .working, unread: false, agent: .claude)
            step(v, to: StatusVisual(activity: .needsInput, unread: false, agent: .claude))
            #expect(keys(v.stage).contains("pop"))
            #expect(keys(v.halo).isEmpty)
            #expect(v.halo.isHidden)
            step(v, to: StatusVisual(activity: .error, unread: false, agent: .claude))
            #expect(!keys(v.halo).contains("out"))
            #expect(!v.outgoing.contains(v.halo))
            // Opting in live shows the halo and starts L2; opting out again hides it.
            v.update(activity: .needsInput, unread: false, agent: .claude)
            v.showsHalo = true
            #expect(!v.halo.isHidden)
            #expect(loops(v) == [StatusIconView.pingKey])
            v.showsHalo = false
            #expect(v.halo.isHidden)
            #expect(loops(v).isEmpty)
            // Toggling while another look shows only changes the stored flag.
            v.update(activity: .done, unread: false, agent: .claude)
            v.showsHalo = true
            #expect(v.halo.isHidden)
            #expect(StatusIconView(slot: 16).showsHalo && StatusIconView(slot: 14).showsHalo)
        }
    }

    // MARK: Transitions

    @Test func animatesOnlyWhenEveryRuleHolds() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted(onScreen: false)
            defer { w.close() }
            let id = UUID()
            let idle = StatusVisual(activity: .idle, unread: false, agent: .claude)
            let working = StatusVisual(activity: .working, unread: false, agent: .claude)
            v.apply(idle, session: id, animated: true)
            #expect(keys(v.stage).isEmpty, "first apply snaps")
            // Not on screen (window never ordered in): snaps.
            v.apply(working, session: id, animated: true)
            #expect(!keys(v.stage).contains("pop"))
            #expect(v.lastTransitionAt == nil, "a snap is not a transition")
            v.forceOnScreen = true
            v.apply(idle, session: UUID(), animated: true)
            #expect(keys(v.stage).isEmpty, "another session snaps")
            v.apply(working, session: nil, animated: true)
            #expect(!keys(v.stage).contains("pop"), "no session snaps")
            v.apply(idle, session: id, animated: false)
            v.apply(working, session: id, animated: false)
            #expect(!keys(v.stage).contains("pop"), "unanimated snaps")
            v.apply(idle, session: id, animated: true)
            #expect(keys(v.stage).contains(kCATransition), "same session, on screen, changed → crossfade")
            step(v, to: working)
            #expect(keys(v.stage).contains("pop"))
            // Unread does not change the working look: nothing to do, the entrance keeps running.
            v.apply(StatusVisual(activity: .working, unread: true, agent: .claude), session: id, animated: true)
            #expect(keys(v.stage).contains("pop"))
            Motion.enabled = false
            step(v, to: idle)
            #expect(keys(v.stage).isEmpty, "motion off snaps")
        }
    }

    @Test func flappingBurstSnaps() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            let id = UUID()
            v.apply(StatusVisual(activity: .idle, unread: false, agent: .claude), session: id, animated: true)
            v.apply(StatusVisual(activity: .working, unread: false, agent: .claude), session: id, animated: true)
            #expect(keys(v.stage).contains("pop"))
            let first = v.lastTransitionAt
            #expect(first != nil)
            v.apply(StatusVisual(activity: .done, unread: true, agent: .claude), session: id, animated: true)
            #expect(keys(v.disc).isEmpty, "second change within 250 ms snaps")
            #expect(keys(v.stage).isEmpty)
            #expect(visibleParts(v) == .disc)
            #expect(v.lastTransitionAt! >= first!, "a flap extends the burst")
            // The history belongs to one session: another session starts clean.
            let next = UUID()
            v.apply(StatusVisual(activity: .working, unread: false, agent: .claude), session: next, animated: true)
            #expect(v.lastTransitionAt == nil)
            v.apply(StatusVisual(activity: .done, unread: true, agent: .claude), session: next, animated: true)
            #expect(keys(v.disc).contains("pop"), "a fresh session animates")
            // The time rule itself.
            #expect(!StatusIconView.isFlap(last: nil, now: 10))
            #expect(StatusIconView.isFlap(last: 9.9, now: 10))
            #expect(!StatusIconView.isFlap(last: 10 - StatusIconView.flapWindow, now: 10))
            #expect(!StatusIconView.isFlap(last: 8, now: 10), "after the window it animates again")
        }
    }

    @Test func transitionCatalog() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            @MainActor func go(_ a: Activity, unread: Bool = false, agent: AgentKind = .claude) {
                step(v, to: StatusVisual(activity: a, unread: unread, agent: agent))
            }
            v.update(activity: .idle, unread: false, agent: .claude)
            // M10: ring fades in, stage scales up; L1 starts.
            go(.working)
            #expect(keys(v.stage).contains("pop"))
            #expect(keys(v.track).contains("in") && keys(v.arc).contains("in"))
            #expect(keys(v.glyph).contains("out"), "idle glyph fades out")
            #expect(keys(v.arc).contains(StatusIconView.spinKey))
            #expect(v.outgoing == [v.glyph])
            // M11: arc out, disc pops, check draws on.
            go(.done, unread: true)
            #expect(keys(v.arc).contains("out") && keys(v.track).contains("out"))
            #expect(keys(v.disc).isSuperset(of: ["pop", "in"]))
            #expect(keys(v.check).contains("draw"))
            #expect(!keys(v.arc).contains(StatusIconView.spinKey))
            #expect(v.check.strokeEnd == 1, "model is final")
            // M15: disc settles into the quiet check.
            go(.done)
            #expect(keys(v.disc).isSuperset(of: ["shrink", "out"]))
            #expect(keys(v.glyph).contains("in"))
            // M12: pop + one burst; L2 waits for the next period boundary after the burst.
            go(.needsInput)
            #expect(keys(v.stage).contains("pop"))
            #expect(keys(v.halo).contains("burst"))
            #expect(v.halo.opacity == 0, "L2 drives the halo after the burst")
            let ping = v.halo.animation(forKey: StatusIconView.pingKey)
            #expect(ping != nil)
            if let ping {
                let begin = v.halo.convertTime(ping.beginTime, to: nil)
                #expect(begin >= CACurrentMediaTime() + 0.45)
                let phase = begin.truncatingRemainder(dividingBy: StatusIconView.pingPeriod)
                #expect(phase < 0.001 || StatusIconView.pingPeriod - phase < 0.001, "phase-synced start")
            }
            // M14 + M13: pop and shake; the halo fades out.
            go(.error)
            #expect(keys(v.stage).contains("pop"))
            #expect(keys(v.glyph).contains("shake"))
            #expect(keys(v.halo).contains("out"))
            #expect(!keys(v.halo).contains(StatusIconView.pingKey))
            // M16: calm states crossfade.
            go(.exited)
            #expect(keys(v.stage).contains(kCATransition))
            go(.idle, agent: .pi)
            #expect(keys(v.stage).contains(kCATransition))
            go(.done)
            #expect(keys(v.stage).contains(kCATransition), "done seen not coming from unread crossfades")
            // Needs input on a selected row grows into the static halo instead of bursting.
            v.haloSuppressed = true
            go(.needsInput)
            #expect(keys(v.halo).isSuperset(of: ["in", "in.scale"]))
            #expect(!keys(v.halo).contains("burst"))
            #expect(v.halo.opacity == StatusIconView.staticHalo.opacity)
        }
    }

    @Test func outgoingLayersHideWhenTheirFadeCompletes() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            let id = UUID()
            v.apply(StatusVisual(activity: .working, unread: false, agent: .claude), session: id, animated: false)
            v.apply(StatusVisual(activity: .needsInput, unread: false, agent: .claude), session: id, animated: true)
            #expect(!v.arc.isHidden, "fading out")
            #expect(v.arc.opacity == 0)
            // A stale completion (newer state took over) must not touch the layers.
            v.finishOutgoing(-1)
            #expect(!v.arc.isHidden)
            v.finishOutgoing(Int.max)
            #expect(!v.arc.isHidden)
            v.finishOutgoing(v.generation)
            #expect(v.arc.isHidden && v.track.isHidden)
            #expect(v.outgoing.isEmpty)
        }
    }

    @Test func reduceMotionCrossfadesInsteadOfPopping() {
        withMotion(enabled: true, reduced: true) {
            let (v, w) = hosted()
            defer { w.close() }
            v.update(activity: .idle, unread: false, agent: .claude)
            for a in [Activity.needsInput, .error, .working, .done] {
                step(v, to: StatusVisual(activity: a, unread: true, agent: .claude))
                #expect(keys(v.stage) == [kCATransition], "\(a)")
                #expect(loops(v).isEmpty)
                #expect(!keys(v.halo).contains("burst"))
            }
        }
    }

    @Test func prepareForReuseLeavesNoAnimations() {
        withMotion(enabled: true, reduced: false) {
            let (v, w) = hosted()
            defer { w.close() }
            let id = UUID()
            v.apply(StatusVisual(activity: .working, unread: false, agent: .claude), session: id, animated: false)
            v.apply(StatusVisual(activity: .needsInput, unread: false, agent: .claude), session: id, animated: true)
            #expect(!v.allLayers.flatMap { keys($0) }.isEmpty)
            v.prepareForReuse()
            for l in v.allLayers {
                #expect(l.animationKeys() == nil || l.animationKeys()!.isEmpty)
            }
            #expect(v.look == nil && v.visual == nil)
            #expect(v.lastTransitionAt == nil)
            #expect(v.arc.isHidden, "no half-faded layer left visible")
            #expect(CATransform3DIsIdentity(v.stage.transform))
            // Reused for another session: the first apply snaps even when animated.
            v.apply(StatusVisual(activity: .error, unread: false, agent: .claude), session: UUID(), animated: true)
            #expect(!keys(v.stage).contains("pop"))
            #expect(!keys(v.glyph).contains("shake"))
            // Reused for the same session id after reuse: still a fresh start (lastSession was cleared).
            v.prepareForReuse()
            v.apply(StatusVisual(activity: .working, unread: false, agent: .claude), session: id, animated: true)
            #expect(!keys(v.stage).contains("pop"))
            #expect(loops(v) == [StatusIconView.spinKey], "the new look re-arms its loop")
        }
    }

    // MARK: Theme, scale, art

    @Test func themeAndBackingChangesRebuildArt() {
        withMotion(enabled: false) {
            let (v, w) = hosted()
            defer { w.close() }
            v.update(activity: .error, unread: false, agent: .claude)
            v.glyph.contents = nil
            v.arc.contents = nil
            NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
            #expect(v.glyph.contents != nil)
            #expect(v.arc.contents != nil)
            v.glyph.contents = nil
            v.viewDidChangeBackingProperties()
            #expect(v.glyph.contents != nil)
            #expect(v.check.contentsScale == (w.backingScaleFactor))
            #expect(v.disc.backgroundColor == Theme.tokens.status.done.fill.cgColor)
            #expect(abs(haloAlpha(v) - StatusIconView.haloAlpha) < 0.001)
            // Per-view art: the same look again is the same bitmap; a theme change rebuilds it.
            v.update(activity: .needsInput, unread: false, agent: .claude)
            let bubble = v.glyph.contents.map { $0 as! CGImage }
            v.update(activity: .working, unread: false, agent: .claude)
            v.update(activity: .needsInput, unread: false, agent: .claude)
            #expect(v.glyph.contents.map { $0 as! CGImage } === bubble)
            // A detached icon renders at 2×; attaching it to a window renders at that window's scale.
            let loose = StatusIconView()
            loose.update(activity: .error, unread: false, agent: .claude)
            #expect(loose.artScale == 2)
            w.contentView?.addSubview(loose)
            #expect(loose.artScale == w.backingScaleFactor)
        }
    }

    @Test func artIsCachedAndInkCentered() {
        // A known shape: ink box comes back in y-up points.
        let ink = StatusIconArt.inkBounds(size: CGSize(width: 10, height: 10)) {
            NSColor.black.setFill()
            NSRect(x: 2, y: 1, width: 4, height: 3).fill()
        }
        #expect(abs(ink.minX - 2) < 0.3 && abs(ink.minY - 1) < 0.3)
        #expect(abs(ink.width - 4) < 0.3 && abs(ink.height - 3) < 0.3)
        let empty = StatusIconArt.inkBounds(size: CGSize(width: 5, height: 5)) {}
        #expect(empty == CGRect(x: 0, y: 0, width: 5, height: 5))

        let spec = StatusIconView.glyphSpec(.needsInput)!
        let colors = [NSColor.white, NSColor.orange]
        let a = StatusIconArt.glyph(spec, colors: colors, slot: 16, scale: 2)
        let b = StatusIconArt.glyph(spec, colors: colors, slot: 16, scale: 2)
        #expect(a != nil && a === b, "cache hit returns the same image")
        let side = StatusIconArt.canvas(16)
        #expect(side == 20)
        #expect(a?.width == 40 && a?.height == 40)
        // The bubble's ink is centered in the slot and fits the 16 × 15.5 box (the full slot width).
        if let a {
            let measured = StatusIconArt.inkBounds(size: CGSize(width: side, height: side)) {
                NSGraphicsContext.current?.cgContext.draw(a, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            #expect(abs(measured.midX - side / 2) <= 0.5 && abs(measured.midY - side / 2) <= 0.5, "\(measured)")
            #expect(measured.width <= spec.box.width + 0.5 && measured.height <= spec.box.height + 0.5, "\(measured)")
            #expect(measured.width >= spec.box.width - 0.75 || measured.height >= spec.box.height - 0.75, "\(measured)")
            #expect(measured.minX >= StatusIconArt.pad - 0.5, "antialiased edges stay inside the canvas")
        }
        let arc = StatusIconArt.arc(color: .systemBlue, slot: 14, scale: 2)
        #expect(arc?.width == 28)
        #expect(StatusIconArt.arc(color: .systemBlue, slot: 14, scale: 2) === arc)
        #expect(StatusIconView.glyphSpec(.working) == nil && StatusIconView.glyphSpec(.doneUnread) == nil)
        for agent in AgentKind.allCases {
            #expect(StatusIconArt.glyph(StatusIconView.glyphSpec(.idle(agent, quiet: false))!, colors: [.gray],
                                        slot: 14, scale: 2) != nil)
        }
        #expect(StatusIconArt.count > 0)
    }

    /// Ink extent of a look at `slot`, measured from art rendered at the 4× measuring scale, so the bitmap
    /// maps 1:1 and no resampling fringe widens it (y-up points on the canvas).
    func ink(_ look: Look, slot: CGFloat = 16) -> CGRect {
        let spec = StatusIconView.glyphSpec(look)!
        let side = StatusIconArt.canvas(slot)
        let image = StatusIconArt.glyph(spec, colors: [.black, .black], slot: slot, scale: 4)!
        return StatusIconArt.inkBounds(size: CGSize(width: side, height: side)) {
            NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    @Test func sizeFollowsRank() {
        // §1.3: needs input 16 > error 14 > disc = ring 12 > calm 9–11, at every row slot.
        for slot: CGFloat in [16, 14] {
            let k = slot / 16
            let bubble = ink(.needsInput, slot: slot).width, triangle = ink(.error, slot: slot).width
            #expect(bubble >= 15.75 * k, "bubble \(bubble) @\(slot) fills the slot width")
            #expect(triangle <= 14.25 * k && triangle >= 13.5 * k, "triangle \(triangle) @\(slot)")
            #expect(bubble - triangle >= 1.5 * k, "a clear step from needs input to error @\(slot)")
            var calm: [Look] = [.doneSeen(quiet: false), .exited]
            calm += AgentKind.allCases.map { Look.idle($0, quiet: false) }
            for look in calm {
                let w = ink(look, slot: slot).width
                #expect(w <= 11.25 * k, "\(look) \(w) @\(slot) stays under the 12 pt disc")
                #expect(w >= 8.5 * k, "\(look) \(w) @\(slot) stays legible")
            }
        }
    }
}

/// Opt-in gallery (CORRAL_SNAPSHOTS=<dir>): every state × slot 16/14 × plain / selected / attention /
/// attention+selected rows, plus the 28 pt preview tile, in the two reference themes. Rendered offscreen with
/// motion off, never visible. Needs-input rows show what a viewer sees live:
/// - "Needs input": unselected rows between L2 pings (no halo), selected rows with the static halo;
/// - "· ping": L2 frozen 0.25 s into its period (scale 1.48, layer opacity 0.34);
/// - "· RM": Reduce Motion, the static halo everywhere.
@MainActor
@Suite(.serialized)
struct StatusIconSnapshotTests {
    nonisolated static let dir = ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]

    final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    enum Background: String, CaseIterable {
        case plain, selected, attention, attentionSelected = "attn+sel"
        var isSelected: Bool { self == .selected || self == .attentionSelected }
    }

    enum Variant { case live, ping, reduced }

    static var rows: [(String, StatusVisual, Variant)] {
        var rows = StatusIconTests.allVisuals.map { ($0.0, $0.1, Variant.live) }
        let waiting = StatusVisual(activity: .needsInput, unread: false, agent: .claude)
        rows.insert(contentsOf: [("Needs input · ping", waiting, .ping), ("Needs input · RM", waiting, .reduced)], at: 1)
        return rows
    }

    static func label(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        l.sizeToFit()
        return l
    }

    /// Row pill as the sidebar draws it (§3.4 fill precedence), with the amber gutter on attention rows.
    static func pill(_ bg: Background, in root: NSView, frame: NSRect, rowH: CGFloat) -> NSView {
        let t = Theme.tokens
        let pill = Flipped(frame: frame)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.cornerCurve = .continuous
        switch bg {
        case .plain: break
        case .selected: pill.layer?.backgroundColor = t.ramp(.chrome).selected.cgColor
        case .attention, .attentionSelected:
            pill.layer?.backgroundColor = (bg == .attention ? t.status.wash : t.status.washSelected).cgColor
            pill.layer?.borderWidth = 1
            pill.layer?.borderColor = t.status.washBorder.cgColor
            let g = max(10, frame.height + 2 - 16)
            let gutter = NSView(frame: NSRect(x: frame.minX - 6, y: frame.midY - g / 2, width: 3, height: g))
            gutter.wantsLayer = true
            gutter.layer?.backgroundColor = t.status.needsInput.fill.cgColor
            gutter.layer?.cornerRadius = 1.5
            gutter.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            root.addSubview(gutter)
        }
        root.addSubview(pill)
        return pill
    }

    static func gallery() -> NSView {
        let t = Theme.tokens
        let r = t.ramp(.chrome)
        let rows = Self.rows
        let rowH: CGFloat = 48, colW: CGFloat = 164, labelW: CGFloat = 128, tileW: CGFloat = 84, m: CGFloat = 16, head: CGFloat = 26
        let slots: [CGFloat] = [16, 14]
        let width = m * 2 + labelW + colW * CGFloat(slots.count * Background.allCases.count) + tileW
        let height = m * 2 + head + rowH * CGFloat(rows.count)
        let root = Flipped(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = t.chrome.cgColor

        var x = m + labelW
        for slot in slots {
            for bg in Background.allCases {
                let h = label("\(bg.rawValue.uppercased()) \(Int(slot))", font: Fonts.section, color: r.tertiary)
                h.frame.origin = NSPoint(x: x + 6, y: m)
                root.addSubview(h)
                x += colW
            }
        }
        let tileHead = label("TILE 28", font: Fonts.section, color: r.tertiary)
        tileHead.frame.origin = NSPoint(x: x + 6, y: m)
        root.addSubview(tileHead)

        for (i, (name, visual, variant)) in rows.enumerated() {
            let y = m + head + CGFloat(i) * rowH
            let n = label(name, font: Fonts.monoSmall, color: r.secondary)
            n.frame.origin = NSPoint(x: m, y: y + (rowH - n.frame.height) / 2)
            root.addSubview(n)
            var x = m + labelW
            for slot in slots {
                for bg in Background.allCases {
                    let pillH: CGFloat = slot == 16 ? 36 : 24
                    let frame = NSRect(x: x + 6, y: y + (rowH - pillH) / 2, width: colW - 12, height: pillH)
                    let pill = Self.pill(bg, in: root, frame: frame, rowH: rowH)
                    let icon = StatusIconView(slot: slot)
                    icon.haloSuppressed = bg.isSelected
                    icon.frame = NSRect(x: 8, y: (pillH - slot) / 2, width: slot, height: slot)
                    pill.addSubview(icon)   // first subview: the halo sits under the label
                    icon.apply(visual, session: nil, animated: false)
                    if visual.activity == .needsInput, !bg.isSelected {
                        switch variant {
                        case .live: icon.showsHalo = false   // between pings
                        case .ping:
                            Motion.quiet {
                                icon.halo.opacity = 0.34
                                icon.halo.transform = CATransform3DMakeScale(1.48, 1.48, 1)
                            }
                        case .reduced: break   // motion off renders the static halo
                        }
                    }
                    let attention = visual.activity == .needsInput
                    let font = slot == 16 ? (attention ? Fonts.rowTitleStrong : (visual.unread ? Fonts.rowTitleMedium : Fonts.rowTitle))
                        : (attention ? Fonts.compactStrong : Fonts.compact)
                    let title = label(icon.accessibilityLabel() ?? "", font: font, color: visual.quiet ? r.secondary : r.primary)
                    title.frame.origin = NSPoint(x: 8 + slot + 8, y: (pillH - title.frame.height) / 2)
                    pill.addSubview(title)
                    x += colW
                }
            }
            // Preview tile on the card surface (no halo by default at 28).
            let card = Flipped(frame: NSRect(x: x + 8, y: y + 1, width: tileW - 16, height: rowH - 2))
            card.wantsLayer = true
            card.layer?.backgroundColor = t.card.cgColor
            card.layer?.cornerRadius = 6
            root.addSubview(card)
            let tile = Flipped(frame: NSRect(x: (card.frame.width - 44) / 2, y: (card.frame.height - 44) / 2, width: 44, height: 44))
            tile.wantsLayer = true
            tile.layer?.backgroundColor = t.ramp(.card).sunken.cgColor
            tile.layer?.borderColor = t.ramp(.card).hairline.cgColor
            tile.layer?.borderWidth = 1
            tile.layer?.cornerRadius = 10
            tile.layer?.cornerCurve = .continuous
            card.addSubview(tile)
            let big = StatusIconView(slot: 28)
            big.surface = .card
            big.frame = NSRect(x: 8, y: 8, width: 28, height: 28)
            tile.addSubview(big)
            big.apply(visual, session: nil, animated: false)
        }
        return root
    }

    @Test(.enabled(if: dir != nil)) func statusIconGallery() throws {
        let out = URL(fileURLWithPath: Self.dir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let wasEnabled = Motion.enabled
        Motion.enabled = false
        defer {
            Motion.enabled = wasEnabled
            Theme.update(background: nil, foreground: nil, windowTheme: nil)
        }
        for (name, bg, fg) in [("dark", 0x1E1E2E, 0xCDD6F4), ("light", 0xFDF6E3, 0x657B83)] as [(String, UInt32, UInt32)] {
            Theme.update(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: nil)
            let view = Self.gallery()
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = Theme.tokens.chromeAppearance
            window.contentView = view
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("status-icons-\(name).png"))
        }
    }
}

/// The icon's share of the status budget (< 1 ms per update): snaps and full transitions with a warm art
/// cache. Enforced under CORRAL_PERF (scripts/perf.sh, release, serial); printed otherwise.
@MainActor
@Suite(.serialized)
struct StatusIconPerformanceTests {
    nonisolated static let enforce = ProcessInfo.processInfo.environment["CORRAL_PERF"] != nil

    @Test func applyStaysCheap() {
        let (wasEnabled, wasReduced) = (Motion.enabled, Motion.reduced)
        Motion.enabled = true
        if Motion.reduced { Motion.setReduced(false) }
        defer {
            Motion.enabled = wasEnabled
            if Motion.reduced != wasReduced { Motion.setReduced(wasReduced) }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let v = StatusIconView()
        w.contentView?.addSubview(v)
        v.forceOnScreen = true
        let cycle = StatusIconTests.allVisuals.map(\.1)
        for visual in cycle { v.apply(visual, session: nil, animated: false) }   // warm the art cache
        var snaps: [Double] = [], transitions: [Double] = []
        for round in 0..<40 {
            for visual in cycle {
                let animated = round % 2 == 0
                // Each transition gets a fresh session (outside the timing), so the flap guard never snaps it.
                let id = UUID()
                if animated, let current = v.visual { v.apply(current, session: id, animated: false) }
                let t0 = BenchRunner.now()
                v.apply(visual, session: animated ? id : nil, animated: animated)
                let ms = BenchRunner.ms(since: t0)
                if animated { transitions.append(ms) } else { snaps.append(ms) }
            }
        }
        let snap = BenchRunner.Metric.percentile(snaps, 0.95)
        let transition = BenchRunner.Metric.percentile(transitions, 0.95)
        print("PERF status icon snap p95 ms: \(String(format: "%.3f", snap)) (budget 0.25)")
        print("PERF status icon transition p95 ms: \(String(format: "%.3f", transition)) (budget 0.5)")
        if Self.enforce {
            #expect(snap < 0.25)
            #expect(transition < 0.5)
        }
    }
}
