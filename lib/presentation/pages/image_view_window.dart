import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_colors.dart';
import '../../injection_container.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';

/// Standalone, freely resizable window that shows a single image the user
/// double-clicked in a reading pane. The [src] is either an `http(s)` URL or
/// an inline `data:` URL (inline `cid:` images are converted to data URLs
/// before the HTML is rendered, so that is what arrives here).
class ImageViewWindowApp extends StatelessWidget {
  const ImageViewWindowApp({super.key, required this.arguments});

  final Map<String, dynamic> arguments;

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C83FD)),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: _ImageViewPage(src: arguments['src'] as String? ?? ''),
          );
        },
      ),
    );
  }
}

class _ImageViewPage extends StatelessWidget {
  const _ImageViewPage({required this.src});

  final String src;

  Widget _buildImage(AppColors c) {
    if (src.isEmpty) return _ImageError(colors: c);

    Widget errorBuilder(BuildContext _, Object _, StackTrace? _) =>
        _ImageError(colors: c);

    if (src.startsWith('data:')) {
      final data = Uri.tryParse(src)?.data;
      if (data == null) return _ImageError(colors: c);
      return Image.memory(
        data.contentAsBytes(),
        fit: BoxFit.contain,
        errorBuilder: errorBuilder,
      );
    }

    return Image.network(
      src,
      fit: BoxFit.contain,
      errorBuilder: errorBuilder,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.surfacePanel,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(onClose: () => windowManager.close()),
          Divider(height: 1, color: c.border),
          Expanded(
            child: Container(
              color: c.surfaceBase,
              padding: const EdgeInsets.all(16),
              child: InteractiveViewer(
                minScale: 0.2,
                maxScale: 8.0,
                child: Center(child: _buildImage(c)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageError extends StatelessWidget {
  const _ImageError({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 40, color: colors.textMuted),
          const SizedBox(height: 8),
          Text(
            'Unable to display image',
            style: TextStyle(color: colors.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.image_outlined, size: 16, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Image',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
            color: c.textMuted,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
