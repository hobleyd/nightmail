// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/auth_service.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/presentation/blocs/auth/auth_bloc.dart';
import 'package:nightmail/presentation/blocs/auth/auth_event.dart';
import 'package:nightmail/presentation/blocs/auth/auth_state.dart';
import 'package:nightmail/presentation/pages/sign_in_page.dart';

import 'widget_test.mocks.dart';

@GenerateMocks([AuthService])
void main() {
  late MockAuthService mockAuthService;

  setUp(() {
    final dummy = AuthToken(
      accessToken: '',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
    provideDummy<AuthToken>(dummy);
    mockAuthService = MockAuthService();
  });

  Widget buildWithAuthBloc(AuthState initialState) {
    return BlocProvider<AuthBloc>(
      create: (_) {
        when(mockAuthService.getStoredToken()).thenAnswer((_) async => null);
        final bloc = AuthBloc(authService: mockAuthService);
        bloc.emit(initialState);
        return bloc;
      },
      child: const MaterialApp(home: SignInPage()),
    );
  }

  testWidgets('SignInPage shows app name and sign-in button',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildWithAuthBloc(const AuthUnauthenticated()));

    expect(find.text('NightMail'), findsOneWidget);
    expect(find.text('Continue with Microsoft'), findsOneWidget);
  });

  testWidgets('SignInPage shows loading indicator while authenticating',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildWithAuthBloc(const AuthLoading()));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Continue with Microsoft'), findsNothing);
  });

  testWidgets('SignInPage shows snackbar when sign-in fails',
      (WidgetTester tester) async {
    when(mockAuthService.signIn())
        .thenThrow(const AuthException(message: 'Sign-in failed'));

    await tester.pumpWidget(buildWithAuthBloc(const AuthUnauthenticated()));
    await tester.tap(find.text('Continue with Microsoft'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in failed'), findsOneWidget);
  });
}
