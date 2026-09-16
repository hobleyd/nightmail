/// Whether a Gmail label id is one of the inbox *categories* rather than a
/// place the user filed a message in.
///
/// Gmail stamps every message it classifies with one of `CATEGORY_PERSONAL`,
/// `CATEGORY_SOCIAL`, `CATEGORY_PROMOTIONS`, `CATEGORY_UPDATES` or
/// `CATEGORY_FORUMS`. They are the Inbox's tabs, not folders — nobody moved a
/// message into Personal, and a reader told a message is "in Personal" will go
/// looking for a folder they never put it in.
///
/// They *are* exposed as folders (`GmailDatasourceImpl.getMailFolders` turns
/// them into `Category/Personal` and friends), because browsing a category is
/// the only way to reach one in an app with no inbox tabs. So this is not about
/// hiding them — see `isHiddenGmailSystemLabel` for that set, which must stay
/// in step with a message's reported folder membership. This is about the
/// places that have to answer "which *one* folder does this message belong
/// to": a category is never the interesting answer when a real label is
/// available, and it is a misleading one when it is not.
library;

/// The five ids, which are stable well-known Gmail system labels.
const _gmailCategoryLabelIds = {
  'CATEGORY_PERSONAL',
  'CATEGORY_SOCIAL',
  'CATEGORY_PROMOTIONS',
  'CATEGORY_UPDATES',
  'CATEGORY_FORUMS',
};

/// Whether [folderId] is a Gmail inbox category.
///
/// Matched by exact id rather than the `CATEGORY_` prefix: the set is closed
/// and Google has not added to it, while a *user* label is free to be called
/// anything — including `CATEGORY_WHATEVER` — and a user label is exactly the
/// thing this must not swallow.
bool isGmailCategoryLabel(String folderId) =>
    _gmailCategoryLabelIds.contains(folderId);
