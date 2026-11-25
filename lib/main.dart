import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'rules.dart';
import 'player_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SqwpApp());
}

class SqwpApp extends StatelessWidget {
  const SqwpApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SQWPFun',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3E6B52),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SearchPage(),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  List<Rule> _rules = [];
  List<Hit> _hits = [];
  bool _loading = false;
  String? _err;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final r = await RuleStore.load();
    if (mounted) setState(() => _rules = r);
  }

  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    _logs.clear();
    setState(() {
      _loading = true;
      _err = null;
      _hits = [];
    });
    final out = <Hit>[];
    for (final rule in _rules.where((r) => r.enabled)) {
      try {
        final hits = await Engine.search(rule, kw);
        _logs.add('${rule.name}: ${hits.length} 条');
        out.addAll(hits);
      } catch (e) {
        _logs.add('${rule.name}: ${e.runtimeType}');
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _hits = out;
      if (out.isEmpty) _err = '所有规则都没搜到，换个关键词或加个源';
    });
  }

  Future<void> _open(Hit hit) async {
    List<Episode> eps;
    try {
      eps = await Engine.chapters(hit);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选集失败: ${e.runtimeType}')),
      );
      return;
    }
    if (!mounted) return;
    if (eps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条规则没解析到选集，检查“选集正则/选集 XPath”')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A14),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(hit.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${hit.rule.name} · ${eps.length} 集',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: eps
                        .map((e) => ActionChip(
                              label: Text(e.label),
                              onPressed: () {
                                Navigator.pop(ctx);
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => PlayerPage(
                                    title: hit.name,
                                    playPage: e.url,
                                    userAgent: hit.rule.ua,
                                    referer: hit.rule.referer,
                                  ),
                                ));
                              },
                            ))
                        .toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SQWPFun'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '规则管理',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RulesPage()),
              );
              _loadRules();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _ctrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜番名（走已启用的规则源）',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _logs.isEmpty
                    ? '源: ${_rules.where((r) => r.enabled).map((r) => r.name).join(' / ')}'
                    : _logs.join('   '),
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_err!, style: const TextStyle(color: Colors.white70)),
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.56,
              ),
              itemCount: _hits.length,
              itemBuilder: (ctx, i) {
                final h = _hits[i];
                return GestureDetector(
                  onTap: () => _open(h),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedNetworkImage(
                                imageUrl: h.pic,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    Container(color: Colors.white10),
                              ),
                              Positioned(
                                right: 4,
                                top: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(h.rule.name,
                                      style: const TextStyle(fontSize: 10)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(h.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class RulesPage extends StatefulWidget {
  const RulesPage({super.key});
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  List<Rule> _rules = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await RuleStore.load();
    if (mounted) setState(() => _rules = r);
  }

  Future<void> _persist() async {
    await RuleStore.save(_rules);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('规则管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final r = await Navigator.of(context).push<Rule>(
            MaterialPageRoute(builder: (_) => const RuleEditorPage(rule: null)),
          );
          if (r != null) {
            _rules.add(r);
            await _persist();
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('添加规则'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _rules.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (ctx, i) {
          final r = _rules[i];
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF16211A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              title: Text(r.name),
              subtitle: Text('${r.baseUrl}\n${r.searchMode.toUpperCase()} · ${r.enabled ? "启用" : "停用"}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: r.enabled,
                    onChanged: (v) async {
                      r.enabled = v;
                      await _persist();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      _rules.removeAt(i);
                      await _persist();
                    },
                  ),
                ],
              ),
              onTap: () async {
                final edited = await Navigator.of(context).push<Rule>(
                  MaterialPageRoute(builder: (_) => RuleEditorPage(rule: r)),
                );
                if (edited != null) {
                  _rules[i] = edited;
                  await _persist();
                }
              },
            ),
          );
        },
      ),
    );
  }
}

class RuleEditorPage extends StatefulWidget {
  final Rule? rule;
  const RuleEditorPage({super.key, this.rule});
  @override
  State<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<RuleEditorPage> {
  late final Map<String, TextEditingController> _c;

  @override
  void initState() {
    super.initState();
    final r = widget.rule;
    _c = {
      'name': TextEditingController(text: r?.name ?? ''),
      'baseUrl': TextEditingController(text: r?.baseUrl ?? 'https://'),
      'searchUrl': TextEditingController(text: r?.searchUrl ?? ''),
      'listPath': TextEditingController(text: r?.listPath ?? r'$.list[*]'),
      'namePath': TextEditingController(text: r?.namePath ?? 'name'),
      'picPath': TextEditingController(text: r?.picPath ?? 'pic'),
      'linkPath': TextEditingController(
          text: r?.linkPath ?? '/index.php/vod/detail/id/{id}.html'),
      'chapterRegex': TextEditingController(
          text: r?.chapterRegex ?? r'/play/\d+_\d+_\d+\.html'),
      'chapterPath': TextEditingController(text: r?.chapterPath ?? ''),
      'userAgent': TextEditingController(text: r?.userAgent ?? ''),
      'referer': TextEditingController(text: r?.referer ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, {String? hint, int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _c[key],
        maxLines: lines,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rule == null ? '新建规则' : '编辑规则'),
        actions: [
          TextButton(
            onPressed: () {
              final r = Rule(
                name: _c['name']!.text.trim().isEmpty ? '未命名' : _c['name']!.text.trim(),
                baseUrl: _c['baseUrl']!.text.trim(),
                searchUrl: _c['searchUrl']!.text.trim(),
                listPath: _c['listPath']!.text.trim(),
                namePath: _c['namePath']!.text.trim(),
                picPath: _c['picPath']!.text.trim(),
                linkPath: _c['linkPath']!.text.trim(),
                chapterRegex: _c['chapterRegex']!.text.trim(),
                chapterPath: _c['chapterPath']!.text.trim(),
                userAgent: _c['userAgent']!.text.trim(),
                referer: _c['referer']!.text.trim(),
                enabled: widget.rule?.enabled ?? true,
                searchMode: widget.rule?.searchMode ?? 'api',
              );
              Navigator.of(context).pop(r);
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('name', '规则名称', hint: 'LMM / AGE / ...'),
          _field('baseUrl', '站点根地址', hint: 'https://www.example.com'),
          _field('searchUrl', '搜索地址（@keyword 会被替换）',
              hint: 'https://site/index.php/ajax/suggest?mid=1&wd=@keyword', lines: 2),
          const SizedBox(height: 8),
          const Text('API 模式（JSON 接口）', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _field('listPath', '结果列表', hint: r'$.list[*]'),
          _field('namePath', '条目名称', hint: 'name'),
          _field('picPath', '封面字段', hint: 'pic'),
          _field('linkPath', '详情地址模板', hint: '/index.php/vod/detail/id/{id}.html'),
          const SizedBox(height: 8),
          const Text('选集', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _field('chapterRegex', '选集正则（匹配播放页链接）',
              hint: r'/play/\d+_\d+_\d+\.html', lines: 2),
          _field('chapterPath', '或：选集 XPath（详情页内）', hint: '//ul/li/a'),
          const SizedBox(height: 8),
          const Text('网络', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _field('userAgent', 'User-Agent（留空用默认）'),
          _field('referer', 'Referer（部分站点需要）'),
          const SizedBox(height: 12),
          const Text(
            'HTML 模式的 XPath（结果列表/名称/链接填写 XPath 即可）在 0.5 里开放；'
            '当前版本请用 API 模式（苹果CMS 站点都是这个接口）。',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
