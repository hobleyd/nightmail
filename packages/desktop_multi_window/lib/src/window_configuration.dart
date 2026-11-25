class WindowConfiguration {
  const WindowConfiguration({
    required this.arguments,
    this.hiddenAtLaunch = true,
    this.nonActivating = false,
  });

  /// The arguments passed to the new window.
  final String arguments;

  final bool hiddenAtLaunch;

  /// macOS only: the window is a non-activating panel. Clicking it, or showing
  /// it, does not activate the app, so the app's other windows stay behind
  /// whatever the user was working in. Ignored on other platforms.
  final bool nonActivating;

  factory WindowConfiguration.fromJson(Map<String, dynamic> json) {
    return WindowConfiguration(
      arguments: json['arguments'] as String? ?? '',
      hiddenAtLaunch: json['hiddenAtLaunch'] as bool? ?? false,
      nonActivating: json['nonActivating'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'arguments': arguments,
      'hiddenAtLaunch': hiddenAtLaunch,
      'nonActivating': nonActivating,
    };
  }

  @override
  String toString() {
    return 'WindowConfiguration(arguments: $arguments, hiddenAtLaunch: $hiddenAtLaunch, nonActivating: $nonActivating)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WindowConfiguration &&
        other.arguments == arguments &&
        other.hiddenAtLaunch == hiddenAtLaunch &&
        other.nonActivating == nonActivating;
  }

  @override
  int get hashCode {
    return arguments.hashCode ^
        hiddenAtLaunch.hashCode ^
        nonActivating.hashCode;
  }
}
