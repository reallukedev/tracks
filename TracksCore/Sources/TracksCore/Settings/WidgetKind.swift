/// Widget kinds, shared by the widget extension and the app that reloads them.
///
/// The system stores these as the identity of every placed widget, so renaming one orphans
/// every copy already on a Home Screen or desktop. That's why `today` is still `TodayOnRadio`.
public enum WidgetKind {
    public static let lastPlayed = "LastCaptured"
    public static let today = "TodayOnRadio"
    public static let listening = "Listening"
}
