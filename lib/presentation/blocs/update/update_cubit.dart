import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../infrastructure/update/app_update_service.dart';
import '../../../infrastructure/update/app_update_status.dart';

/// Publishes [AppUpdateService]'s status to the widgets that draw it: the red
/// dot on the folder panel's Settings icon, and the update block in the About
/// section of Settings.
///
/// Same shape as [OverdueTasksCubit] — a service already owns the work and the
/// timing, and this is the thin bloc-shaped window onto it. It holds no update
/// logic of its own; every action forwards.
///
/// It is a *singleton* rather than a factory because both of its consumers must
/// see the same status, and because the About panel is built inside a separate
/// dialog route (see `SettingsDialog.open`, which re-provides it) rather than
/// under `HomePage`'s provider subtree.
class UpdateCubit extends Cubit<AppUpdateStatus> {
  UpdateCubit({required AppUpdateService service})
      : _service = service,
        super(service.status);

  final AppUpdateService _service;

  StreamSubscription<AppUpdateStatus>? _sub;

  /// Safe to call repeatedly — `HomePage` calls it on every build.
  void start() {
    _sub ??= _service.changes.listen((status) {
      if (!isClosed) emit(status);
    });
    // The service may already have a status from a previous start: adopt it
    // rather than waiting for the next change, which may never come.
    if (!isClosed && state != _service.status) emit(_service.status);
    unawaited(_service.start());
  }

  Future<void> check() => _service.checkForUpdate();

  Future<void> download() => _service.downloadUpdate();

  /// The only action a fresh-install-only release supports.
  Future<void> openFreshInstallDownload() =>
      _service.openFreshInstallDownload();

  Future<void> install() => _service.installUpdate();

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
