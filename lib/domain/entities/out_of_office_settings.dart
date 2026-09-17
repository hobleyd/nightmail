import 'package:equatable/equatable.dart';

/// Who receives an automatic reply.
///
/// One three-way choice over two providers that model this differently, so the
/// values are named for what the *reader* gets rather than for either wire
/// format. What each means in practice differs slightly by provider, which is
/// why the screen labels them per account rather than sharing one wording —
/// see [OutOfOfficeSettings.audience].
enum OutOfOfficeAudience {
  /// Everyone who writes.
  everyone,

  /// Senders in the user's own contacts. On Microsoft that is *in addition* to
  /// everyone inside the organisation, who always get a reply; on Google it is
  /// the whole of it, so a colleague who is not a contact gets nothing.
  contacts,

  /// Nobody outside the organisation.
  organisationOnly,
}

/// A mailbox's automatic-reply ("out of office") configuration.
///
/// This is a *server* setting, not an app preference: it lives on the mailbox,
/// applies however the user reads their mail, and nothing about it is cached
/// locally.
class OutOfOfficeSettings extends Equatable {
  const OutOfOfficeSettings({
    required this.enabled,
    this.start,
    this.end,
    this.messageHtml = '',
    this.audience = OutOfOfficeAudience.everyone,
    this.useSeparateExternalMessage = false,
    this.externalMessageHtml = '',
  });

  /// Whether automatic replies are scheduled for the [start]–[end] window.
  ///
  /// Maps to Graph `status: scheduled`/`disabled` and Gmail
  /// `enableAutoReply`. "Always on with no end date" is deliberately not
  /// reachable from here — the screen always supplies both dates — but an
  /// `alwaysEnabled` mailbox still reads back as enabled, so turning the
  /// switch off here turns that off too.
  final bool enabled;

  /// The window's bounds, as **wall-clock** local times rather than instants.
  ///
  /// The screen picks whole dates, so [start] is midnight on the first day and
  /// [end] is the last moment of the last day — the end date is *inclusive*,
  /// which is what "I'm away until Friday" means and what Gmail's own UI does.
  /// Reading the bounds as a wall clock is what keeps the two providers
  /// honest: Graph stores a local time plus a zone name (the mailbox's own,
  /// which may not be this device's), so its fields are carried across
  /// verbatim rather than converted through UTC.
  final DateTime? start;
  final DateTime? end;

  /// The reply body, as HTML. Both providers store HTML natively — Graph's
  /// `internalReplyMessage` is HTML and Gmail has `responseBodyHtml` — so a
  /// message written in Outlook or the Gmail web UI round-trips through this
  /// screen with its formatting intact.
  ///
  /// When [useSeparateExternalMessage] is set this is the *internal* message;
  /// otherwise it is the only one, sent to everybody who gets a reply.
  final String messageHtml;

  /// Who gets a reply. Graph stores this as `externalAudience`; Gmail composes
  /// it out of `restrictToDomain` and `restrictToContacts`.
  final OutOfOfficeAudience audience;

  /// Microsoft only: send [externalMessageHtml] to people outside the
  /// organisation instead of [messageHtml].
  ///
  /// A separate flag rather than "[externalMessageHtml] is empty", so that
  /// turning the option *off* keeps the text: it can be turned back on without
  /// having to retype a message the mailbox already had. The save sends
  /// [messageHtml] to both fields while this is false, so what is stored
  /// always matches what the screen shows.
  final bool useSeparateExternalMessage;

  /// The external reply body. Meaningful only while
  /// [useSeparateExternalMessage] is set, but retained either way.
  final String externalMessageHtml;

  /// The message a sender outside the organisation actually receives.
  String get effectiveExternalMessageHtml =>
      useSeparateExternalMessage ? externalMessageHtml : messageHtml;

  /// Whether anybody outside the organisation gets a reply at all. A separate
  /// external message is meaningless when nobody external is answered.
  bool get repliesToExternalSenders =>
      audience != OutOfOfficeAudience.organisationOnly;

  /// Note that this cannot *clear* a field: a null argument means "leave it
  /// alone", which is what every caller wants and what the form guarantees
  /// (both bounds are non-null from the moment the draft is built). Anything
  /// that needs to null a bound has to build the object outright.
  OutOfOfficeSettings copyWith({
    bool? enabled,
    DateTime? start,
    DateTime? end,
    String? messageHtml,
    OutOfOfficeAudience? audience,
    bool? useSeparateExternalMessage,
    String? externalMessageHtml,
  }) {
    return OutOfOfficeSettings(
      enabled: enabled ?? this.enabled,
      start: start ?? this.start,
      end: end ?? this.end,
      messageHtml: messageHtml ?? this.messageHtml,
      audience: audience ?? this.audience,
      useSeparateExternalMessage:
          useSeparateExternalMessage ?? this.useSeparateExternalMessage,
      externalMessageHtml: externalMessageHtml ?? this.externalMessageHtml,
    );
  }

  @override
  List<Object?> get props => [
    enabled,
    start,
    end,
    messageHtml,
    audience,
    useSeparateExternalMessage,
    externalMessageHtml,
  ];
}
