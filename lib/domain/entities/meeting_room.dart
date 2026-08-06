import 'package:equatable/equatable.dart';

/// A bookable room, as offered in the event form's Location field.
///
/// A room is just a mailbox (Exchange) or a resource calendar (Google) with a
/// booking policy attached, which is why free/busy for one is fetched through
/// the same path as a guest's — see `CalendarRepository.checkAttendeesAvailability`.
/// Selecting a room therefore means *inviting* it, not only naming it: see
/// `CreateCalendarEventParams.roomEmails`.
class MeetingRoom extends Equatable {
  const MeetingRoom({
    required this.email,
    required this.displayName,
    this.capacity,
    this.building,
    this.floorLabel,
    this.isWheelchairAccessible = false,
  });

  /// The room mailbox / resource calendar address. This is the identity — it is
  /// what gets invited and what free/busy is keyed by.
  final String email;

  final String displayName;

  /// Seats, when the provider reports it. Null means unknown, not zero.
  final int? capacity;

  final String? building;

  /// Floor as text rather than a number: Graph reports `floorNumber` (an int)
  /// and Google `floorName` (a free-form string like "M" or "Ground"), and
  /// there is nothing useful to gain by forcing the latter into the former.
  final String? floorLabel;

  final bool isWheelchairAccessible;

  /// Building/floor/capacity as one line for the dropdown's subtitle, or null
  /// when the provider told us none of them.
  String? get detailLine {
    final parts = [
      if (building != null && building!.isNotEmpty) building,
      if (floorLabel != null && floorLabel!.isNotEmpty) 'Level $floorLabel',
      if (capacity != null) '$capacity seats',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  List<Object?> get props => [email, displayName, capacity, building, floorLabel];
}
