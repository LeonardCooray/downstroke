public enum MuteRules {
    public static func shouldPlay(
        enabled: Bool, frontmostBundleID: String?, muted: [String], micInUse: Bool, muteWhileMicInUse: Bool
    ) -> Bool {
        guard enabled else { return false }
        if let id = frontmostBundleID, muted.contains(id) { return false }
        return !(micInUse && muteWhileMicInUse)
    }
}
