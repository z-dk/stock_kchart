import 'package:flutter/material.dart';

import '../data_sources/data_source.dart';
import '../data_sources/data_source_factory.dart';
import '../services/storage_service.dart';

/// Settings page for selecting data source and managing API keys.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _storage = StorageService.instance;
  final _factory = DataSourceFactory.instance;

  String? _activeSourceId;
  final Map<String, TextEditingController> _keyControllers = {};
  final Map<String, String?> _currentKeys = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final sources = _factory.allSources;
    final Map<String, String?> keys = {};
    for (final ds in sources) {
      if (ds.requiresApiKey) {
        keys[ds.id] = await _storage.getApiKey(ds.id);
      }
    }
    final activeId = await _storage.getActiveDataSourceId();
    if (mounted) {
      setState(() {
        _activeSourceId = activeId;
        _currentKeys.addAll(keys);
        for (final ds in sources) {
          if (ds.requiresApiKey) {
            _keyControllers[ds.id] =
                TextEditingController(text: _currentKeys[ds.id] ?? '');
          }
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = _factory.allSources;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1D25),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1D25),
        elevation: 0,
        title: const Text('涨了吗 · 设置', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _activeSourceId == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _sectionHeader('数据源'),
                const SizedBox(height: 8),
                ...sources.map((ds) => _buildSourceTile(ds)),
                const SizedBox(height: 24),
                if (_hasAnyApiKey) ...<Widget>[
                  _sectionHeader('API 密钥配置'),
                  const SizedBox(height: 8),
                  ...sources
                      .where((ds) => ds.requiresApiKey)
                      .map((ds) => _buildKeyTile(ds)),
                ],
                const SizedBox(height: 16),
                _buildInfoTile(),
              ],
            ),
    );
  }

  bool get _hasAnyApiKey =>
      _keyControllers.isNotEmpty;

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF60738E),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildSourceTile(DataSource ds) {
    final isActive = _activeSourceId == ds.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF242830),
        borderRadius: BorderRadius.circular(8),
        border: isActive
            ? Border.all(color: const Color(0xFF4DAA90), width: 2)
            : null,
      ),
      child: ListTile(
        leading: Icon(
          isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: isActive ? const Color(0xFF4DAA90) : const Color(0xFF60738E),
        ),
        title: Text(
          ds.displayName,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          ds.description,
          style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 12),
        ),
        trailing: ds.requiresApiKey &&
                (_currentKeys[ds.id] == null || _currentKeys[ds.id]!.isEmpty)
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFC15466).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '需配置 Key',
                  style: TextStyle(color: Color(0xFFC15466), fontSize: 10),
                ),
              )
            : null,
        onTap: () {
          setState(() {
            _activeSourceId = ds.id;
            _storage.setActiveDataSourceId(ds.id);
          });
        },
      ),
    );
  }

  Widget _buildKeyTile(DataSource ds) {
    final controller = _keyControllers[ds.id]!;
    final hasKey = _currentKeys[ds.id] != null && _currentKeys[ds.id]!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF242830),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '${ds.displayName} API Key',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              if (hasKey)
                const Icon(Icons.check_circle, color: Color(0xFF4DAA90), size: 18),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '输入 API Key',
              hintStyle: const TextStyle(color: Color(0xFF60738E)),
              filled: true,
              fillColor: const Color(0xFF1A1D25),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: () async {
                  await _storage.setApiKey(ds.id, controller.text);
                  setState(() {
                    _currentKeys[ds.id] = controller.text;
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('API Key 已保存')),
                    );
                  }
                },
                child: const Text('保存', style: TextStyle(color: Color(0xFF4DAA90))),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await _storage.setApiKey(ds.id, null);
                  controller.clear();
                  setState(() {
                    _currentKeys[ds.id] = null;
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('API Key 已清除')),
                    );
                  }
                },
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFC15466)),
                child: const Text('清除'),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _showKeyInfo(ds),
                child: const Icon(Icons.info_outline, color: Color(0xFF60738E), size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showKeyInfo(DataSource ds) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF242830),
        title: Text(
          '${ds.displayName} API Key',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          _keyInfoText(ds.id),
          style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 13),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了', style: TextStyle(color: Color(0xFF4DAA90))),
          ),
        ],
      ),
    );
  }

  String _keyInfoText(String id) {
    if (id == 'finnhub') {
      return 'Finnhub 免费注册即可获得 API Key：\n\n'
          '1. 访问 https://finnhub.io/register\n'
          '2. 邮箱注册登录\n'
          '3. 在 Dashboard 复制你的 API Key\n\n'
          '免费额度：每分钟 60 次调用。\n'
          '支持市场：美股、中国 A 股、港股、外汇、加密货币。';
    }
    return '请访问数据源官网申请 API Key。';
  }

  Widget _buildInfoTile() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF242830),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        '提示：切换数据源后，需重新输入股票代码。不同数据源的股票代码格式可能不同（如 AAPL / 600519.SS）。',
        style: TextStyle(color: Color(0xFF60738E), fontSize: 12),
      ),
    );
  }
}
