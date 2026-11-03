import Testing

/// The Duo tests that render or host screens, one at a time: the offline cases switch the app's
/// shared connection state, which every other rendering test would otherwise see mid-render.
@Suite(.serialized)
enum DuoUITests {}
