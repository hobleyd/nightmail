import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'html_view_controller.dart';
import 'html_view_overlay_guard.dart';

class HtmlViewWidget extends StatefulWidget {
  const HtmlViewWidget({
    required this.controller,
    this.scaleFactor,
    super.key,
  });

  final HtmlViewController controller;

  /// Override the device pixel ratio. Defaults to [View.devicePixelRatio].
  final double? scaleFactor;

  @override
  State<HtmlViewWidget> createState() => _HtmlViewWidgetState();
}

class _HtmlViewWidgetState extends State<HtmlViewWidget>
    with WindowListener {
  final _key = GlobalKey();

  // WebView2 (a native Win32 child window) always paints over Flutter's
  // DirectX surface, so we hide it whenever something Flutter-rendered
  // should appear on top of it: either a ModalRoute (dialog, bottom sheet)
  // pushed above this widget's route, or a non-route overlay (hover card,
  // dropdown) that has claimed HtmlViewOverlayGuard.
  bool _isModalCurrent = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    HtmlViewOverlayGuard.activeCount.addListener(_onGuardChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportPosition();
      _reportSize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of() registers a dependency on _ModalScopeStatus so this
    // method is called whenever a route is pushed/popped above this widget.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent != _isModalCurrent) {
      _isModalCurrent = isCurrent;
      _applyVisibility();
    }
  }

  void _onGuardChanged() => _applyVisibility();

  void _applyVisibility() {
    final visible =
        _isModalCurrent && HtmlViewOverlayGuard.activeCount.value == 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.setVisible(visible));
    });
  }

  @override
  void onWindowMove() {
    _reportPosition();
  }

  @override
  void onWindowResize() {
    _reportPosition();
    _reportSize();
  }

  double get _dpr =>
      widget.scaleFactor ??
      ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  void _reportPosition() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final pos = box.localToGlobal(Offset.zero);
    unawaited(widget.controller.setPosition(pos.dx, pos.dy, _dpr));
  }

  void _reportSize() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    unawaited(
        widget.controller.setSize(box.size.width, box.size.height, _dpr));
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _reportPosition();
        _reportSize();
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: SizedBox.expand(key: _key),
      ),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    HtmlViewOverlayGuard.activeCount.removeListener(_onGuardChanged);
    super.dispose();
  }
}
