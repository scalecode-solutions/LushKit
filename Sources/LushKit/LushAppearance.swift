/// The home screen's wording, chosen by the host. The kit ships neutral
/// defaults (LushLab); a host can pass its own.
public struct LushAppearance: Sendable {
    /// Heading over toys connected to this phone.
    public var localTitle: String
    /// Heading over toys other people share with the user.
    public var sharedTitle: String
    /// Heading over the user's own toys.
    public var mineTitle: String
    public var sharedEmpty: String
    public var mineEmpty: String
    /// The button that opens the connect screen.
    public var connectPrompt: String

    public init(localTitle: String = "On this phone",
                sharedTitle: String = "Shared with you",
                mineTitle: String = "Your toys",
                sharedEmpty: String = "When someone shares their toys with you, they show up here.",
                mineEmpty: String = "Connect a toy on this phone and it shows up here.",
                connectPrompt: String = "Connect a toy") {
        self.localTitle = localTitle
        self.sharedTitle = sharedTitle
        self.mineTitle = mineTitle
        self.sharedEmpty = sharedEmpty
        self.mineEmpty = mineEmpty
        self.connectPrompt = connectPrompt
    }

    public static let standard = LushAppearance()
}
