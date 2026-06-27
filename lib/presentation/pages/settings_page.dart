import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/config/oauth_client_id_storage.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../injection_container.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import 'settings/ai_settings_page.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../blocs/mail_poller/mail_poller_state.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';

bool get _isApplePlatform => !kIsWeb && (Platform.isMacOS || Platform.isIOS);

enum SettingsSection {
  about('About'),
  accounts('Accounts'),
  ai('AI'),
  appearance('Appearance'),
  general('General'),
  security('Security');

  const SettingsSection(this.label);
  final String label;
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  /// Opens settings: a push route on mobile, a dialog on desktop.
  static Future<void> open(BuildContext context) {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    final themeCubit = context.read<ThemeCubit>();
    final accountCubit = context.read<AccountCubit>();
    final pollerCubit = context.read<MailPollerCubit>();

    Widget wrap(Widget child) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: themeCubit),
            BlocProvider.value(value: accountCubit),
            BlocProvider.value(value: pollerCubit),
          ],
          child: child,
        );

    if (isMobile) {
      return Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => wrap(const _MobileSettingsPage()),
        ),
      );
    }

    return showDialog<void>(
      context: context,
      builder: (ctx) => wrap(const SettingsDialog()),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  SettingsSection _selectedSection = SettingsSection.about;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Get sections in alphabetical order
    final sections = SettingsSection.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 800,
        height: 600,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Sidebar
            Container(
              width: 200,
              color: c.surfaceBase,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: sections.length,
                      itemBuilder: (context, index) {
                        final section = sections[index];
                        final isSelected = _selectedSection == section;
                        return InkWell(
                          onTap: () => setState(() => _selectedSection = section),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            color: isSelected ? c.surfacePanel : null,
                            child: Text(
                              section.label,
                              style: TextStyle(
                                color: isSelected ? c.textPrimary : c.textSecondary,
                                fontSize: 13,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.accent,
                      ),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: c.separatorStrong),
            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedSection.label.toUpperCase(),
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: switch (_selectedSection) {
                        SettingsSection.about => const _AboutSection(),
                        SettingsSection.accounts => const _AccountsSection(),
                        SettingsSection.ai => const AiSettingsPage(),
                        SettingsSection.appearance => const _AppearanceSection(),
                        SettingsSection.general => const _GeneralSection(),
                        SettingsSection.security => const _SecuritySection(),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Image.asset(
            'assets/sharpblue.png',
            width: 80,
            height: 80,
          ),
          const SizedBox(height: 20),
          Text(
            'NightMail',
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'by SharpBlue',
            style: TextStyle(
              color: c.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'NightMail is a fast, focused email client for Microsoft 365, Gmail, and IMAP accounts. '
            'It brings together your inbox, calendar, and tasks in a clean, native interface '
            'designed for professionals who value clarity and keyboard-friendly workflows.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Written by Claude with help from David Hobley.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textMuted,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ThemeSetting(),
        const SizedBox(height: 12),
        _FontFamilySetting(),
        const SizedBox(height: 12),
        _FontSizeSetting(),
        const SizedBox(height: 12),
        const _ComposeFormatSetting(),
      ],
    );
  }
}

class _GeneralSection extends StatelessWidget {
  const _GeneralSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PollIntervalSetting(),
        const SizedBox(height: 12),
        const _DeleteConfirmSetting(),
      ],
    );
  }
}

class _PollIntervalSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<MailPollerCubit, MailPollerState>(
      builder: (context, state) {
        return Row(
          children: [
            Text(
              'Check for new mail',
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const Spacer(),
            SizedBox(
              width: 180,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surfaceBase,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.separatorStrong),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: state.pollIntervalSeconds,
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: c.surfacePanel,
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Never')),
                      DropdownMenuItem(
                          value: 30, child: Text('Every 30 seconds')),
                      DropdownMenuItem(
                          value: 60, child: Text('Every minute')),
                      DropdownMenuItem(
                          value: 120, child: Text('Every 2 minutes')),
                      DropdownMenuItem(
                          value: 300, child: Text('Every 5 minutes')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        context.read<MailPollerCubit>().updatePollInterval(val);
                      }
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThemeSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ThemeCubit, ThemeState>(
      builder: (context, state) {
        return Row(
          children: [
            Text(
              'Theme',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 180,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surfaceBase,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.separatorStrong),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AppThemeMode>(
                    value: state.mode,
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: c.surfacePanel,
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                    items: const [
                      DropdownMenuItem(
                        value: AppThemeMode.system,
                        child: Text('OS Default'),
                      ),
                      DropdownMenuItem(
                        value: AppThemeMode.light,
                        child: Text('Light'),
                      ),
                      DropdownMenuItem(
                        value: AppThemeMode.dark,
                        child: Text('Dark'),
                      ),
                    ],
                    onChanged: (mode) {
                      if (mode != null) context.read<ThemeCubit>().setMode(mode);
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FontFamilySetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ThemeCubit, ThemeState>(
      builder: (context, state) {
        return Row(
          children: [
            Text(
              'Font',
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const Spacer(),
            SizedBox(
              width: 180,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surfaceBase,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.separatorStrong),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: state.fontFamily,
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: c.surfacePanel,
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text('System Default', style: TextStyle(color: c.textSecondary)),
                      ),
                      ...const [
                        ('Arial', 'Arial'),
                        ('Georgia', 'Georgia'),
                        ('Courier New', 'Courier New'),
                        ('Segoe UI', 'Segoe UI'),
                        ('Verdana', 'Verdana'),
                        ('Trebuchet MS', 'Trebuchet MS'),
                      ].map((entry) {
                        final (label, family) = entry;
                        return DropdownMenuItem<String?>(
                          value: family,
                          child: Text(
                            label,
                            style: TextStyle(fontFamily: family),
                          ),
                        );
                      }),
                    ],
                    onChanged: (family) {
                      context.read<ThemeCubit>().setFontFamily(family);
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FontSizeSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ThemeCubit, ThemeState>(
      builder: (context, state) {
        return Row(
          children: [
            Text(
              'Font Size',
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const Spacer(),
            SizedBox(
              width: 180,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surfaceBase,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.separatorStrong),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<double>(
                    value: state.fontScale,
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: c.surfacePanel,
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                    items: const [
                      DropdownMenuItem(value: 0.85, child: Text('Small')),
                      DropdownMenuItem(value: 1.0, child: Text('Default')),
                      DropdownMenuItem(value: 1.15, child: Text('Large')),
                      DropdownMenuItem(value: 1.3, child: Text('Extra Large')),
                    ],
                    onChanged: (scale) {
                      if (scale != null) context.read<ThemeCubit>().setFontScale(scale);
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DeleteConfirmSetting extends StatefulWidget {
  const _DeleteConfirmSetting();

  @override
  State<_DeleteConfirmSetting> createState() => _DeleteConfirmSettingState();
}

class _DeleteConfirmSettingState extends State<_DeleteConfirmSetting> {
  bool _value = AppSettings.defaultConfirmDeleteEmail;

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadConfirmDeleteEmail().then((v) {
      if (mounted) setState(() => _value = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(
          'Ask every time before deleting',
          style: TextStyle(color: c.textSecondary, fontSize: 13),
        ),
        const Spacer(),
        SizedBox(
          width: 180,
          child: Align(
            alignment: Alignment.centerRight,
            child: Checkbox(
              value: _value,
              onChanged: (val) {
                if (val == null) return;
                setState(() => _value = val);
                sl<AppSettings>().saveConfirmDeleteEmail(val);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ComposeFormatSetting extends StatefulWidget {
  const _ComposeFormatSetting();

  @override
  State<_ComposeFormatSetting> createState() => _ComposeFormatSettingState();
}

class _ComposeFormatSettingState extends State<_ComposeFormatSetting> {
  EmailBodyType _value = AppSettings.defaultComposeFormat;

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadDefaultComposeFormat().then((v) {
      if (mounted) setState(() => _value = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(
          'Compose format',
          style: TextStyle(color: c.textSecondary, fontSize: 13),
        ),
        const Spacer(),
        SizedBox(
          width: 180,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: c.surfaceBase,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.separatorStrong),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<EmailBodyType>(
                value: _value,
                isDense: true,
                isExpanded: true,
                dropdownColor: c.surfacePanel,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
                items: const [
                  DropdownMenuItem(
                    value: EmailBodyType.html,
                    child: Text('Rich Text (HTML)'),
                  ),
                  DropdownMenuItem(
                    value: EmailBodyType.text,
                    child: Text('Plain Text'),
                  ),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  setState(() => _value = val);
                  sl<AppSettings>().saveDefaultComposeFormat(val);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountsSection extends StatefulWidget {
  const _AccountsSection();

  @override
  State<_AccountsSection> createState() => _AccountsSectionState();
}

class _AccountsSectionState extends State<_AccountsSection> {
  Account? _selectedAccount;
  bool _isEditing = false;

  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _smtpHostController;
  late TextEditingController _smtpPortController;
  bool _useSsl = true;
  bool _smtpUseSsl = false;

  // Nextcloud calendar (non-Apple platforms only)
  late TextEditingController _caldavUrlController;
  late TextEditingController _caldavUsernameController;
  late TextEditingController _caldavPasswordController;
  bool _nextcloudEnabled = false;

  late TextEditingController _msClientIdController;
  late TextEditingController _googleClientIdController;


  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _emailController = TextEditingController();
    _hostController = TextEditingController();
    _portController = TextEditingController();
    _smtpHostController = TextEditingController();
    _smtpPortController = TextEditingController();
    _caldavUrlController = TextEditingController();
    _caldavUsernameController = TextEditingController();
    _caldavPasswordController = TextEditingController();
    _msClientIdController = TextEditingController();
    _googleClientIdController = TextEditingController();
    _loadClientIds();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _smtpHostController.dispose();
    _smtpPortController.dispose();
    _caldavUrlController.dispose();
    _caldavUsernameController.dispose();
    _caldavPasswordController.dispose();
    _msClientIdController.dispose();
    _googleClientIdController.dispose();
    super.dispose();
  }

  void _syncControllers(Account account) {
    _nameController.text = account.displayName;
    _emailController.text = account.emailAddress;
    if (account is ImapAccount) {
      _hostController.text = account.host;
      _portController.text = account.port.toString();
      _useSsl = account.useSsl;
      _smtpHostController.text = account.smtpHost;
      _smtpPortController.text = account.smtpPort.toString();
      _smtpUseSsl = account.smtpUseSsl;
      final caldav = account.nextcloudCalendarConfig;
      _nextcloudEnabled = caldav != null;
      _caldavUrlController.text = caldav?.serverUrl ?? '';
      _caldavUsernameController.text = caldav?.username ?? '';
      _caldavPasswordController.text = '';
    }
  }

  void _loadCalDavPassword(String accountId) {
    sl<AccountManager>().loadCalDavPassword(accountId).then((p) {
      if (mounted) setState(() => _caldavPasswordController.text = p ?? '');
    });
  }

  void _loadClientIds() {
    final storage = sl<OAuthClientIdStorage>();
    storage.loadMicrosoftClientId().then((id) {
      if (mounted) setState(() => _msClientIdController.text = id ?? '');
    });
    storage.loadGoogleClientId().then((id) {
      if (mounted) setState(() => _googleClientIdController.text = id ?? '');
    });
  }

  void _confirmDeleteAccount(BuildContext context) {
    if (_selectedAccount == null) return;
    final account = _selectedAccount!;
    final name = account.displayName.isEmpty
        ? account.emailAddress
        : account.displayName;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account'),
        content: Text(
          'Remove "$name" and all its cached data? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.read<AccountCubit>().removeAccount(account.id);
              setState(() {
                _selectedAccount = null;
                _isEditing = false;
              });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _saveChanges() {
    if (_selectedAccount == null) return;

    NextcloudCalendarConfig? caldavConfig;
    if (_selectedAccount is ImapAccount && _nextcloudEnabled) {
      final url = _caldavUrlController.text.trim();
      final user = _caldavUsernameController.text.trim();
      if (url.isNotEmpty && user.isNotEmpty) {
        caldavConfig = NextcloudCalendarConfig(serverUrl: url, username: user);
      }
    }

    final updated = switch (_selectedAccount!) {
      MicrosoftAccount a => a.copyWith(
          displayName: _nameController.text,
          emailAddress: _emailController.text,
        ),
      GmailAccount a => a.copyWith(
          displayName: _nameController.text,
          emailAddress: _emailController.text,
        ),
      ImapAccount a => a.copyWith(
          displayName: _nameController.text,
          emailAddress: _emailController.text,
          host: _hostController.text,
          port: int.tryParse(_portController.text) ?? a.port,
          useSsl: _useSsl,
          smtpHost: _smtpHostController.text,
          smtpPort: int.tryParse(_smtpPortController.text) ?? a.smtpPort,
          smtpUseSsl: _smtpUseSsl,
          nextcloudCalendarConfig: caldavConfig,
        ),
    };

    // Persist Client ID changes for OAuth accounts
    final storage = sl<OAuthClientIdStorage>();
    if (updated is MicrosoftAccount) {
      final id = _msClientIdController.text.trim();
      if (id.isNotEmpty) storage.saveMicrosoftClientId(id);
    } else if (updated is GmailAccount) {
      final id = _googleClientIdController.text.trim();
      if (id.isNotEmpty) storage.saveGoogleClientId(id);
    }

    // Persist CalDAV password if provided
    if (updated is ImapAccount) {
      final pw = _caldavPasswordController.text;
      if (pw.isNotEmpty) {
        sl<AccountManager>().saveCalDavPassword(updated.id, pw);
      } else if (!_nextcloudEnabled) {
        // Cleared — remove stored password
        sl<AccountManager>().saveCalDavPassword(updated.id, '');
      }
    }

    context.read<AccountCubit>().updateAccount(updated);
    setState(() {
      _selectedAccount = updated;
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<AccountCubit, AccountState>(
      builder: (context, state) {
        if (state is! AccountsLoaded) {
          return const Center(child: Text('No accounts configured'));
        }

        final accounts = state.accounts;

        // After a save/delete the local _selectedAccount reference may no
        // longer match any item in the new state (different instance). Always
        // re-anchor it to the matching object from state by ID so the
        // DropdownButton value is guaranteed to be in its items list.
        if (_selectedAccount != null) {
          final fresh = accounts.cast<Account?>().firstWhere(
            (a) => a!.id == _selectedAccount!.id,
            orElse: () => null,
          );
          if (fresh == null) {
            _selectedAccount = null; // account was deleted
          } else if (!identical(fresh, _selectedAccount)) {
            _selectedAccount = fresh; // account was updated
          }
        }

        if (_selectedAccount == null) {
          if (accounts.isEmpty) {
            return const Center(child: Text('No accounts configured'));
          }
          _selectedAccount = state.activeAccount;
          _syncControllers(_selectedAccount!);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Select Account',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 24),
                const Spacer(),
                Flexible(
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: c.surfaceBase,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.separatorStrong),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<Account>(
                        value: _selectedAccount,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: c.surfacePanel,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 13,
                          overflow: TextOverflow.ellipsis,
                        ),
                        items: accounts.map((account) {
                          return DropdownMenuItem(
                            value: account,
                            child: Text(
                              account.displayName.isEmpty
                                  ? account.emailAddress
                                  : account.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: _isEditing
                            ? null
                            : (account) {
                                if (account != null) {
                                  setState(() {
                                    _selectedAccount = account;
                                    _syncControllers(account);
                                  });
                                }
                              },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            if (_selectedAccount != null)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AccountDetailRow(
                        label: 'Name',
                        value: _selectedAccount!.displayName,
                        isEditing: _isEditing,
                        controller: _nameController,
                      ),
                      _AccountDetailRow(
                        label: 'Email',
                        value: _selectedAccount!.emailAddress,
                        isEditing: _isEditing,
                        controller: _emailController,
                      ),
                      _AccountDetailRow(
                        label: 'Type',
                        value: switch (_selectedAccount!) {
                          MicrosoftAccount() => 'Microsoft',
                          GmailAccount() => 'Gmail',
                          ImapAccount() => 'IMAP',
                        },
                      ),
                      if (_selectedAccount is MicrosoftAccount)
                        _AccountDetailRow(
                          label: 'Client ID',
                          value: _msClientIdController.text.isEmpty
                              ? '—'
                              : _msClientIdController.text,
                          isEditing: _isEditing,
                          controller: _msClientIdController,
                        ),
                      if (_selectedAccount is GmailAccount)
                        _AccountDetailRow(
                          label: 'Client ID',
                          value: _googleClientIdController.text.isEmpty
                              ? '—'
                              : _googleClientIdController.text,
                          isEditing: _isEditing,
                          controller: _googleClientIdController,
                        ),
                      if (_selectedAccount is ImapAccount) ...[
                        _SectionSubheader(label: 'Incoming (IMAP)'),
                        _AccountDetailRow(
                          label: 'Host',
                          value: (_selectedAccount as ImapAccount).host,
                          isEditing: _isEditing,
                          controller: _hostController,
                        ),
                        _AccountDetailRow(
                          label: 'Port',
                          value: (_selectedAccount as ImapAccount).port.toString(),
                          isEditing: _isEditing,
                          controller: _portController,
                          keyboardType: TextInputType.number,
                        ),
                        _SslRow(
                          label: 'SSL',
                          value: (_selectedAccount as ImapAccount).useSsl,
                          isEditing: _isEditing,
                          onChanged: (val) => setState(() => _useSsl = val),
                          editingValue: _useSsl,
                        ),
                        _SectionSubheader(label: 'Outgoing (SMTP)'),
                        _AccountDetailRow(
                          label: 'Host',
                          value: (_selectedAccount as ImapAccount).smtpHost,
                          isEditing: _isEditing,
                          controller: _smtpHostController,
                        ),
                        _AccountDetailRow(
                          label: 'Port',
                          value: (_selectedAccount as ImapAccount).smtpPort.toString(),
                          isEditing: _isEditing,
                          controller: _smtpPortController,
                          keyboardType: TextInputType.number,
                        ),
                        _SslRow(
                          label: 'SSL',
                          value: (_selectedAccount as ImapAccount).smtpUseSsl,
                          isEditing: _isEditing,
                          onChanged: (val) => setState(() => _smtpUseSsl = val),
                          editingValue: _smtpUseSsl,
                        ),
                        _SectionSubheader(label: 'Calendar'),
                        if (_isApplePlatform &&
                            !(_isEditing
                                ? _nextcloudEnabled
                                : (_selectedAccount as ImapAccount)
                                        .nextcloudCalendarConfig !=
                                    null))
                          const _AccountDetailRow(
                            label: 'Source',
                            value: 'System Calendar (EventKit)',
                          ),
                        _SslRow(
                          label: 'Nextcloud',
                          value: (_selectedAccount as ImapAccount)
                                  .nextcloudCalendarConfig !=
                              null,
                          isEditing: _isEditing,
                          editingValue: _nextcloudEnabled,
                          onChanged: (val) =>
                              setState(() => _nextcloudEnabled = val),
                        ),
                        if (_isEditing && _nextcloudEnabled ||
                            !_isEditing &&
                                (_selectedAccount as ImapAccount)
                                        .nextcloudCalendarConfig !=
                                    null) ...[
                          _AccountDetailRow(
                            label: 'Server URL',
                            value: (_selectedAccount as ImapAccount)
                                    .nextcloudCalendarConfig
                                    ?.serverUrl ??
                                '',
                            isEditing: _isEditing,
                            controller: _caldavUrlController,
                          ),
                          _AccountDetailRow(
                            label: 'Username',
                            value: (_selectedAccount as ImapAccount)
                                    .nextcloudCalendarConfig
                                    ?.username ??
                                '',
                            isEditing: _isEditing,
                            controller: _caldavUsernameController,
                          ),
                          if (_isEditing)
                            _AccountDetailRow(
                              label: 'Password',
                              value: '',
                              isEditing: true,
                              controller: _caldavPasswordController,
                              obscureText: true,
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _confirmDeleteAccount(context),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  child: const Text('Delete Account'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    if (_isEditing) {
                      _saveChanges();
                    } else {
                      setState(() {
                        _isEditing = true;
                        _syncControllers(_selectedAccount!);
                      });
                      if (_selectedAccount is ImapAccount) {
                        _loadCalDavPassword(_selectedAccount!.id);
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(_isEditing ? 'Save' : 'Edit'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SectionSubheader extends StatelessWidget {
  const _SectionSubheader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          color: c.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SslRow extends StatelessWidget {
  const _SslRow({
    required this.label,
    required this.value,
    required this.isEditing,
    required this.editingValue,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool isEditing;
  final bool editingValue;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ),
          if (isEditing)
            Switch(
              value: editingValue,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.accent,
            )
          else
            Text(
              value ? 'Yes' : 'No',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}

class _SecuritySection extends StatefulWidget {
  const _SecuritySection();

  @override
  State<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<_SecuritySection> {
  List<String> _domains = [];
  Set<String> _selectedDomains = {};
  int? _lastSelectedIndex;

  @override
  void initState() {
    super.initState();
    _loadDomains();
  }

  Future<void> _loadDomains() async {
    final domains = await sl<AppSettings>().loadExternalImageDomains();
    if (mounted) {
      setState(() => _domains = domains.toList()..sort());
    }
  }

  void _handleTap(int index) {
    final domain = _domains[index];
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isMeta = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;

    setState(() {
      if (isShift && _lastSelectedIndex != null) {
        final lo = _lastSelectedIndex! < index ? _lastSelectedIndex! : index;
        final hi = _lastSelectedIndex! > index ? _lastSelectedIndex! : index;
        _selectedDomains = {for (int i = lo; i <= hi; i++) _domains[i]};
      } else if (isMeta) {
        final next = Set<String>.from(_selectedDomains);
        if (next.contains(domain)) {
          next.remove(domain);
        } else {
          next.add(domain);
          _lastSelectedIndex = index;
        }
        _selectedDomains = next;
      } else {
        _selectedDomains = {domain};
        _lastSelectedIndex = index;
      }
    });
  }

  Future<void> _removeSelected() async {
    await sl<AppSettings>().removeExternalImageDomains(_selectedDomains);
    if (!mounted) return;
    setState(() {
      _selectedDomains = {};
      _lastSelectedIndex = null;
    });
    await _loadDomains();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Approved Image Domains',
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'External images are automatically loaded from these domains.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.separatorStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: _domains.isEmpty
                ? Center(
                    child: Text(
                      'No approved domains',
                      style: TextStyle(color: c.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    itemCount: _domains.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, thickness: 1, color: c.separator),
                    itemBuilder: (context, index) {
                      final domain = _domains[index];
                      final isSelected = _selectedDomains.contains(domain);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _handleTap(index),
                        child: Container(
                          color: isSelected ? c.selectionBg : null,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          child: Text(
                            domain,
                            style: TextStyle(
                              color: isSelected
                                  ? AppColors.accent
                                  : c.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.bottomRight,
          child: ElevatedButton(
            onPressed: _selectedDomains.isEmpty ? null : _removeSelected,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              disabledBackgroundColor: c.surfaceBase,
              foregroundColor: Colors.white,
              disabledForegroundColor: c.textMuted,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Remove'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile settings navigation
// ---------------------------------------------------------------------------

class _MobileSettingsPage extends StatelessWidget {
  const _MobileSettingsPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sections = SettingsSection.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    return Scaffold(
      backgroundColor: c.surfacePanel,
      appBar: AppBar(
        title: Text(
          'Settings',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: c.surfacePanel,
        elevation: 0,
        iconTheme: IconThemeData(color: c.textMuted),
      ),
      body: ListView.separated(
        itemCount: sections.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: c.separator),
        itemBuilder: (context, index) {
          final section = sections[index];
          return ListTile(
            title: Text(
              section.label,
              style: TextStyle(color: c.textSecondary, fontSize: 15),
            ),
            trailing: Icon(Icons.chevron_right_rounded, color: c.textMuted),
            onTap: () {
              final themeCubit = context.read<ThemeCubit>();
              final accountCubit = context.read<AccountCubit>();
              final pollerCubit = context.read<MailPollerCubit>();
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => MultiBlocProvider(
                    providers: [
                      BlocProvider.value(value: themeCubit),
                      BlocProvider.value(value: accountCubit),
                      BlocProvider.value(value: pollerCubit),
                    ],
                    child: _MobileSettingsSectionPage(section: section),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _MobileSettingsSectionPage extends StatelessWidget {
  const _MobileSettingsSectionPage({required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.surfacePanel,
      appBar: AppBar(
        title: Text(
          section.label,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: c.surfacePanel,
        elevation: 0,
        iconTheme: IconThemeData(color: c.textMuted),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (section) {
          SettingsSection.about => const _AboutSection(),
          SettingsSection.accounts => const _AccountsSection(),
          SettingsSection.ai => const AiSettingsPage(),
          SettingsSection.appearance => const _AppearanceSection(),
          SettingsSection.general => const _GeneralSection(),
          SettingsSection.security => const _SecuritySection(),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AccountDetailRow extends StatelessWidget {
  const _AccountDetailRow({
    required this.label,
    required this.value,
    this.isEditing = false,
    this.controller,
    this.keyboardType,
    this.obscureText = false,
  });

  final String label;
  final String value;
  final bool isEditing;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: c.textMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: isEditing && controller != null
                ? SizedBox(
                    height: 36,
                    child: TextField(
                      controller: controller,
                      keyboardType: keyboardType,
                      obscureText: obscureText,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                  )
                : Text(
                    value,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
