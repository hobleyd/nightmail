import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// Chat and channel scopes are incremental. A refresh must keep asking for
/// what was granted (or chat reads as lapsed an hour later) and must never
/// ask for what was not (or every refresh fails) — `ChannelMessage.Read.All`
/// in particular, which needs a tenant administrator.
MicrosoftAuthService _microsoft() => MicrosoftAuthService(
      clientId: 'client',
      tenantId: 'common',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
    );

AuthToken _token(String scope) => AuthToken(
      accessToken: 'a',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'r',
      scope: scope,
    );

void main() {
  test('no chat scope is asked for when signing an account in', () {
    expect(MicrosoftAuthService.baseScopes,
        isNot(contains(MicrosoftAuthService.chatScope)));
    for (final s in MicrosoftAuthService.channelScopes) {
      expect(MicrosoftAuthService.baseScopes, isNot(contains(s)));
    }
  });

  test('Chat.Read is not read as Chat.ReadWrite', () {
    expect(MicrosoftAuthService.grantsChat('openid Chat.Read'), isFalse);
    expect(MicrosoftAuthService.grantsChat('openid Chat.ReadWrite'), isTrue);
    expect(
        MicrosoftAuthService.grantsChat(
            'openid https://graph.microsoft.com/Chat.ReadWrite'),
        isTrue);
  });

  test('channels need every channel scope', () {
    expect(
        MicrosoftAuthService.grantsChannels(
            'Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Send'),
        isFalse);
    expect(
        MicrosoftAuthService.grantsChannels('Team.ReadBasic.All '
            'Channel.ReadBasic.All ChannelMessage.Read.All '
            'ChannelMessage.Send'),
        isTrue);
  });

  test('a refresh keeps chat, and channels only when all were granted', () {
    final chatOnly = _microsoft().refreshScopesFor(_token('openid Chat.ReadWrite'));
    expect(chatOnly, contains(MicrosoftAuthService.chatScope));
    for (final s in MicrosoftAuthService.channelScopes) {
      expect(chatOnly, isNot(contains(s)));
    }

    final both = _microsoft().refreshScopesFor(_token('openid Chat.ReadWrite '
        'Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Read.All '
        'ChannelMessage.Send'));
    expect(both, containsAll(MicrosoftAuthService.channelScopes));

    final none = _microsoft().refreshScopesFor(_token('openid Mail.Read'));
    expect(none, isNot(contains(MicrosoftAuthService.chatScope)));
  });
}
