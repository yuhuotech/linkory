/// The app's own version. Release builds pass --dart-define=LINKORY_VERSION=X.Y.Z (the tag without the "v");
/// local builds keep this default. Used for the update check and reported at sign-in.
const appVersion = String.fromEnvironment('LINKORY_VERSION', defaultValue: '0.1.0');
