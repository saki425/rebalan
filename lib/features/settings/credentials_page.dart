import 'package:flutter/material.dart';

import '../../core/domain/models.dart';
import '../../core/live/binance_live_client.dart';
import '../../core/live/credential_store.dart';
import '../../core/live/live_trading_gate.dart';

class CredentialsPage extends StatefulWidget {
  const CredentialsPage({
    super.key,
    this.store = const SecureCredentialStore(),
  });
  final CredentialStore store;

  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  final Map<AccountRole, bool> _configured = {};
  final Map<AccountRole, String> _diagnostics = {};
  final Set<AccountRole> _testing = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final role in AccountRole.values) {
      final credentials = await widget.store.read(role);
      _configured[role] = credentials?.isValid == true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _edit(AccountRole role) async {
    final existing = await widget.store.read(role);
    if (!mounted) return;
    final email = TextEditingController(text: existing?.accountEmail ?? '');
    final apiKey = TextEditingController();
    final secret = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_name(role)} API 凭据'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '子账户邮箱（用于划转）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: apiKey,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Secret Key（不会回显）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final credentials = BinanceCredentials(
                apiKey: apiKey.text.trim(),
                secretKey: secret.text.trim(),
                accountEmail: email.text.trim(),
              );
              if (!credentials.isValid) return;
              await widget.store.save(role, credentials);
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('安全保存'),
          ),
        ],
      ),
    );
    email.dispose();
    apiKey.dispose();
    secret.dispose();
    if (saved == true) await _refresh();
  }

  Future<void> _delete(AccountRole role) async {
    await widget.store.delete(role);
    await _refresh();
  }

  Future<void> _test(AccountRole role) async {
    final credentials = await widget.store.read(role);
    if (credentials == null) return;
    setState(() => _testing.add(role));
    final client = BinanceLiveClient(credentials: credentials);
    try {
      await client.synchronizeTime();
      await client.account();
      final permissions = ApiPermissionSnapshot.fromBinance(
        await client.apiRestrictions(),
      );
      final result = [
        '连接成功',
        permissions.ipRestricted ? 'IP✓' : 'IP未限制✗',
        permissions.spotTradingEnabled ? '交易✓' : '交易✗',
        permissions.internalTransferEnabled ? '内部划转✓' : '内部划转✗',
        permissions.withdrawalsEnabled ? '提现已开启✗' : '提现关闭✓',
      ].join(' · ');
      if (mounted) setState(() => _diagnostics[role] = result);
    } catch (error) {
      if (mounted) setState(() => _diagnostics[role] = '检查失败：$error');
    } finally {
      client.close();
      if (mounted) setState(() => _testing.remove(role));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本机 Binance 凭据')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '凭据仅保存到系统 Keychain/Keystore，不写入 SQLite、日志或 Git。建议启用 Binance IP 白名单并关闭提现权限。',
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final role in AccountRole.values)
          Card(
            child: ListTile(
              title: Text(_name(role)),
              subtitle: Text(
                _diagnostics[role] ??
                    (_configured[role] == true ? '已安全保存' : '未配置'),
              ),
              leading: Icon(
                _configured[role] == true ? Icons.verified_user : Icons.key_off,
              ),
              trailing: Wrap(
                children: [
                  if (_configured[role] == true)
                    IconButton(
                      onPressed: _testing.contains(role)
                          ? null
                          : () => _test(role),
                      tooltip: '测试连接与权限',
                      icon: _testing.contains(role)
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.health_and_safety_outlined),
                    ),
                  if (_configured[role] == true)
                    IconButton(
                      onPressed: () => _delete(role),
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline),
                    ),
                  IconButton(
                    onPressed: () => _edit(role),
                    tooltip: '设置',
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'LIVE 默认锁定。还需要完成至少20笔 Paper 成交、连续24小时无错误、权限检查以及输入确认短语后才能解锁。',
            ),
          ),
        ),
      ],
    ),
  );
}

String _name(AccountRole role) => switch (role) {
  AccountRole.funding => 'Funding Account',
  AccountRole.strategy => 'Strategy Account',
  AccountRole.profit => 'Profit Account',
};
