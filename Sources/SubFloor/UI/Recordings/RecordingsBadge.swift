/// The red unheard count on the Recordings button.
enum RecordingsBadge {
    /// Nil when there is nothing unheard, so the badge is hidden; `99+` above 99.
    static func text(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
}
