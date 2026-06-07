import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../infrastructure/accounts/account.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../blocs/mail_poller/mail_poller_state.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';

enum SettingsSection {
  accounts('Accounts'),
  appearance('Appearance'),
  general('General');

  const SettingsSection(this.label);
  final String label;
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  SettingsSection _selectedSection = SettingsSection.accounts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Get sections in alphabetical order
    final sections = SettingsSection.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));

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
                        SettingsSection.accounts => const _AccountsSection(),
                        SettingsSection.appearance => const _AppearanceSection(),
                        SettingsSection.general => const _GeneralSection(),
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

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ThemeSetting(),
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
                  child: DropdownButton<int>(
                    value: state.pollIntervalSeconds,
                    isDense: true,
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
                  child: DropdownButton<AppThemeMode>(
                    value: state.mode,
                    isDense: true,
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
  late TextEditingController _tenantIdController;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _smtpHostController;
  late TextEditingController _smtpPortController;
  bool _useSsl = true;
  bool _smtpUseSsl = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _emailController = TextEditingController();
    _tenantIdController = TextEditingController();
    _hostController = TextEditingController();
    _portController = TextEditingController();
    _smtpHostController = TextEditingController();
    _smtpPortController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _tenantIdController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _smtpHostController.dispose();
    _smtpPortController.dispose();
    super.dispose();
  }

  void _syncControllers(Account account) {
    _nameController.text = account.displayName;
    _emailController.text = account.emailAddress;
    if (account is MicrosoftAccount) {
      _tenantIdController.text = account.tenantId;
    } else if (account is ImapAccount) {
      _hostController.text = account.host;
      _portController.text = account.port.toString();
      _useSsl = account.useSsl;
      _smtpHostController.text = account.smtpHost;
      _smtpPortController.text = account.smtpPort.toString();
      _smtpUseSsl = account.smtpUseSsl;
    }
  }

  void _saveChanges() {
    if (_selectedAccount == null) return;

    final updated = switch (_selectedAccount!) {
      MicrosoftAccount a => a.copyWith(
          displayName: _nameController.text,
          emailAddress: _emailController.text,
          tenantId: _tenantIdController.text,
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
        ),
    };

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
        if (_selectedAccount == null) {
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
                          label: 'Tenant ID',
                          value: (_selectedAccount as MicrosoftAccount).tenantId,
                          isEditing: _isEditing,
                          controller: _tenantIdController,
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
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.bottomRight,
              child: ElevatedButton(
                onPressed: () {
                  if (_isEditing) {
                    _saveChanges();
                  } else {
                    setState(() {
                      _isEditing = true;
                      _syncControllers(_selectedAccount!);
                    });
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

class _AccountDetailRow extends StatelessWidget {
  const _AccountDetailRow({
    required this.label,
    required this.value,
    this.isEditing = false,
    this.controller,
    this.keyboardType,
  });

  final String label;
  final String value;
  final bool isEditing;
  final TextEditingController? controller;
  final TextInputType? keyboardType;

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
