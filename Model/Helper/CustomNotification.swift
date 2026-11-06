import Foundation

extension Notification.Name {
    static let willUpdateOverrideConfiguration = Notification.Name("willUpdateOverrideConfiguration")
    static let didUpdateOverrideConfiguration = Notification.Name("didUpdateOverrideConfiguration")
    static let willUpdateTempTargetConfiguration = Notification.Name("willUpdateTempTargetConfiguration")
    static let didUpdateTempTargetConfiguration = Notification.Name("didUpdateTempTargetConfiguration")
    /// Override and temp target presets were written by a backup restore.
    static let didRestoreAdjustmentPresets = Notification.Name("didRestoreAdjustmentPresets")
    static let liveActivityOrderDidChange = Notification.Name("liveActivityOrderDidChange")
    static let openFromGarminConnect = Notification.Name("Notification.Name.openFromGarminConnect")
}
