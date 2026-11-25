import 'package:nightmail/data/datasources/local/chat_local_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';

/// [ChatLocalDatasource] in memory, for repository tests that are not about
/// the cache.
class MemoryChatLocalDatasource implements ChatLocalDatasource {
  final lists = <String, List<ChatConversation>>{};
  final messageLists = <String, List<ChatMessage>>{};

  @override
  Future<List<ChatConversation>> conversations(String accountId) async =>
      lists[accountId] ?? const [];

  @override
  Future<void> saveConversations(
          String accountId, List<ChatConversation> conversations) async =>
      lists[accountId] = conversations;

  @override
  Future<List<ChatMessage>> messages(
          String accountId, String conversationKey) async =>
      messageLists['$accountId|$conversationKey'] ?? const [];

  @override
  Future<void> saveMessages(String accountId, String conversationKey,
          List<ChatMessage> messages) async =>
      messageLists['$accountId|$conversationKey'] =
          messages.take(ChatLocalDatasource.maxMessages).toList();

  @override
  Future<void> clear(String accountId) async {
    lists.remove(accountId);
    messageLists.removeWhere((k, _) => k.startsWith('$accountId|'));
  }
}
