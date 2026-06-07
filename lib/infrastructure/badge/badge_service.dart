import 'package:flutter/services.dart';

class BadgeService {
  static const _channel = MethodChannel('au.com.sharpblue.nightmail/badge');

  Future<void> setBadgeCount(int count) async {
    try {
      await _channel.invokeMethod('setBadgeCount', count);
    } catch (_) {}
  }
}
