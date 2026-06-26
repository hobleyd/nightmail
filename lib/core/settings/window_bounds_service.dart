import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// Returned by [WindowBoundsService.loadValidatedBounds].
class WindowRestoreState {
  const WindowRestoreState({
    this.bounds,
    this.fullScreen = false,
    this.maximized = false,
  });

  /// Saved window rect. Null when [fullScreen] or [maximized] is true.
  final Rect? bounds;

  /// Window was in macOS full-screen (Space) mode when last saved.
  final bool fullScreen;

  /// Window was in zoomed/maximized state when last saved.
  final bool maximized;
}

class WindowBoundsService {
  static const String _boundsFile = 'window_bounds.json';
  static const double _minTitleBarOverlap = 100.0;
  static const double _titleBarHeight = 40.0;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_boundsFile');
  }

  // ── Public API ───────────────────────────────────────────────────────────

  /// Returns the best restore state given currently connected displays, or
  /// null to let the platform use its default position/size.
  ///
  /// Selection priority: external displays before built-in.
  /// Within each tier the first candidate whose state is restorable wins:
  ///   - fullScreen / maximized entries: pass if the display is connected.
  ///   - Normal entries: pass if the title bar is reachable on-screen.
  Future<WindowRestoreState?> loadValidatedBounds() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      final saved = await _loadMap();

      // Build candidates: per display, try exact key first then resolution
      // fallback. The fallback handles the case where the OS-assigned device
      // path (e.g. \\.\DISPLAY2 on Windows) changes between sessions due to
      // docking-station re-enumeration or a monitor being reconnected.
      final candidates = <(Display, _DisplayEntry)>[];
      final usedEntries = <_DisplayEntry>{};
      for (final display in displays) {
        // 1. Exact key match.
        final exactEntry = saved[_displayKey(display)];
        if (exactEntry != null && !usedEntries.contains(exactEntry)) {
          candidates.add((display, exactEntry));
          usedEntries.add(exactEntry);
          continue;
        }
        // 2. Resolution-based fallback (newest saves at the end of the map,
        //    iterate in reverse so the most-recent save wins).
        final sizeKey = _sizeKey(display);
        for (final e in saved.entries.toList().reversed) {
          if (usedEntries.contains(e.value)) continue;
          if (!e.key.endsWith('_$sizeKey')) continue;
          // Validate the saved bounds are actually visible in the current
          // display layout before accepting the fallback match.
          final b = e.value.bounds;
          if (b != null && !_isTitleBarReachable(b, displays)) continue;
          candidates.add((display, e.value));
          usedEntries.add(e.value);
          break;
        }
      }

      if (candidates.isEmpty) return null;

      // External displays first, built-in last.
      candidates.sort((a, b) =>
          (_isLikelyBuiltIn(a.$1) ? 1 : 0) - (_isLikelyBuiltIn(b.$1) ? 1 : 0));

      for (final (_, entry) in candidates) {
        if (entry.fullScreen) {
          return const WindowRestoreState(fullScreen: true);
        }
        if (entry.maximized) {
          return const WindowRestoreState(maximized: true);
        }
        if (entry.bounds != null &&
            _isTitleBarReachable(entry.bounds!, displays)) {
          return WindowRestoreState(bounds: entry.bounds!);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Saves the window state keyed to the display the window centre falls on.
  ///
  /// [bounds] must always be supplied (even in special states) so the correct
  /// display key can be derived. The bounds are only persisted when the window
  /// is in normal (non-maximized, non-fullscreen) state.
  Future<void> saveBounds(
    Rect bounds, {
    bool fullScreen = false,
    bool maximized = false,
  }) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      final display = _displayForBounds(bounds, displays);
      if (display == null) return;

      final saved = await _loadMap();
      saved[_displayKey(display)] = _DisplayEntry(
        bounds: (fullScreen || maximized) ? null : bounds,
        fullScreen: fullScreen,
        maximized: maximized,
      );
      await _saveMap(saved);
    } catch (_) {}
  }

  // ── Storage ──────────────────────────────────────────────────────────────

  Future<Map<String, _DisplayEntry>> _loadMap() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return {};
      final result = <String, _DisplayEntry>{};
      for (final entry in raw.entries) {
        final v = entry.value;
        if (v is! Map<String, dynamic>) continue;
        Rect? bounds;
        if (v['x'] != null) {
          bounds = Rect.fromLTWH(
            (v['x'] as num).toDouble(),
            (v['y'] as num).toDouble(),
            (v['width'] as num).toDouble(),
            (v['height'] as num).toDouble(),
          );
        }
        result[entry.key] = _DisplayEntry(
          bounds: bounds,
          fullScreen: v['fullScreen'] as bool? ?? false,
          maximized: v['maximized'] as bool? ?? false,
        );
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveMap(Map<String, _DisplayEntry> map) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({
        for (final e in map.entries)
          e.key: {
            if (e.value.bounds != null) ...{
              'x': e.value.bounds!.left,
              'y': e.value.bounds!.top,
              'width': e.value.bounds!.width,
              'height': e.value.bounds!.height,
            },
            'fullScreen': e.value.fullScreen,
            'maximized': e.value.maximized,
          },
      }));
    } catch (_) {}
  }

  // ── Display helpers ──────────────────────────────────────────────────────

  /// Stable per-display key: identifier + native resolution.
  ///
  /// macOS:   name = NSScreen.localizedName (stable, descriptive)
  /// Linux:   id   = "" always; name = EDID model from gdk_monitor_get_model
  /// Windows: screen_retriever returns the VOLATILE device path (e.g.
  ///          "\\.\DISPLAY2") as display.name and the STABLE hardware
  ///          DeviceID (PnP instance path) as display.id.  On Windows we
  ///          therefore prefer id over name.
  static String _displayKey(Display display) {
    final String identifier;
    if (Platform.isWindows) {
      identifier = display.id.isNotEmpty ? display.id : (display.name ?? '');
    } else {
      identifier =
          (display.name?.isNotEmpty == true) ? display.name! : display.id;
    }
    return '${identifier}_${_sizeKey(display)}';
  }

  /// Resolution-only portion of the key ("WxH").  Used by the fallback
  /// lookup in [loadValidatedBounds] when the full key doesn't match.
  static String _sizeKey(Display display) {
    final w = display.size.width.toInt();
    final h = display.size.height.toInt();
    return '${w}x$h';
  }

  /// Returns the display whose visible area contains the window centre.
  /// Falls back to the display with the largest overlap.
  static Display? _displayForBounds(Rect bounds, List<Display> displays) {
    final center = bounds.center;
    for (final display in displays) {
      if (_visibleRect(display).contains(center)) return display;
    }
    Display? best;
    double bestArea = 0;
    for (final display in displays) {
      final overlap = bounds.intersect(_visibleRect(display));
      final area = overlap.isEmpty ? 0.0 : overlap.width * overlap.height;
      if (area > bestArea) {
        bestArea = area;
        best = display;
      }
    }
    return best;
  }

  static bool _isTitleBarReachable(Rect bounds, List<Display> displays) {
    final titleBar = Rect.fromLTWH(
      bounds.left,
      bounds.top,
      bounds.width,
      _titleBarHeight,
    );
    for (final display in displays) {
      final overlap = titleBar.intersect(_visibleRect(display));
      if (!overlap.isEmpty && overlap.width >= _minTitleBarOverlap) return true;
    }
    return false;
  }

  /// Heuristic: true for built-in laptop/desktop panels.
  ///
  /// macOS:   localizedName is "Built-in Retina Display" or "Color LCD".
  /// Linux:   EDID name heuristic only — connector names (eDP-1) are not
  ///          exposed by screen_retriever_linux so detection is best-effort.
  /// Windows: friendly name heuristic only.
  static bool _isLikelyBuiltIn(Display display) {
    final name = (display.name ?? '').toLowerCase();
    final id = display.id.toLowerCase();
    return name.contains('built-in') ||
        name.contains('built in') ||
        name.contains('color lcd') ||
        name.contains('internal') ||
        id.contains('edp') ||
        id.startsWith('dsi');
  }

  static Rect _visibleRect(Display display) => Rect.fromLTWH(
        display.visiblePosition?.dx ?? 0,
        display.visiblePosition?.dy ?? 0,
        display.visibleSize?.width ?? display.size.width,
        display.visibleSize?.height ?? display.size.height,
      );
}

class _DisplayEntry {
  const _DisplayEntry({
    required this.bounds,
    required this.fullScreen,
    required this.maximized,
  });
  final Rect? bounds;
  final bool fullScreen;
  final bool maximized;
}
