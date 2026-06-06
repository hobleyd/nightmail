import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/auth/auth_event.dart';
import '../blocs/auth/auth_state.dart';

class SignInPage extends StatelessWidget {
  const SignInPage({super.key});

  @override
  Widget build(BuildContext context) {
    // BlocConsumer covers both cases:
    //   • listener fires on state *transitions* (e.g. sign-in attempt while
    //     already on this page)
    //   • builder checks the *current* state so an error is visible even when
    //     this page is first mounted after a failed sign-in
    return BlocConsumer<AuthBloc, AuthState>(
      listener: (context, state) {
        // Dismiss any previous snackbar before showing the new one.
        if (state is AuthError) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: Theme.of(context).colorScheme.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
        }
      },
      builder: (context, state) {
        final c = context.colors;
        return Scaffold(
          backgroundColor: c.surfaceBase,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(flex: 2),
                      _AppLogo(),
                      const SizedBox(height: 48),
                      _Headline(),
                      const SizedBox(height: 12),
                      _Subheadline(),
                      const Spacer(flex: 3),
                      _SignInButton(),
                      const SizedBox(height: 12),
                      // Inline error — always visible, even on first mount.
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: state is AuthError
                            ? _ErrorBanner(
                                key: ValueKey(state.message),
                                message: state.message,
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 12),
                      _PrivacyNote(),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AppLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: c.logoContainerBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.logoContainerBorder, width: 1),
          ),
          child: const Icon(
            Icons.mail_outline_rounded,
            size: 36,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'NightMail',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      'Sign in to get started',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: c.textSecondary,
        fontSize: 16,
        fontWeight: FontWeight.w400,
      ),
    );
  }
}

class _Subheadline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      'Connect your Office 365 account to access your inbox.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: c.textMuted,
        fontSize: 14,
        height: 1.5,
      ),
    );
  }
}

class _SignInButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        final isLoading = state is AuthLoading;

        return SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: isLoading
                ? null
                : () => context
                    .read<AuthBloc>()
                    .add(const AuthSignInRequested()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2F2FA2),
              foregroundColor: Colors.white,
              disabledBackgroundColor: c.logoContainerBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 0,
            ),
            child: isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white54,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MicrosoftLogo(),
                      const SizedBox(width: 12),
                      const Flexible(
                        child: Text(
                          'Continue with Microsoft',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// Microsoft "four squares" logo drawn with Canvas.
class _MicrosoftLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(painter: _MicrosoftLogoPainter()),
    );
  }
}

class _MicrosoftLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    final gap = size.width * 0.05;
    final sq = half - gap;

    void drawSquare(double x, double y, Color color) {
      canvas.drawRect(
        Rect.fromLTWH(x, y, sq, sq),
        Paint()..color = color,
      );
    }

    drawSquare(0, 0, const Color(0xFFF25022));         // red  — top-left
    drawSquare(half + gap, 0, const Color(0xFF7FBA00)); // green — top-right
    drawSquare(0, half + gap, const Color(0xFF00A4EF)); // blue  — bottom-left
    drawSquare(half + gap, half + gap, const Color(0xFFFFB900)); // yellow
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PrivacyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      'Your credentials are handled entirely by Microsoft.\nNightMail never sees your password.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: c.textDimmed,
        fontSize: 12,
        height: 1.6,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.errorBannerBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.errorBannerBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 16, color: Color(0xFFEF4444)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: c.errorBannerText,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
