import 'package:equatable/equatable.dart';

import 'cloud_document.dart';

/// Which of an account's file collections the compose picker is listing.
///
/// [sharedWithMe] is not offered for a NightMail Server (Nightware answers it
/// `501`, and Microsoft is retiring it too); [sharedDrives] is Google only.
enum CloudFileCollection { myFiles, sharedWithMe, sharedDrives }

/// One file or folder in a cloud drive, as the compose window's picker lists
/// it — the thing "Attach from Cloud" downloads and "Link from Cloud" links to.
///
/// Distinct from [CloudDocumentLink], which is a URL found in a *received*
/// body: this is an item the sender browsed to, so it carries the ids the
/// provider needs to fetch, inspect and share it directly.
class CloudFile extends Equatable {
  const CloudFile({
    required this.accountId,
    required this.provider,
    required this.id,
    required this.name,
    required this.isFolder,
    this.driveId,
    this.size,
    this.mimeType,
    this.modified,
    this.webUrl,
  });

  /// The signed-in account that listed it, and therefore the one that fetches,
  /// inspects and shares it.
  final String accountId;
  final CloudDriveProvider provider;

  /// The provider's item id: a Graph driveItem id, a Drive file id, or (for a
  /// Google shared drive listed as a folder) the shared drive's id.
  final String id;

  /// Graph only: the drive holding [id]. Null for the caller's own drive and
  /// for Google, where a file id is global.
  final String? driveId;

  final String name;
  final bool isFolder;
  final int? size;
  final String? mimeType;
  final DateTime? modified;

  /// The provider's own "open this item" URL — what a link in the message
  /// points at. Opens for anybody who already has access to the item.
  final String? webUrl;

  /// A Google Docs/Sheets/Slides/Drawings file: no bytes of its own, so
  /// attaching it means exporting it to the matching Office format.
  bool get isGoogleEditorFile =>
      provider == CloudDriveProvider.google &&
      (mimeType?.startsWith('application/vnd.google-apps.') ?? false);

  @override
  List<Object?> get props => [accountId, provider, id, driveId];
}

/// A signed-in account the picker can browse.
class CloudFileSource extends Equatable {
  const CloudFileSource({
    required this.accountId,
    required this.email,
    required this.provider,
    required this.hasReadAccess,
  });

  final String accountId;
  final String email;

  /// [CloudDriveProvider.microsoft] for Microsoft 365, [CloudDriveProvider.google]
  /// for Gmail, [CloudDriveProvider.nextcloud] for a NightMail Server.
  final CloudDriveProvider provider;

  /// False until the account has been asked for (and granted) read access to
  /// its files — the picker then offers the grant instead of a listing.
  final bool hasReadAccess;

  List<CloudFileCollection> get collections => switch (provider) {
        CloudDriveProvider.microsoft => const [
            CloudFileCollection.myFiles,
            CloudFileCollection.sharedWithMe,
          ],
        CloudDriveProvider.google => const [
            CloudFileCollection.myFiles,
            CloudFileCollection.sharedWithMe,
            CloudFileCollection.sharedDrives,
          ],
        CloudDriveProvider.nextcloud => const [CloudFileCollection.myFiles],
      };

  @override
  List<Object?> get props => [accountId, email, provider, hasReadAccess];
}

/// Who can open a linked [CloudFile], as far as the provider will say.
class CloudFileAccess extends Equatable {
  const CloudFileAccess({
    required this.recipientsWithoutAccess,
    this.anyoneLinkUrl,
    this.canShare = true,
  });

  /// Recipients no permission on the item covers. Empty means everyone can
  /// open the link — or that the provider would not say, in which case there
  /// is nothing useful to ask the sender either.
  final List<String> recipientsWithoutAccess;

  /// An existing "anyone with the link" sharing URL for the item. Linking to
  /// it rather than [CloudFile.webUrl] lets every recipient open the file
  /// without being granted anything.
  final String? anyoneLinkUrl;

  /// Whether the signed-in user may grant access to the item at all. A file
  /// someone else shared read-only cannot be re-shared, so "share with them"
  /// is not offered.
  final bool canShare;

  static const everyone = CloudFileAccess(recipientsWithoutAccess: []);

  @override
  List<Object?> get props => [recipientsWithoutAccess, anyoneLinkUrl, canShare];
}

/// The outcome of sharing a file with recipients: those the provider refused,
/// with its reason. Empty means everyone was granted access.
class CloudShareResult extends Equatable {
  const CloudShareResult({this.failed = const {}});

  final Map<String, String> failed;

  @override
  List<Object?> get props => [failed];
}
