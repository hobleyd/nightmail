import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../infrastructure/http/google_calendar_http_client.dart';
import '../../models/calendar_event_model.dart';
import 'calendar_remote_datasource.dart';

class GoogleCalendarDatasourceImpl implements CalendarRemoteDatasource {
  GoogleCalendarDatasourceImpl({required GoogleCalendarHttpClient client})
      : _dio = client.dio;

  final Dio _dio;

  @override
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/calendars/primary/events',
        queryParameters: {
          'timeMin': startDateTime.toUtc().toIso8601String(),
          'timeMax': endDateTime.toUtc().toIso8601String(),
          'singleEvents': true,
          'orderBy': 'startTime',
          'maxResults': 250,
          'fields':
              'items(id,summary,start,end,description,location,status,organizer,attendees,allDayEvent)',
        },
      );

      final data = response.data;
      if (data == null) return [];

      final items = data['items'] as List<dynamic>? ?? [];
      return items
          .map((e) => _parseEvent(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  CalendarEventModel _parseEvent(Map<String, dynamic> json) {
    final startMap = json['start'] as Map<String, dynamic>? ?? {};
    final endMap = json['end'] as Map<String, dynamic>? ?? {};

    final isAllDay = startMap.containsKey('date') && !startMap.containsKey('dateTime');

    final start = isAllDay
        ? DateTime.parse('${startMap['date']}T00:00:00Z')
        : DateTime.parse(startMap['dateTime'] as String? ?? DateTime.now().toIso8601String()).toUtc();

    final end = isAllDay
        ? DateTime.parse('${endMap['date']}T00:00:00Z')
        : DateTime.parse(endMap['dateTime'] as String? ?? DateTime.now().toIso8601String()).toUtc();

    final organizerEmail = (json['organizer'] as Map<String, dynamic>?)?['email'] as String?;
    final attendees = (json['attendees'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final selfAttendee = attendees.where((a) => a['self'] == true).firstOrNull;
    final selfStatus = selfAttendee?['responseStatus'] as String?;

    final status = _parseStatus(selfStatus ?? json['status'] as String?);
    final isOrganizer = selfAttendee?['organizer'] == true ||
        (organizerEmail != null && attendees.any((a) => a['email'] == organizerEmail && a['self'] == true));

    return CalendarEventModel(
      id: json['id'] as String? ?? '',
      subject: json['summary'] as String? ?? '(No title)',
      start: start,
      end: end,
      isAllDay: isAllDay,
      location: json['location'] as String?,
      bodyPreview: json['description'] as String?,
      status: status,
      isOrganizer: isOrganizer,
    );
  }

  CalendarEventStatus _parseStatus(String? value) {
    return switch (value?.toLowerCase()) {
      'free' || 'accepted' => CalendarEventStatus.free,
      'tentative' || 'needsaction' => CalendarEventStatus.tentative,
      'declined' => CalendarEventStatus.free,
      _ => CalendarEventStatus.busy,
    };
  }

  Exception _mapException(DioException e) {
    final statusCode = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }
    return ServerException(
        message: e.message ?? 'Server error ($statusCode)',
        statusCode: statusCode);
  }
}
