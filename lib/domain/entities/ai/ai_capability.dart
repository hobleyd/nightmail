/// An AI feature category that can be routed to a specific provider + model.
///
/// Each value maps to a use case in the AI subsystem (compose/smart-reply,
/// thread summarization, triage/categorization, and semantic "ask my inbox"
/// search). Per-capability routing is stored in the AI settings repository, so
/// the user can, for example, route [triage] to a local model while [compose]
/// uses a cloud one.
enum AiCapability {
  /// Compose / smart-reply — drafting and replying to mail (first slice).
  compose,

  /// Thread summarization.
  summarize,

  /// Triage / categorization (extends the bayesian spam filter path).
  triage,

  /// Semantic "ask my inbox" search.
  search,
}
