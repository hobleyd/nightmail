import 'email_remote_datasource.dart';
import 'imap_datasource_impl.dart';

/// Whether a folder listing from [datasource] is in date order, newest first —
/// so the stretch of dates a page covers is a stretch of the folder. Graph
/// lists messages by date and Gmail threads by their latest message; both also
/// carry every message of each thread on the page (the cross-folder
/// expansion).
///
/// IMAP lists by UID, the order mail *arrived in that mailbox*: an Archive
/// filled by moves holds years-old messages at the top, so a page's dates say
/// nothing about what it covers, and a coverage built from them claimed years
/// the cache had never seen — Load More then continued from below them. See
/// `ListingWindow.dateOrdered`.
bool listingIsDateOrdered(EmailRemoteDatasource datasource) =>
    datasource is! ImapDatasourceImpl;
