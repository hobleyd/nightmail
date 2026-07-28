/// Escapes the SQL `LIKE` wildcards in a user-typed query so that a literal
/// `%` or `_` in an address (both legal in a local-part) matches itself instead
/// of acting as a wildcard.
///
/// Callers must pair this with `ESCAPE '\'` in the statement — SQLite has no
/// default escape character, so without the clause the backslashes this inserts
/// would themselves be matched literally.
String escapeLikePattern(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('%', r'\%')
    .replaceAll('_', r'\_');
