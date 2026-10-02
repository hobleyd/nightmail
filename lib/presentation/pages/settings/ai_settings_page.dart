import 'package:flutter/material.dart';
import '../../widgets/adaptive_switch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/ai/ai_capability.dart';
import '../../../domain/entities/ai/ai_decision.dart';
import '../../../domain/entities/ai/ai_model.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_catalog_repository.dart';
import '../../../domain/repositories/ai/ai_inference_repository.dart';
import '../../../injection_container.dart';
import '../../blocs/ai/ai_settings_cubit.dart';
import '../../blocs/ai/ai_settings_state.dart';

/// AI settings section.
///
/// Three halves:
///
/// * **Configured providers** — the (initially empty) durable list of providers
///   the user has set up (BYO endpoints and catalog picks). Each row stores an
///   API key (optional for local/BYO endpoints) and can be removed.
/// * **Features** — one row per AI feature, each routed to a configured
///   provider + model. *Compose* (drafting/replying, plus the folder agent)
///   takes chat models; *Triage* takes System One typed-decision models (Jev,
///   Laya-MLX), which answer yes/no, choice and score questions and cannot
///   write text — so each row only offers the providers it can actually use.
/// * **Privacy** — the cloud-bodies guard (default OFF/safe): whether the quoted
///   original email body may be sent to a *cloud* provider during compose.
///
/// Unlike the sibling settings sections (`_AppearanceSection`, `_GeneralSection`,
/// `_SecuritySection`), which are private inline widgets in `settings_page.dart`,
/// this section is intentionally a standalone public page: it is large enough to
/// warrant its own file and is already well-decomposed into ~13 private widgets
/// below, so it lives in `pages/settings/` rather than bloating the host page.
///
/// Self-contained: it provides its own [AiSettingsCubit] from `get_it`.
class AiSettingsPage extends StatelessWidget {
  const AiSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<AiSettingsCubit>(
      create: (_) => sl<AiSettingsCubit>()..load(),
      child: const _AiSettingsView(),
    );
  }
}

class _AiSettingsView extends StatefulWidget {
  const _AiSettingsView();

  @override
  State<_AiSettingsView> createState() => _AiSettingsViewState();
}

/// A row of the Features table: which [AiCapability] it routes, and which
/// configured providers may serve it. Compose needs a text model; Triage
/// needs a System One (typed decision) model — the two sets are disjoint, so
/// a provider is only ever offered where a request to it can succeed.
class _Feature {
  const _Feature({
    required this.capability,
    required this.label,
    required this.isEligible,
    required this.emptyHint,
  });

  final AiCapability capability;
  final String label;
  final bool Function(AiProvider provider) isEligible;

  /// Shown in place of the provider dropdown when no configured provider is
  /// eligible, naming what to add.
  final String emptyHint;
}

bool _isChatProvider(AiProvider p) => p.supportsChat;
bool _isDecisionProvider(AiProvider p) => p.supportsDecisions;

/// The catalog id of the synthesized Laya-MLX entry (see `AiCatalogMapper`).
/// Its endpoint is a Jev-compatible bridge on this machine that is
/// provisioned *outside* NightMail, so a refused connection there is
/// explained as "not running" rather than left as a bare socket error.
const String _layaMlxProviderId = 'laya-mlx';

/// The Features table, top to bottom. New features slot in as new entries.
const _features = <_Feature>[
  _Feature(
    capability: AiCapability.compose,
    label: 'Compose',
    isEligible: _isChatProvider,
    emptyHint: 'Add a chat provider (OpenAI, Anthropic, Ollama…) to enable.',
  ),
  _Feature(
    capability: AiCapability.triage,
    label: 'Triage',
    isEligible: _isDecisionProvider,
    emptyHint: 'Add a System One provider (Jev, Laya-MLX) to enable.',
  ),
];

/// Per-feature UI state for one row of the Features table: the locally
/// selected provider (before its routing is committed), the model field, and
/// the model list loaded for that provider.
///
/// Each feature owns its own slot. A single shared loader would thrash: every
/// rebuild has each row re-assert *its* provider, so two rows pointing at
/// different providers would re-fetch each other's model lists forever.
class _FeatureSlot {
  final modelController = TextEditingController();

  /// Locally-selected provider before its routing is committed.
  String? providerId;

  /// Provider whose saved model has been restored into [modelController], so
  /// the field is seeded from persisted routing exactly once per load.
  String? seededFor;

  /// Provider the lists below were loaded for.
  String? modelsLoadedFor;
  bool modelsLoading = false;

  /// Catalog models for the in-focus provider (BYO providers carry none, so
  /// the model becomes a free-text field unless a live list is available).
  List<AiModel> models = const [];

  /// Live model ids fetched from a provider's own `/models` endpoint (Ollama,
  /// the Laya-MLX bridge, …). Used to drive the same dropdown catalog
  /// providers get.
  List<String> liveModelIds = const [];

  /// Set when a live `/models` fetch for [modelsLoadedFor] failed (endpoint
  /// unreachable, non-2xx, bad shape, …), so the UI can tell "the server
  /// refused/couldn't be reached" apart from "it has no models" and offer a
  /// retry instead of silently falling back to a blank free-text field.
  String? modelsLoadErrorFor;

  /// The actual failure message for [modelsLoadErrorFor], shown in the UI —
  /// a generic "couldn't reach it" label hides whether the real problem was a
  /// connection failure, a timeout, or the endpoint returning something this
  /// app doesn't understand, all of which need different fixes.
  String? modelsLoadErrorMessage;

  void dispose() => modelController.dispose();
}

class _AiSettingsViewState extends State<_AiSettingsView> {
  final _apiKeyController = TextEditingController();

  /// Configured provider currently expanded for key editing (null = collapsed).
  String? _expandedId;
  bool _obscureKey = true;
  String? _keyLoadedFor;

  /// One slot per Features-table row (see [_FeatureSlot]).
  final _slots = <AiCapability, _FeatureSlot>{
    for (final feature in _features) feature.capability: _FeatureSlot(),
  };

  @override
  void dispose() {
    _apiKeyController.dispose();
    for (final slot in _slots.values) {
      slot.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Features (Compose, Triage, …)
  // ---------------------------------------------------------------------------

  String? _selectedProvider(_Feature feature, AiSettingsState state) {
    return _slots[feature.capability]!.providerId ??
        state.routingFor(feature.capability)?.providerId;
  }

  void _selectProvider(
    _Feature feature,
    String providerId,
    AiSettingsState state,
  ) {
    final slot = _slots[feature.capability]!;
    final route = state.routingFor(feature.capability);
    setState(() {
      slot.providerId = providerId;
      slot.modelController.text =
          route?.providerId == providerId ? route!.modelId : '';
    });
    for (final p in state.configured) {
      if (p.id == providerId) {
        _ensureModelsLoaded(slot, p);
        break;
      }
    }
  }

  void _commitRouting(_Feature feature, String providerId) {
    final slot = _slots[feature.capability]!;
    final model = slot.modelController.text.trim();
    if (model.isEmpty) {
      _snack('Enter a model id');
      return;
    }
    FocusScope.of(context).unfocus();
    context.read<AiSettingsCubit>().setRouting(
          capability: feature.capability,
          providerId: providerId,
          modelId: model,
        );
    _snack('${feature.label} will use $model');
  }

  /// Loads the model list for [provider] into [slot]: the static catalog for
  /// catalog providers, or a live `/models` fetch for BYO/self-hosted and
  /// local endpoints (Ollama, LM Studio, the Laya-MLX bridge, …) so they get
  /// a real dropdown too.
  ///
  /// Pass [retry] to force a re-fetch even though [provider] was already
  /// (unsuccessfully) attempted this session — the normal guard below only
  /// dedupes concurrent/repeated calls for the *same* provider, it doesn't
  /// retry a failed live fetch on its own (a down local server shouldn't be
  /// hammered on every rebuild).
  void _ensureModelsLoaded(
    _FeatureSlot slot,
    AiProvider provider, {
    bool retry = false,
  }) {
    if (provider.id == slot.modelsLoadedFor && !retry) return;
    slot.modelsLoadedFor = provider.id;
    slot.models = const [];
    slot.liveModelIds = const [];
    slot.modelsLoadErrorFor = null;
    slot.modelsLoadErrorMessage = null;
    slot.modelsLoading = true;

    final repo = sl<AiCatalogRepository>();
    final cubit = context.read<AiSettingsCubit>();

    // `defaultBaseUrl` already returns `apiBaseUrl` when one is persisted
    // (normalizing an Ollama / System One endpoint to end in `/v1`) and only
    // computes a true default otherwise (e.g. a catalog pick that stores
    // none) — the same getter the inference path uses, so listing and
    // inference always agree on where a provider actually lives.
    final baseUrl = provider.defaultBaseUrl;
    final hasUrl = baseUrl != null && baseUrl.isNotEmpty;
    // Detect Azure by protocol OR endpoint host, so a stale wireProtocol on the
    // persisted row still routes to the deployments listing.
    final isAzure = provider.wireProtocol == AiWireProtocol.azure ||
        (hasUrl && baseUrl.contains('azure.com'));
    // Local runtimes (Ollama, LM Studio, the Laya-MLX bridge, …) always
    // reflect what's actually installed on the endpoint, never a static
    // catalog list — whether they were added as a catalog pick or a custom
    // endpoint.
    final preferLive = hasUrl &&
        (provider.source == AiProviderSource.user ||
            isAzure ||
            provider.kind == AiProviderKind.local);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      List<AiModel> catalogModels = const [];
      List<String> liveIds = const [];
      String? errorMessage;

      if (preferLive) {
        final key = await cubit.getApiKey(provider.id);
        final result = await repo.listLiveModels(
          baseUrl: baseUrl,
          apiKey: key,
          azure: isAzure,
        );
        result.match(
          (failure) => errorMessage = failure.message,
          (ids) => liveIds = ids,
        );
        // The Laya bridge is a local service; a refused connection means it
        // is not running, which is the whole diagnosis.
        final msg = errorMessage;
        if (msg != null &&
            provider.id == _layaMlxProviderId &&
            msg.toLowerCase().contains('connection')) {
          errorMessage =
              'The Laya-MLX bridge is not running at $baseUrl. Start it, '
              'then retry.';
        }
      } else if (provider.source == AiProviderSource.catalog) {
        final result = await repo.getModelsForProvider(provider.id);
        catalogModels = result.getOrElse((_) => const []);
      }

      if (!mounted || slot.modelsLoadedFor != provider.id) return;
      setState(() {
        slot.modelsLoading = false;
        slot.models = catalogModels;
        slot.liveModelIds = liveIds;
        slot.modelsLoadErrorFor = errorMessage != null ? provider.id : null;
        slot.modelsLoadErrorMessage = errorMessage;
      });
      if (errorMessage != null) {
        debugPrint(
          'AI settings: live model fetch failed for ${provider.id} '
          '($baseUrl): $errorMessage',
        );
      }
    });
  }

  /// The model id the "Test decision" probe should send for [provider]: the
  /// model Triage is routed to when that route points here, else the
  /// provider's first known model, else Jev's universal alias (which the
  /// Jev-compatible local servers and the Laya-MLX bridge all accept).
  String? _probeModelFor(AiProvider provider, AiSettingsState state) {
    if (!provider.supportsDecisions) return null;
    final route = state.routingFor(AiCapability.triage);
    if (route != null && route.providerId == provider.id) return route.modelId;
    for (final p in state.providers) {
      if (p.id == provider.id && p.models.isNotEmpty) return p.models.first.id;
    }
    final slot = _slots[AiCapability.triage]!;
    if (slot.modelsLoadedFor == provider.id && slot.liveModelIds.isNotEmpty) {
      return slot.liveModelIds.first;
    }
    return 'jev-latest';
  }

  // ---------------------------------------------------------------------------
  // Provider management
  // ---------------------------------------------------------------------------

  void _toggleExpanded(AiProvider provider) {
    final opening = _expandedId != provider.id;
    setState(() {
      _expandedId = opening ? provider.id : null;
      _obscureKey = true;
      if (opening) {
        _apiKeyController.text = '';
        _keyLoadedFor = null;
      }
    });
    if (opening) _ensureKeyLoaded(provider.id);
  }

  void _ensureKeyLoaded(String providerId) {
    if (providerId == _keyLoadedFor) return;
    _keyLoadedFor = providerId;
    final cubit = context.read<AiSettingsCubit>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final key = await cubit.getApiKey(providerId);
      if (!mounted || _keyLoadedFor != providerId) return;
      _apiKeyController.text = key ?? '';
    });
  }

  void _saveKey(AiProvider provider) {
    FocusScope.of(context).unfocus();
    context.read<AiSettingsCubit>().setApiKey(
          providerId: provider.id,
          apiKey: _apiKeyController.text.trim(),
        );
    _snack('API key saved');
  }

  Future<void> _removeProvider(AiProvider provider) async {
    await context.read<AiSettingsCubit>().removeProvider(provider.id);
    if (!mounted) return;
    setState(() => _expandedId = null);
    _snack('Removed ${provider.name}');
  }

  Future<void> _openAddProvider(AiSettingsState state) async {
    final cubit = context.read<AiSettingsCubit>();
    final catalog = state.providers
        .where((p) => p.source == AiProviderSource.catalog)
        .toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (_) => BlocProvider<AiSettingsCubit>.value(
        value: cubit,
        child: _AddProviderDialog(catalogProviders: catalog),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<AiSettingsCubit, AiSettingsState>(
      builder: (context, state) {
        switch (state.status) {
          case AiSettingsStatus.loading:
            return const Center(child: CircularProgressIndicator());
          case AiSettingsStatus.error:
            return Center(
              child: Text(
                state.errorMessage ?? 'Failed to load AI providers',
                style: TextStyle(color: c.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            );
          case AiSettingsStatus.loaded:
            return _buildLoaded(context, state);
        }
      },
    );
  }

  Widget _buildLoaded(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    final configured = state.configured;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _Label('Providers')),
              if (configured.isNotEmpty)
                _AddButton(onTap: () => _openAddProvider(state)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'AI backends you have configured.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
          if (configured.isEmpty)
            _EmptyConfigured(onAdd: () => _openAddProvider(state))
          else
            Column(
              children: [
                for (final provider in configured)
                  _ConfiguredTile(
                    provider: provider,
                    isExpanded: _expandedId == provider.id,
                    routedFeatures: [
                      for (final feature in _features)
                        if (state.routingFor(feature.capability)?.providerId ==
                            provider.id)
                          feature.label,
                    ],
                    onToggle: () => _toggleExpanded(provider),
                    editor: _expandedId == provider.id
                        ? _ProviderKeyEditor(
                            provider: provider,
                            apiKeyController: _apiKeyController,
                            obscureKey: _obscureKey,
                            onToggleObscure: () =>
                                setState(() => _obscureKey = !_obscureKey),
                            onSaveKey: () => _saveKey(provider),
                            onRemove: () => _removeProvider(provider),
                            decisionProbeModelId:
                                _probeModelFor(provider, state),
                          )
                        : null,
                  ),
              ],
            ),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _Label('Features'),
          const SizedBox(height: 4),
          Text(
            'Assign a configured provider and model to each AI feature.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildFeatures(context, state, configured),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _buildAgentCaps(context, state),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _buildPrivacy(context, state),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Folder agent — configurable safety caps
  // ---------------------------------------------------------------------------

  /// Two user-configurable bounds for the folder-reading agent loop: how many
  /// tool steps it may take per turn (`agentMaxRounds`) and how many emails it
  /// may read in one step (`agentMaxToolCallsPerRound`). Both default to the old
  /// compile-time constants (5 / 8) and clamp to 1–20, so the loop can never run
  /// unbounded. (`RunFolderAgent` reads the same settings to enforce them.)
  Widget _buildAgentCaps(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('Folder agent'),
        const SizedBox(height: 4),
        Text(
          'Limits on how hard the agent works through a folder when answering.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _AgentCapsSection(
          maxRounds: state.agentMaxRounds,
          maxToolCallsPerRound: state.agentMaxToolCallsPerRound,
          onMaxRoundsChanged: (v) =>
              context.read<AiSettingsCubit>().setAgentMaxRounds(v),
          onMaxToolCallsChanged: (v) =>
              context.read<AiSettingsCubit>().setAgentMaxToolCallsPerRound(v),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Privacy — cloud-bodies guard (default OFF / safe)
  // ---------------------------------------------------------------------------

  /// Toggle for `allowCloudForBodies`. When OFF (the conservative default) a
  /// compose routed to a **cloud** provider sends an instruction only — never
  /// the quoted original mail body. Local/self-hosted providers always receive
  /// the body, so the guard only narrows what leaves the machine to third
  /// parties. (`ComposeReply` reads the same flag to enforce this end-to-end.)
  Widget _buildPrivacy(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('Privacy'),
        const SizedBox(height: 4),
        Text(
          'Controls whether mail bodies may leave your machine for cloud '
          'providers.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _CloudBodiesToggle(
          value: state.allowCloudForBodies,
          onChanged: (v) =>
              context.read<AiSettingsCubit>().setAllowCloudForBodies(v),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Features table (compact — one row per feature)
  // ---------------------------------------------------------------------------

  Widget _buildFeatures(
    BuildContext context,
    AiSettingsState state,
    List<AiProvider> configured,
  ) {
    final c = context.colors;
    if (configured.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: c.separatorStrong),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Add a provider above to enable features.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < _features.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.separator),
            _featureRow(context, state, configured, _features[i]),
          ],
        ],
      ),
    );
  }

  Widget _featureRow(
    BuildContext context,
    AiSettingsState state,
    List<AiProvider> configured,
    _Feature feature,
  ) {
    final c = context.colors;
    final slot = _slots[feature.capability]!;
    final eligible = configured.where(feature.isEligible).toList(growable: false);
    final providerId = _selectedProvider(feature, state);
    AiProvider? selected;
    if (providerId != null) {
      // Registry view = authoritative wireProtocol + catalog models; config row
      // = durable user endpoint. Prefer the registry view but graft the config
      // row's base URL when the registry copy is missing one (e.g. a session
      // where the catalog snapshot predates the just-added endpoint).
      AiProvider? registryView;
      AiProvider? configRow;
      for (final p in state.providers) {
        if (p.id == providerId) {
          registryView = p;
          break;
        }
      }
      for (final p in configured) {
        if (p.id == providerId) {
          configRow = p;
          break;
        }
      }
      selected = registryView ?? configRow;
      final cfgUrl = configRow?.apiBaseUrl;
      if (selected != null &&
          cfgUrl != null &&
          cfgUrl.isNotEmpty &&
          (selected.apiBaseUrl == null || selected.apiBaseUrl!.isEmpty)) {
        selected = selected.copyWith(apiBaseUrl: cfgUrl);
      }
    }
    // Only offer what this feature can actually use: a stale route to a
    // provider that was removed, or that this feature can't drive, renders as
    // "no selection" rather than crashing the dropdown with a foreign value.
    if (selected != null && !eligible.any((p) => p.id == selected!.id)) {
      selected = null;
    }
    if (selected != null) _ensureModelsLoaded(slot, selected);

    // Restore the persisted model into the field once on load. Routing lives in
    // drift, but the text controller starts empty, so without this the saved
    // model would render blank even though it still drives the feature.
    final route = state.routingFor(feature.capability);
    if (slot.providerId == null &&
        route != null &&
        route.providerId == providerId &&
        slot.seededFor != providerId) {
      slot.seededFor = providerId;
      slot.modelController.text = route.modelId;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              feature.label,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (eligible.isEmpty)
            Expanded(
              flex: 10,
              child: _compactBox(
                context,
                child: Text(
                  feature.emptyHint,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ),
            )
          else ...[
            Expanded(
              flex: 5,
              child: _compactDropdown<String>(
                context,
                value: selected?.id,
                hint: 'Provider',
                items: [
                  for (final p in eligible)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(p.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) _selectProvider(feature, id, state);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: _modelCell(context, feature, slot, selected),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modelCell(
    BuildContext context,
    _Feature feature,
    _FeatureSlot slot,
    AiProvider? provider,
  ) {
    final c = context.colors;
    if (provider == null) {
      return _compactBox(context,
          child: Text('—', style: TextStyle(color: c.textMuted, fontSize: 12)));
    }
    if (slot.modelsLoading) {
      return _compactBox(context,
          child: Text('Loading…',
              style: TextStyle(color: c.textMuted, fontSize: 12)));
    }

    // Catalog providers → models.dev list; BYO providers → live `/models` list.
    final modelIds = slot.models.isNotEmpty
        ? [for (final m in slot.models) (id: m.id, label: m.name)]
        : [for (final id in slot.liveModelIds) (id: id, label: id)];

    if (modelIds.isEmpty) {
      final failed = slot.modelsLoadErrorFor == provider.id;
      // Endpoint unreachable / advertises nothing: fall back to manual entry.
      // When a live fetch actually failed (vs. a provider that just has no
      // models to enumerate), show the real failure reason and offer a retry
      // rather than a generic "unreachable" guess — a down/unstarted local
      // server is only one of several ways this can fail, and each needs a
      // different fix.
      final errorHint = slot.modelsLoadErrorMessage;
      return Row(
        children: [
          Expanded(
            child: Tooltip(
              message: failed && errorHint != null ? errorHint : '',
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: slot.modelController,
                  onSubmitted: (_) => _commitRouting(feature, provider.id),
                  style: TextStyle(color: c.textSecondary, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: failed
                        ? (errorHint ?? 'Couldn\'t load models')
                        : 'model id ⏎',
                    hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
                    hintMaxLines: 1,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: failed ? c.errorBannerBorder : c.separatorStrong,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (failed) ...[
            if (errorHint != null) ...[
              const SizedBox(width: 4),
              SizedBox(
                width: 32,
                height: 32,
                // Hint text and tooltips aren't selectable, so this is the only
                // way to get the actual error text out of this compact row.
                child: IconButton(
                  padding: EdgeInsets.zero,
                  splashRadius: 16,
                  iconSize: 16,
                  tooltip: 'Copy error',
                  icon: Icon(Icons.copy_rounded, color: c.textMuted),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: errorHint));
                    _snack('Error copied to clipboard');
                  },
                ),
              ),
            ],
            const SizedBox(width: 4),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                splashRadius: 16,
                iconSize: 16,
                tooltip: 'Retry',
                icon: Icon(Icons.refresh_rounded, color: c.textMuted),
                onPressed: () => setState(
                  () => _ensureModelsLoaded(slot, provider, retry: true),
                ),
              ),
            ),
          ],
        ],
      );
    }

    final value = modelIds.any((m) => m.id == slot.modelController.text)
        ? slot.modelController.text
        : null;
    return _compactDropdown<String>(
      context,
      value: value,
      hint: 'Model',
      items: [
        for (final m in modelIds)
          DropdownMenuItem(
            value: m.id,
            child: Text(m.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) {
        if (id != null) {
          setState(() => slot.modelController.text = id);
          _commitRouting(feature, provider.id);
        }
      },
    );
  }

  Widget _compactBox(BuildContext context, {required Widget child}) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: child,
    );
  }

  Widget _compactDropdown<T>(
    BuildContext context, {
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          hint: Text(hint, style: TextStyle(color: c.textMuted, fontSize: 12)),
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 12),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configured provider tile (key + remove)
// ---------------------------------------------------------------------------

class _ConfiguredTile extends StatelessWidget {
  const _ConfiguredTile({
    required this.provider,
    required this.isExpanded,
    required this.routedFeatures,
    required this.onToggle,
    required this.editor,
  });

  final AiProvider provider;
  final bool isExpanded;

  /// Labels of the features currently routed to this provider (badges).
  final List<String> routedFeatures;
  final VoidCallback onToggle;
  final Widget? editor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: isExpanded ? AppColors.accent : c.separatorStrong,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      provider.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final label in routedFeatures) ...[
                    _FeatureBadge(label),
                    const SizedBox(width: 8),
                  ],
                  if (provider.supportsDecisions) ...[
                    const _DecisionBadge(),
                    const SizedBox(width: 8),
                  ],
                  _KindBadge(kind: provider.kind),
                  const SizedBox(width: 8),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (editor != null) ...[
            Divider(height: 1, color: c.separator),
            Padding(padding: const EdgeInsets.all(12), child: editor),
          ],
        ],
      ),
    );
  }
}

/// Accent badge naming a feature routed to a provider ("Compose", "Triage").
class _FeatureBadge extends StatelessWidget {
  const _FeatureBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Marks a System One provider: it answers typed questions (yes/no, choice,
/// score) and cannot write text, so it drives Triage, never Compose.
class _DecisionBadge extends StatelessWidget {
  const _DecisionBadge();

  static const Color _color = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'System One model: typed decisions (yes/no, choice, score), '
          'not text generation. Used by Triage.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _color.withAlpha(28),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          'Decisions',
          style: TextStyle(
            color: _color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ProviderKeyEditor extends StatelessWidget {
  const _ProviderKeyEditor({
    required this.provider,
    required this.apiKeyController,
    required this.obscureKey,
    required this.onToggleObscure,
    required this.onSaveKey,
    required this.onRemove,
    this.decisionProbeModelId,
  });

  final AiProvider provider;
  final TextEditingController apiKeyController;
  final bool obscureKey;
  final VoidCallback onToggleObscure;
  final VoidCallback onSaveKey;
  final VoidCallback onRemove;

  /// Non-null for a System One provider: the model id the "Test decision"
  /// probe should send.
  final String? decisionProbeModelId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Catalog providers genuinely require a key; BYO/user endpoints may not
    // (local Ollama needs none), so the key is offered as optional there.
    final keyOptional = provider.source == AiProviderSource.user;
    final showKey = provider.requiresApiKey || provider.source == AiProviderSource.user;
    final probeModel = decisionProbeModelId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (provider.defaultBaseUrl != null) ...[
          Text(
            provider.defaultBaseUrl!,
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 12),
        ],
        if (provider.id == _layaMlxProviderId) ...[
          Text(
            'Runs the open Laya decision model on this Mac with Apple MLX, '
            'behind a Jev-compatible bridge at the address above. The bridge '
            'is provisioned outside NightMail and has to be running.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
        ],
        if (showKey)
          _ApiKeyField(
            controller: apiKeyController,
            obscure: obscureKey,
            optional: keyOptional,
            onToggleObscure: onToggleObscure,
          ),
        if (probeModel != null) ...[
          if (showKey) const SizedBox(height: 12),
          _DecisionProbe(provider: provider, modelId: probeModel),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              onPressed: onRemove,
              style: TextButton.styleFrom(foregroundColor: c.textMuted),
              child: const Text('Remove'),
            ),
            const Spacer(),
            if (showKey)
              ElevatedButton(
                onPressed: onSaveKey,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Save key'),
              ),
          ],
        ),
      ],
    );
  }
}

/// "Test decision" for a System One provider: sends one fixed sample email
/// through `AiInferenceRepository.decide` and shows the typed answers inline,
/// so a freshly added Jev key or a just-started Laya-MLX bridge can be
/// verified from the settings page without routing a feature first.
///
/// Reaches into `get_it` for the inference repository the same way the page
/// already does for the catalog repository's live model listing — a one-off
/// diagnostic, not state the cubit needs to own.
class _DecisionProbe extends StatefulWidget {
  const _DecisionProbe({required this.provider, required this.modelId});

  final AiProvider provider;
  final String modelId;

  @override
  State<_DecisionProbe> createState() => _DecisionProbeState();
}

class _DecisionProbeState extends State<_DecisionProbe> {
  bool _running = false;
  String? _result;
  String? _error;

  /// A realistic triage sample: the same three question types the Laya email
  /// preset uses (urgency score, needs-reply noul, department choice).
  static const AiDecisionRequest _sample = AiDecisionRequest(
    providerId: '',
    modelId: '',
    state: {
      'subject': 'Duplicate charge on September invoice',
      'from': 'accounts@example.com',
      'body': 'Hi team, the September invoice was charged twice. Can you '
          'refund the duplicate today? It is blocking our month-end close.',
    },
    questions: {
      'urgency': AiDecisionQuestion.score(
        instructions: 'How urgent is the request in `body`?',
        levels: [
          'no time pressure',
          'needs attention soon',
          'blocking issue or hard deadline',
        ],
      ),
      'needs_reply': AiDecisionQuestion.noul(
        instructions: 'Does the sender expect a reply?',
      ),
      'category': AiDecisionQuestion.choice(
        instructions: 'Which team should handle the email in `body`?',
        options: {
          'billing': 'invoices, payments, refunds',
          'technical': 'bugs, outages, integrations',
          'other': 'none of the above',
        },
      ),
    },
  );

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    final response = await sl<AiInferenceRepository>().decide(
      AiDecisionRequest(
        providerId: widget.provider.id,
        modelId: widget.modelId,
        state: _sample.state,
        questions: _sample.questions,
      ),
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      response.match(
        (failure) => _error = failure.message,
        (decision) {
          final model =
              decision.model.isEmpty ? widget.modelId : decision.model;
          final answers = [
            for (final entry in decision.answers.entries)
              '${entry.key}: ${entry.value.summary}',
          ];
          _result = '$model · ${answers.join(' · ')}';
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final message = _error ?? _result;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OutlinedButton(
          onPressed: _running ? null : _run,
          style: OutlinedButton.styleFrom(
            foregroundColor: c.textSecondary,
            side: BorderSide(color: c.separatorStrong),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _running ? 'Deciding…' : 'Test decision',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: message == null
              ? Text(
                  'Sends a sample email and shows the model\'s typed answers.',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                )
              : SelectableText(
                  message,
                  style: TextStyle(
                    color: _error != null ? c.errorBannerBorder : c.textSecondary,
                    fontSize: 11,
                  ),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state + add affordances
// ---------------------------------------------------------------------------

class _EmptyConfigured extends StatelessWidget {
  const _EmptyConfigured({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(Icons.auto_awesome_rounded, size: 22, color: c.textMuted),
          const SizedBox(height: 10),
          Text(
            'No providers configured yet',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add a provider to draft and reply to mail with AI.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add provider'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Add provider'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add provider dialog (custom endpoint | from catalog)
// ---------------------------------------------------------------------------

enum _AddMode { custom, catalog }

class _AddProviderDialog extends StatefulWidget {
  const _AddProviderDialog({required this.catalogProviders});

  final List<AiProvider> catalogProviders;

  @override
  State<_AddProviderDialog> createState() => _AddProviderDialogState();
}

class _AddProviderDialogState extends State<_AddProviderDialog> {
  _AddMode _mode = _AddMode.custom;

  // Custom endpoint form.
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  AiWireProtocol _protocol = AiWireProtocol.openai;

  // Catalog form.
  final _searchController = TextEditingController();
  final _catalogKeyController = TextEditingController();
  final _catalogUrlController = TextEditingController();
  String _query = '';
  AiProvider? _picked;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _searchController.dispose();
    _catalogKeyController.dispose();
    _catalogUrlController.dispose();
    super.dispose();
  }

  void _addCustom() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) return;

    // Ollama is local by definition. A Jev-compatible decision server is
    // local when it lives on this machine (local-jev, jevlocal, the Laya-MLX
    // bridge) and self-hosted otherwise; the other chat protocols keep their
    // existing self-hosted classification regardless of host.
    final isLocal = _protocol == AiWireProtocol.ollama ||
        (_protocol == AiWireProtocol.systemOne && _isLoopbackUrl(url));
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final provider = AiProvider(
      id: 'byo_${slug}_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      npm: '',
      doc: '',
      // BYO keys are optional everywhere (set later on the tile), so we never
      // mark them required here.
      env: const [],
      apiBaseUrl: url,
      kind: isLocal ? AiProviderKind.local : AiProviderKind.selfHosted,
      wireProtocol: _protocol,
      source: AiProviderSource.user,
    );
    context.read<AiSettingsCubit>().addConfiguredProvider(provider);
    Navigator.of(context).pop();
  }

  /// True for a URL on this machine (`localhost`, `127.0.0.1`, `::1`, or a
  /// `.local` mDNS name of our own host is *not* counted — only loopback).
  static bool _isLoopbackUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]' ||
        host.startsWith('127.');
  }

  Future<void> _addCatalog() async {
    final provider = _picked;
    if (provider == null) return;

    // Only some catalog providers need a user-supplied endpoint (Azure /
    // AI Foundry, gateways, unknown OpenAI-compatible hosts). First-party
    // providers (OpenAI/Anthropic/Google) carry a built-in default, so don't
    // prompt for those.
    final needsUrl = provider.defaultBaseUrl == null;
    final url = _catalogUrlController.text.trim();
    if (needsUrl && url.isEmpty) return;

    final toAdd = needsUrl
        ? AiProvider(
            id: provider.id,
            name: provider.name,
            npm: provider.npm,
            doc: provider.doc,
            env: provider.env,
            apiBaseUrl: url,
            kind: provider.kind,
            wireProtocol: provider.wireProtocol,
            source: provider.source,
          )
        : provider;

    final cubit = context.read<AiSettingsCubit>();
    await cubit.addConfiguredProvider(toAdd);
    final key = _catalogKeyController.text.trim();
    if (key.isNotEmpty) {
      await cubit.setApiKey(providerId: toAdd.id, apiKey: key);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add provider',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _ModeToggle(
                mode: _mode,
                onChanged: (m) => setState(() => _mode = m),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: _mode == _AddMode.custom
                      ? _buildCustom(context)
                      : _buildCatalog(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustom(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect a self-hosted or OpenAI-compatible endpoint (Ollama, '
          'LM Studio, vLLM, a proxy…). Pick Ollama for a local server with no '
          'API key, or System One for a Jev-compatible decision server '
          '(local-jev, jevlocal, OpenJev) used by Triage.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        _FormRow(
          label: 'Name',
          child: _PlainField(controller: _nameController, hint: 'Ollama'),
        ),
        const SizedBox(height: 12),
        _FormRow(
          label: 'Base URL',
          child: _PlainField(
            controller: _urlController,
            hint: 'http://localhost:11434/v1',
            keyboardType: TextInputType.url,
          ),
        ),
        const SizedBox(height: 12),
        _FormRow(
          label: 'Protocol',
          child: _ProtocolDropdown(
            protocol: _protocol,
            onChanged: (p) => setState(() => _protocol = p),
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton(
            onPressed: _addCustom,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }

  Widget _buildCatalog(BuildContext context) {
    final c = context.colors;
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.catalogProviders
        : widget.catalogProviders
            .where((p) =>
                p.name.toLowerCase().contains(query) ||
                p.id.toLowerCase().contains(query))
            .toList(growable: false);

    if (_picked != null) {
      final provider = _picked!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                splashRadius: 16,
                iconSize: 18,
                icon: Icon(Icons.arrow_back_rounded, color: c.textMuted),
                onPressed: () => setState(() => _picked = null),
              ),
              Expanded(
                child: Text(
                  provider.name,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (provider.supportsDecisions) ...[
                const _DecisionBadge(),
                const SizedBox(width: 8),
              ],
              _KindBadge(kind: provider.kind),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.supportsDecisions) ...[
            Text(
              'System One model: answers typed questions (yes/no, choice, '
              'score) about a message instead of writing text. Drives '
              'Triage, not Compose.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
          if (provider.defaultBaseUrl == null) ...[
            _FormRow(
              label: 'Base URL',
              child: _PlainField(
                controller: _catalogUrlController,
                hint: 'https://<resource>.openai.azure.com/openai/v1',
                keyboardType: TextInputType.url,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This provider has no fixed endpoint — paste your '
              'per-resource / project URL.',
              style: TextStyle(color: c.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
          ],
          if (provider.requiresApiKey)
            _ApiKeyField(
              controller: _catalogKeyController,
              obscure: true,
              optional: false,
              onToggleObscure: () {},
            )
          else
            Text(
              'This provider needs no API key.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _addCatalog,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Add'),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SearchField(
          controller: _searchController,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: 280),
          decoration: BoxDecoration(
            border: Border.all(color: c.separatorStrong),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      'No providers match your search',
                      style: TextStyle(color: c.textMuted, fontSize: 13),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, thickness: 1, color: c.separator),
                  itemBuilder: (context, index) {
                    final provider = filtered[index];
                    return InkWell(
                      onTap: () => setState(() => _picked = provider),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (provider.requiresApiKey) ...[
                              Text(
                                'needs key',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (provider.supportsDecisions) ...[
                              const _DecisionBadge(),
                              const SizedBox(width: 8),
                            ],
                            _KindBadge(kind: provider.kind),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final _AddMode mode;
  final ValueChanged<_AddMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget tab(String label, _AddMode value) {
      final selected = mode == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.accent.withAlpha(28) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.accent : c.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: Row(
        children: [
          tab('Custom endpoint', _AddMode.custom),
          const SizedBox(width: 3),
          tab('From catalog', _AddMode.catalog),
        ],
      ),
    );
  }
}

class _ProtocolDropdown extends StatelessWidget {
  const _ProtocolDropdown({required this.protocol, required this.onChanged});

  final AiWireProtocol protocol;
  final ValueChanged<AiWireProtocol> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AiWireProtocol>(
          value: protocol,
          isDense: true,
          isExpanded: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 13),
          items: AiWireProtocol.values.map((p) {
            return DropdownMenuItem<AiWireProtocol>(
              value: p,
              child: Text(_protocolLabel(p)),
            );
          }).toList(),
          onChanged: (p) {
            if (p != null) onChanged(p);
          },
        ),
      ),
    );
  }

  String _protocolLabel(AiWireProtocol protocol) {
    return switch (protocol) {
      AiWireProtocol.openai => 'OpenAI-compatible',
      AiWireProtocol.anthropic => 'Anthropic',
      AiWireProtocol.google => 'Google',
      AiWireProtocol.ollama => 'Ollama (local, no key)',
      AiWireProtocol.azure => 'Azure OpenAI (api-key)',
      AiWireProtocol.systemOne => 'System One / Jev-compatible (decisions)',
    };
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final AiProviderKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      AiProviderKind.cloud => ('Cloud', const Color(0xFF3B82F6)),
      AiProviderKind.local => ('Local', const Color(0xFF10B981)),
      AiProviderKind.selfHosted => ('Self-hosted', const Color(0xFFF59E0B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ApiKeyField extends StatelessWidget {
  const _ApiKeyField({
    required this.controller,
    required this.obscure,
    required this.optional,
    required this.onToggleObscure,
  });

  final TextEditingController controller;
  final bool obscure;
  final bool optional;
  final VoidCallback onToggleObscure;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _FormRow(
      label: optional ? 'API key (optional)' : 'API key',
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: optional
                ? 'Only if your endpoint needs one'
                : 'Paste your provider API key',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.separatorStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.accent),
            ),
            suffixIcon: IconButton(
              splashRadius: 16,
              iconSize: 18,
              icon: Icon(
                obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: c.textMuted,
              ),
              onPressed: onToggleObscure,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bordered row hosting the cloud-bodies privacy switch plus an explicit
/// OFF/ON explanation, so the safe default and its effect are legible without
/// flipping it. Matches the `Switch` styling used in `settings_page.dart`.
class _CloudBodiesToggle extends StatelessWidget {
  const _CloudBodiesToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Send mail bodies to cloud providers',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value
                      ? 'On — the original email is quoted in the prompt sent '
                          'to cloud providers.'
                      : 'Off (recommended) — cloud providers receive an '
                          'instruction only; the original email body stays on '
                          'your machine. Local and self-hosted providers always '
                          'get the body.',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AdaptiveSwitch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.accent,
          ),
        ],
      ),
    );
  }
}

/// Bordered container holding the two folder-agent caps, styled like
/// [_CloudBodiesToggle]. Each cap is a [_AgentCapRow]: a label + helper, an
/// editable number field, and a slider, all bound to the same clamped value.
class _AgentCapsSection extends StatelessWidget {
  const _AgentCapsSection({
    required this.maxRounds,
    required this.maxToolCallsPerRound,
    required this.onMaxRoundsChanged,
    required this.onMaxToolCallsChanged,
  });

  final int maxRounds;
  final int maxToolCallsPerRound;
  final ValueChanged<int> onMaxRoundsChanged;
  final ValueChanged<int> onMaxToolCallsChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AgentCapRow(
            label: 'Max steps per turn',
            helper: 'How many tool steps the agent takes per turn.',
            value: maxRounds,
            onChanged: onMaxRoundsChanged,
          ),
          const SizedBox(height: 16),
          _AgentCapRow(
            label: 'Max tool calls per step',
            helper: 'How many tools it can call in a single step.',
            value: maxToolCallsPerRound,
            onChanged: onMaxToolCallsChanged,
          ),
        ],
      ),
    );
  }
}

/// One folder-agent cap: a [_Label] + helper, an editable digits-only number
/// field, and a [Slider]. Both controls drive the same value via [onChanged]
/// (clamped to [_min]–[_max]); the field and slider stay in sync with [value]
/// from cubit state. Empty/out-of-range typed input snaps to the clamped value.
class _AgentCapRow extends StatefulWidget {
  const _AgentCapRow({
    required this.label,
    required this.helper,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String helper;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_AgentCapRow> createState() => _AgentCapRowState();
}

class _AgentCapRowState extends State<_AgentCapRow> {
  static const int _min = 1;
  static const int _max = 20;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.value.toString();
    // Commit on blur so a typed value persists even without pressing enter.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_AgentCapRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external value changes (e.g. the slider) into the field. We
    // reconcile even while focused so a newer slider value isn't later
    // overwritten by a stale draft on blur — only rewrite when the new value
    // differs from what the field currently parses to, so we don't clobber an
    // in-progress edit that already matches.
    if (widget.value != oldWidget.value &&
        int.tryParse(_controller.text.trim()) != widget.value) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int _clamp(int v) => v < _min ? _min : (v > _max ? _max : v);

  /// Parse + clamp the typed text, snap the field back to the clamped string,
  /// and only notify when the value actually changed.
  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    final clamped = _clamp(parsed ?? widget.value);
    final text = clamped.toString();
    if (_controller.text != text) _controller.text = text;
    if (clamped != widget.value) widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label(widget.label),
                  const SizedBox(height: 2),
                  Text(
                    widget.helper,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              height: 32,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onSubmitted: (_) => _commit(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.separatorStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: _clamp(widget.value).toDouble(),
          min: _min.toDouble(),
          max: _max.toDouble(),
          divisions: _max - _min,
          activeColor: AppColors.accent,
          label: _clamp(widget.value).toString(),
          onChanged: (v) {
            final next = _clamp(v.round());
            if (next != widget.value) widget.onChanged(next);
          },
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      text,
      style: TextStyle(
        color: c.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(color: c.textSecondary, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search providers',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.textMuted),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _PlainField extends StatelessWidget {
  const _PlainField({
    required this.controller,
    required this.hint,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: TextStyle(
          color: c.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}
