import 'package:flutter/material.dart';

import '../../domain/entities/attendee_availability.dart';

/// How a free/busy status is drawn, shared by the guest availability rows and
/// the Location field's room dropdown so a busy room and a busy colleague read
/// the same way.
Color availabilityStatusColor(AttendeeAvailabilityStatus s) => switch (s) {
      AttendeeAvailabilityStatus.free => const Color(0xFF34C759),
      AttendeeAvailabilityStatus.tentative => const Color(0xFFFF9F0A),
      AttendeeAvailabilityStatus.busy => const Color(0xFFFF3B30),
      AttendeeAvailabilityStatus.outOfOffice => const Color(0xFFFF3B30),
      AttendeeAvailabilityStatus.workingElsewhere => const Color(0xFF5E5CE6),
      AttendeeAvailabilityStatus.unknown => const Color(0xFF8E8E93),
    };

/// The status word shown beside the dot. Empty for [AttendeeAvailabilityStatus.unknown]:
/// a mailbox the provider will not talk about has nothing truthful said about it,
/// so the dot stands alone rather than claiming "free".
const availabilityStatusLabels = {
  AttendeeAvailabilityStatus.free: 'Free',
  AttendeeAvailabilityStatus.tentative: 'Tentative',
  AttendeeAvailabilityStatus.busy: 'Busy',
  AttendeeAvailabilityStatus.outOfOffice: 'Out of office',
  AttendeeAvailabilityStatus.workingElsewhere: 'Working elsewhere',
  AttendeeAvailabilityStatus.unknown: '',
};

/// The room-picker wording for the same statuses. A room is not "out of office",
/// it is taken — and "Free" reads as bookable rather than as an opinion about
/// someone's day.
const roomAvailabilityLabels = {
  AttendeeAvailabilityStatus.free: 'Available',
  AttendeeAvailabilityStatus.tentative: 'Held',
  AttendeeAvailabilityStatus.busy: 'Booked',
  AttendeeAvailabilityStatus.outOfOffice: 'Booked',
  AttendeeAvailabilityStatus.workingElsewhere: 'Booked',
  AttendeeAvailabilityStatus.unknown: '',
};
