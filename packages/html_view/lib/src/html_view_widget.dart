import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'html_view_controller.dart';

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

  // Tracks whether the native WebView2 HWND is currently visible.
  // WebView2 (a native Win32 child window) always paints over Flutter's
  // DirectX surface, so we hide it whenever a Flutter overlay route
  // (dialog, bottom sheet, etc.) is shown on top of this widget's route.
  bool _nativeVisible = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
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
    if (isCurrent != _nativeVisible) {
      _nativeVisible = isCurrent;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.controller.setVisible(_nativeVisible));
      });
    }
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
    super.dispose();
  }
}
