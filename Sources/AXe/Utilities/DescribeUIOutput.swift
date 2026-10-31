import Foundation

// MARK: - Described Element

/// One element of describe-ui's JSON output.
///
/// The serialized dictionary is kept as it came from the simulator, so every key of the public
/// schema survives display filtering; only `frame` and `AXFrame` are rewritten.
struct DescribedElement: AccessibilityFrameTree {
    // The schema is open-ended JSON from the simulator; a typed model would drop or reformat keys.
    let json: [String: Any]

    init(json: [String: Any]) {
        self.json = json
    }

    var frame: AccessibilityElement.Frame? {
        guard let frame = json["frame"] as? [String: Any],
              let x = Self.number(frame["x"]),
              let y = Self.number(frame["y"]),
              let width = Self.number(frame["width"]),
              let height = Self.number(frame["height"]) else {
            return nil
        }
        return AccessibilityElement.Frame(x: x, y: y, width: width, height: height)
    }

    var children: [DescribedElement]? {
        (json["children"] as? [[String: Any]]).map { $0.map(DescribedElement.init(json:)) }
    }

    /// True when the element names itself: a label, identifier or value.
    var isDescribed: Bool {
        hasLabelOrValue || hasText("AXUniqueId") || hasText("AXIdentifier")
    }

    /// True when the element has a non-empty label or value, which is what a person sees. Internal
    /// containers can carry an identifier only (SpringBoard's icon caption is `label-view`).
    var hasLabelOrValue: Bool {
        hasText("AXLabel") || hasText("AXValue")
    }

    /// True when the element reports `focused: true`.
    var isFocused: Bool {
        (json["focused"] as? NSNumber)?.boolValue == true
    }

    private func hasText(_ key: String) -> Bool {
        guard let text = json[key] as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func replacingChildren(_ children: [DescribedElement]) -> DescribedElement {
        var json = json
        json["children"] = children.map(\.json)
        return DescribedElement(json: json)
    }

    func replacingFrame(_ frame: AccessibilityElement.Frame) -> DescribedElement {
        var json = json
        json["frame"] = [
            "x": frame.x,
            "y": frame.y,
            "width": frame.width,
            "height": frame.height,
        ]
        if json["AXFrame"] is String {
            json["AXFrame"] = Self.axFrameString(frame)
        }
        return DescribedElement(json: json)
    }

    func mappingFrames(_ transform: (AccessibilityElement.Frame) -> AccessibilityElement.Frame) -> DescribedElement {
        var element = frame.map { replacingFrame(transform($0)) } ?? self
        if let children {
            element = element.replacingChildren(children.map { $0.mappingFrames(transform) })
        }
        return element
    }

    /// `AXFrame` in the simulator's format, `NSStringFromRect` style: `{{x, y}, {width, height}}`
    /// with 17 significant digits.
    static func axFrameString(_ frame: AccessibilityElement.Frame) -> String {
        "{{\(format(frame.x)), \(format(frame.y))}, {\(format(frame.width)), \(format(frame.height))}}"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.17g", value)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

// MARK: - Output

/// describe-ui output for the active display of a foldable simulator.
///
/// The simulator serializes the frontmost application with the frames of every display (the
/// windows of both panels and pixel-sized backing windows) and hit-tests `--point` against the
/// main display only. On a non-main active display AXe reduces the tree to that display's windows
/// in interface points (`TouchTarget.activePanelRoots`) and hit-tests the point itself.
enum DescribeUIOutput {
    static let consequence = "Pass --all-displays to print the unfiltered tree."

    static func fallbackWarning(reason: String) -> String {
        "Warning: could not determine the active display (\(reason)); showing all displays unfiltered."
    }

    /// The display describe-ui reports: a non-main active display, or `nil` to keep the simulator's
    /// output (non-foldables, the folded cover, `AXE_DISPLAY_PROBE=never`). `allDisplays` skips the
    /// display probe entirely.
    ///
    /// Display detection never fails describe-ui: a devicectl failure, an undeterminable active
    /// display or missing geometry prints one `warn` line and keeps the unfiltered output (and the
    /// simulator's hit test for `--point`). Touch commands still fail on the same errors.
    static func displayTarget(
        allDisplays: Bool,
        warn: (String) -> Void = { print($0, to: &standardError) },
        state: () async throws -> SimulatorDisplayState?
    ) async -> TouchTarget? {
        guard !allDisplays else { return nil }
        do {
            return try TouchTarget.nonMainTarget(state: await state())
        } catch {
            // The shared message is written for touch commands ("no touch was sent").
            let reason = error.localizedDescription == TouchTarget.unknownDisplayMessage
                ? "devicectl reports no active display"
                : error.localizedDescription
            warn(fallbackWarning(reason: reason))
            return nil
        }
    }

    /// The tree of the active display. Without a non-main target the data is returned unchanged.
    static func panelTreeData(_ data: Data, target: TouchTarget?) throws -> Data {
        guard let target, !target.isMain else { return data }
        let tree = try DescribedTree(data: data)
        return try serialize(tree.replacingRoots(target.activePanelRoots(tree.roots, consequence: consequence)))
    }

    /// The element at an interface point of the active display, with its subtree, in the shape the
    /// simulator's own hit test prints (a single element object).
    static func elementData(at point: AccessibilityPoint, in data: Data, target: TouchTarget) throws -> Data {
        let tree = try DescribedTree(data: data)
        let roots = try target.activePanelRoots(tree.roots, consequence: consequence)
        let element = try element(at: point, in: roots, target: target)
        return try serialize(element.json)
    }

    static let noFocusedElementMessage = "No focused element: no element in the accessibility tree reports `focused: true`. Run `axe describe-ui` to see the whole tree."

    /// The focused element of a describe-ui tree as a single element object, without its children
    /// (a focused tvOS cell carries decoration groups and images that say nothing about it).
    ///
    /// The element whose `focused` is true; when an element and its descendants are all focused (a
    /// focused cell inside a focused collection), the deepest one, and the first in tree order among
    /// equally deep ones.
    ///
    /// - Throws: `noFocusedElementMessage` when no element is focused.
    static func focusedElementData(in data: Data) throws -> Data {
        let tree = try DescribedTree(data: data)
        guard let element = focusedElement(in: tree.roots) else {
            throw CLIError(errorDescription: noFocusedElementMessage)
        }
        var json = element.json
        json.removeValue(forKey: "children")
        return try serialize(json)
    }

    static func focusedElement(in roots: [DescribedElement]) -> DescribedElement? {
        var best: (element: DescribedElement, depth: Int)?
        func visit(_ element: DescribedElement, depth: Int) {
            if element.isFocused, best.map({ depth > $0.depth }) ?? true {
                best = (element, depth)
            }
            for child in element.children ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        for root in roots {
            visit(root, depth: 0)
        }
        return best?.element
    }

    /// Hit-tests interface-space roots.
    ///
    /// Windows (the direct children of a root) are searched front to back. The tree lists them
    /// back to front: the Dock window follows the home-screen window and keyboard and alert windows
    /// follow the content window, so the last window is searched first. The first window with an
    /// element that has a label, identifier or value at the point decides; within it:
    /// 1. the deepest such element (then the smallest frame, then the last in tree order);
    /// 2. if that element has an identifier only, its nearest ancestor up to the window that
    ///    contains the point and has a label or value (an icon button over its `label-view`);
    /// 3. otherwise the best element with a label or value, if any.
    /// When no window has such an element, the deepest element containing the point is returned (a
    /// container). Frames are half-open: a point on the shared edge of two rows belongs to the
    /// lower or right one; zero-sized frames never contain a point.
    ///
    /// - Throws: when the point is outside the display or no element contains it.
    static func element(
        at point: AccessibilityPoint,
        in roots: [DescribedElement],
        target: TouchTarget
    ) throws -> DescribedElement {
        let bounds = target.interfaceBounds
        // Inclusive like touch coordinates (`TouchTarget.checkedNativePoint`).
        guard point.x >= 0, point.y >= 0, point.x <= bounds.width, point.y <= bounds.height else {
            throw CLIError(
                errorDescription: "Point (\(format(point.x)), \(format(point.y))) is outside display \(target.displayID), which is \(format(bounds.width))x\(format(bounds.height)) points in its current orientation. Take coordinates from `axe screenshot` of the active display (pixels divided by \(format(target.pointScale)))."
            )
        }

        var allHits: [Hit] = []
        for root in roots.reversed() {
            var rootHits: [Hit] = []
            if let frame = root.frame, contains(frame, point) {
                rootHits.append(Hit(element: root, ancestors: [], order: 0, area: frame.width * frame.height))
            }
            for window in (root.children ?? []).reversed() {
                var windowHits: [Hit] = []
                collectHits(in: window, at: point, ancestors: [root], into: &windowHits)
                if let element = described(in: windowHits, at: point) {
                    return element
                }
                rootHits.append(contentsOf: windowHits)
            }
            allHits.append(contentsOf: rootHits)
        }
        guard let container = best(of: allHits) else {
            throw CLIError(
                errorDescription: "No accessibility element contains point (\(format(point.x)), \(format(point.y))) on display \(target.displayID). \(consequence)"
            )
        }
        return container.element
    }

    private struct Hit {
        let element: DescribedElement
        /// From the root down to the parent; index 1 is the window.
        let ancestors: [DescribedElement]
        let order: Int
        let area: Double

        var depth: Int { ancestors.count }
    }

    /// Steps 1-3 of `element(at:in:target:)` for the hits of one window.
    private static func described(in hits: [Hit], at point: AccessibilityPoint) -> DescribedElement? {
        let described = hits.filter { $0.element.isDescribed }
        guard let deepest = best(of: described) else { return nil }
        if deepest.element.hasLabelOrValue {
            return deepest.element
        }
        // Climb to the window (index 1), never to the application root.
        for ancestor in deepest.ancestors.dropFirst().reversed() where ancestor.hasLabelOrValue {
            if let frame = ancestor.frame, contains(frame, point) {
                return ancestor
            }
        }
        return best(of: described.filter { $0.element.hasLabelOrValue })?.element ?? deepest.element
    }

    private static func collectHits(
        in element: DescribedElement,
        at point: AccessibilityPoint,
        ancestors: [DescribedElement],
        into hits: inout [Hit]
    ) {
        if let frame = element.frame, contains(frame, point) {
            hits.append(Hit(element: element, ancestors: ancestors, order: hits.count, area: frame.width * frame.height))
        }
        // Children are searched even when the parent does not contain the point: scroll content
        // and SpringBoard pages report frames outside their container.
        for child in element.children ?? [] {
            collectHits(in: child, at: point, ancestors: ancestors + [element], into: &hits)
        }
    }

    private static func best(of hits: [Hit]) -> Hit? {
        hits.max { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            return lhs.order < rhs.order
        }
    }

    /// Half-open containment, like `CGRect.contains`; empty frames contain nothing.
    private static func contains(_ frame: AccessibilityElement.Frame, _ point: AccessibilityPoint) -> Bool {
        frame.width > 0 && frame.height > 0
            && point.x >= frame.x && point.x < frame.x + frame.width
            && point.y >= frame.y && point.y < frame.y + frame.height
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func serialize(_ object: Any) throws -> Data {
        // Same options as the simulator path (`AccessibilityFetcher.serializeAccessibilityInfo`).
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }
}

/// The roots of describe-ui JSON, remembering whether the top level was an array or one object.
private struct DescribedTree {
    let roots: [DescribedElement]
    let isArray: Bool

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            roots = array.map(DescribedElement.init(json:))
            isArray = true
        } else if let root = object as? [String: Any] {
            roots = [DescribedElement(json: root)]
            isArray = false
        } else {
            throw CLIError(errorDescription: "AXe received an unsupported accessibility response from the simulator.")
        }
    }

    /// The JSON object for new roots, in the original top-level shape.
    func replacingRoots(_ newRoots: [DescribedElement]) -> Any {
        if isArray || newRoots.count != 1 {
            return newRoots.map(\.json)
        }
        return newRoots[0].json
    }
}
