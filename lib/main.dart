import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'injection_container.dart';
import 'presentation/blocs/auth/auth_bloc.dart';
import 'presentation/blocs/auth/auth_event.dart';
import 'presentation/blocs/auth/auth_state.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/pages/sign_in_page.dart';

/// Azure AD app registration values.
/// Supply via --dart-define at build time:
///   flutter run --dart-define=AZURE_CLIENT_ID=xxx --dart-define=AZURE_TENANT_ID=yyy
const _clientId = String.fromEnvironment(
  'AZURE_CLIENT_ID',
  defaultValue: 'YOUR_CLIENT_ID',
);
const _tenantId = String.fromEnvironment(
  'AZURE_TENANT_ID',
  defaultValue: 'common',
);
const _redirectUri = String.fromEnvironment(
  'AZURE_REDIRECT_URI',
  defaultValue: 'nightmail://auth-callback',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await configureDependencies(
    clientId: _clientId,
    tenantId: _tenantId,
    redirectUri: _redirectUri,
  );

  runApp(const NightMailApp());
}

class NightMailApp extends StatelessWidget {
  const NightMailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<AuthBloc>(
      create: (_) => sl<AuthBloc>()..add(const AuthCheckRequested()),
      child: MaterialApp(
        title: 'NightMail',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C83FD),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

/// Switches between [SignInPage] and [HomePage] based on [AuthBloc] state,
/// with a fade transition between them.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (state) {
            AuthInitial() || AuthLoading() => const _SplashScreen(),
            AuthAuthenticated() => const HomePage(),
            AuthUnauthenticated() || AuthError() => const SignInPage(),
          },
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0F1117),
      body: Center(
        child: CircularProgressIndicator(
          color: Color(0xFF7C83FD),
          strokeWidth: 2,
        ),
      ),
    );
  }
}
