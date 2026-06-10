abstract interface class DeltaTokenDatasource {
  Future<String?> loadDeltaToken(String accountId, String folderId);
  Future<void> saveDeltaToken(String accountId, String folderId, String deltaLink);
  Future<void> clearDeltaTokensForAccount(String accountId);
}
