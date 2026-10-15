/// What a fresh server listing must be reconciled against: the messages the
/// user has just taken out of view, and — for a move — the folder each one went
/// to.
///
/// A move used to be reconciled as a plain removal, folder-blind, and that is
/// wrong for exactly one folder: the destination. `EmailRepositoryImpl.moveEmail`
/// re-files the cached row there the moment the user drops it, so opening the
/// destination shows the message straight away; but the first network listing
/// of that folder then
///
/// - **dropped it on Gmail**, where a move is a label change and the message
///   keeps its id, so the tombstone matched it in its new home; and
/// - **wiped it everywhere else** whenever the listing did not name it yet — a
///   move still in the outbox, an Exchange replica seconds behind the one the
///   drain moved it on, or IMAP, where the drain cannot learn the UID the
///   destination assigned — because a folder's first page *replaces* its cached
///   rows.
///
/// [tombstonedFor] answers the first and [arrivalsIn] the second. Shared by
/// `EmailRepositoryImpl` and `MailPollerCubit` so both reconciliations agree.
library;

import 'dart:convert';

import '../../data/datasources/local/pending_operations_datasource.dart';
import '../../domain/entities/email.dart';
import 'recent_mutation_store.dart';

class PendingRemovals {
  PendingRemovals._(this._removals, this._arrivals);

  /// Built from this account's queued ops and the [recent] store's grace
  /// entries. A queued op is the more current of the two, and among queued
  /// ops the last one for a message wins — a move then a delete is a delete.
  factory PendingRemovals.from(
    String accountId,
    List<PendingOperationRecord> pendingOps,
    RecentMutationStore recent,
  ) {
    final removals = <String, String?>{...recent.recentRemovals(accountId)};
    final pendingMoves = <String, String>{};
    for (final op in pendingOps) {
      switch (op.opType) {
        case PendingOperationType.move:
          final destination = _destinationOf(op);
          removals[op.emailId] = destination;
          if (destination != null) {
            pendingMoves[op.emailId] = destination;
          } else {
            pendingMoves.remove(op.emailId);
          }
        case PendingOperationType.delete:
        case PendingOperationType.junk:
        case PendingOperationType.notJunk:
          removals[op.emailId] = null;
          pendingMoves.remove(op.emailId);
        case PendingOperationType.markRead:
        case PendingOperationType.emptyFolder:
        case PendingOperationType.spamDbPush:
          break;
      }
    }
    // Only ids known to exist in the destination: a queued move's (the row the
    // repository re-filed) and the id the drain was told the move landed under.
    // Not a recent removal's own id — on IMAP the drain learns no new UID, so
    // the source's `mailbox:uid` would sit beside the destination's real one.
    // An arrival a later removal sent somewhere else, or deleted, is void.
    final arrivals = <String, String>{
      ...recent.recentArrivals(accountId),
      ...pendingMoves,
    }..removeWhere((id, folder) =>
        removals.containsKey(id) && removals[id] != folder);
    return PendingRemovals._(removals, arrivals);
  }

  static String? _destinationOf(PendingOperationRecord op) {
    try {
      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      return payload['destinationFolderId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Id → the folder a move took it to, or null for a delete/junk.
  final Map<String, String?> _removals;

  /// Id → the folder it has just been filed into.
  final Map<String, String> _arrivals;

  /// Every id taken out of view, wherever it went.
  Set<String> get all => _removals.keys.toSet();

  /// The ids a listing of [folderId] must drop: everything removed, except a
  /// message moved *into* [folderId]. A null [folderId] is a mailbox-wide
  /// listing, where nothing is excepted.
  Set<String> tombstonedFor(String? folderId) => {
        for (final MapEntry(:key, :value) in _removals.entries)
          if (folderId == null || value != folderId) key,
      };

  /// Whether [id] has just been filed into a folder by a move — so a report
  /// that it left some *other* folder is that move, not a reason to forget it.
  bool isArriving(String id) => _arrivals.containsKey(id);

  /// The ids just filed into [folderId].
  Set<String> arrivalsIn(String? folderId) => folderId == null
      ? const {}
      : {
          for (final MapEntry(:key, :value) in _arrivals.entries)
            if (value == folderId) key,
        };

  /// Returns [listing] with the cached copy of every message just filed into
  /// [folderId] that the listing does not name yet, each in date order.
  ///
  /// Only for a listing that stands for the folder's whole first page — the
  /// one whose cache write replaces the folder — or a load-more page would
  /// repeat rows already on screen. [cachedById] answers from the cache; a copy
  /// that is not filed under [folderId] (the drain has since renamed it, or it
  /// was never cached) is left out.
  Future<List<Email>> withArrivals(
    List<Email> listing, {
    required String? folderId,
    required Future<Email?> Function(String id) cachedById,
  }) async {
    final missing = arrivalsIn(folderId)
        .difference({for (final e in listing) e.id});
    if (missing.isEmpty) return listing;

    final result = [...listing];
    for (final id in missing) {
      final cached = await cachedById(id);
      if (cached == null || !cached.isInFolder(folderId)) continue;
      final at = result.indexWhere(
          (e) => e.receivedDateTime.isBefore(cached.receivedDateTime));
      result.insert(at < 0 ? result.length : at, cached);
    }
    return result;
  }
}
