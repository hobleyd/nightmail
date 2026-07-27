/// Who should be emailed an invite/update/cancellation when an organized
/// meeting is saved.
enum MeetingNotifyScope {
  /// Notify every attendee. Used when the meeting's content (time, subject,
  /// location, body, recurrence, …) changed.
  all,

  /// Notify only the attendees added or removed by this save — added guests
  /// get an invite, removed guests get a cancellation, and unchanged guests
  /// are left alone. Used when the attendee list was the only thing that
  /// changed.
  ///
  /// Microsoft Graph honours this natively (a PATCH that only alters the
  /// attendee collection notifies just the delta). Google Calendar's API
  /// cannot scope notifications to a subset of guests, so its datasource
  /// falls back to [all] for this scope.
  changedAttendeesOnly,

  /// Send no notifications. Used when nothing attendee-visible changed (e.g.
  /// only a personal reminder was adjusted), so the save still persists but
  /// no one is emailed.
  none,
}
