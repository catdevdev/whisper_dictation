import Foundation

/// Turns side-specific `flagsChanged` snapshots into explicit gesture-key
/// transitions for left Shift and right Option.
///
/// The event's key code identifies the physical gesture key whose state changed,
/// while its device-specific flags describe both monitored keys afterward. This
/// makes chord releases and duplicate events deterministic without a second,
/// potentially stale hardware-state poll.
public struct OptionTransitionTracker: Sendable {
    public private(set) var pressedKeys: Set<OptionKey>

    public init(initiallyPressed: Set<OptionKey> = []) {
        pressedKeys = initiallyPressed
    }

    public mutating func transition(
        for key: OptionKey,
        isPressed: Bool,
        clean: Bool
    ) -> GestureEvent? {
        if isPressed {
            guard !pressedKeys.contains(key) else { return nil }

            let isOnlyGestureKey = pressedKeys.isEmpty
            pressedKeys.insert(key)
            return .optionDown(key, clean: clean && isOnlyGestureKey)
        }

        guard pressedKeys.remove(key) != nil else { return nil }
        return .optionUp(key)
    }

    /// Reconciles the previous state with the complete snapshot carried by the
    /// modifier event. Multi-key changes indicate a missed or out-of-order edge,
    /// so callers receive a reset instead of a synthesized gesture.
    public mutating func transition(
        for key: OptionKey,
        pressedInEvent current: Set<OptionKey>,
        clean: Bool
    ) -> GestureEvent? {
        let previous = pressedKeys
        let changed = previous.symmetricDifference(current)
        pressedKeys = current

        guard !changed.isEmpty else { return nil }
        guard changed == Set([key]) else { return .reset }

        if current.contains(key) {
            return .optionDown(
                key,
                clean: clean && previous.isEmpty && current == Set([key])
            )
        }
        return .optionUp(key)
    }

    public mutating func reset(to physicallyPressed: Set<OptionKey> = []) {
        pressedKeys = physicallyPressed
    }
}
