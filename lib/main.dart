import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SqwpApp());
}

const _ua =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

const _green = Color(0xFF0E1F16);
const _ink = Color(0xFF12261A);
const _sub = Color(0xFF6A7A70);

/* ------------------------------- 数据层 ------------------------------- */

class Anime {
  final int id;
  final String titleCn;
  final String titleJp;
  final String cover;
  final String broadcast;
  final int weekday;
  final String typeTag;
  final String staff;
  final String cast;

  Anime({
    required this.id,
    required this.titleCn,
    required this.titleJp,
    required this.cover,
    required this.broadcast,
    required this.weekday,
    required this.typeTag,
    required this.staff,
    required this.cast,
  });

  String get title => titleCn.isNotEmpty ? titleCn : titleJp;
  String get weekdayName => (weekday >= 1 && weekday <= 7)
      ? const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1]
      : '未定档';

  Map<String, dynamic> toJson() => {
        'id': id,
        'titleCn': titleCn,
        'titleJp': titleJp,
        'cover': cover,
        'broadcast': broadcast,
        'weekday': weekday,
        'typeTag': typeTag,
        'staff': staff,
        'cast': cast,
      };

  factory Anime.fromJson(Map<String, dynamic> j) => Anime(
        id: j['id'] ?? 0,
        titleCn: j['titleCn'] ?? '',
        titleJp: j['titleJp'] ?? '',
        cover: j['cover'] ?? '',
        broadcast: j['broadcast'] ?? '',
        weekday: j['weekday'] ?? 0,
        typeTag: j['typeTag'] ?? '',
        staff: j['staff'] ?? '',
        cast: j['cast'] ?? '',
      );
}

String currentSeason() {
  final now = DateTime.now();
  final m = ((now.month - 1) ~/ 3) * 3 + 1;
  return '${now.year}${m.toString().padLeft(2, '0')}';
}

String seasonName(String s) {
  if (s.length != 6) return '当季';
  final part = switch (s.substring(4)) {
    '01' => '冬季',
    '04' => '春季',
    '07' => '夏季',
    _ => '秋季',
  };
  return '${s.substring(0, 4)}$part';
}

String _strip(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>'), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .trim();

/// yuc.wiki 当季新番表（纯动画情报，国内直连）
Future<List<Anime>> fetchSeason() async {
  final season = currentSeason();
  final r = await http.get(
    Uri.parse('https://yuc.wiki/$season/'),
    headers: {'User-Agent': _ua},
  ).timeout(const Duration(seconds: 20));
  final blocks = r.body.split(RegExp(r'<!--#[A-Za-z]?\d+-->'));
  final out = <Anime>[];
  var idx = 0;
  for (final b in blocks.skip(1)) {
    final cover = RegExp(r'data-src="([^"]+)"').firstMatch(b)?.group(1);
    if (cover == null) continue;
    idx++;
    final cn = RegExp(r'class="title_cn_r">([^<]*)<').firstMatch(b)?.group(1) ?? '';
    final jp = RegExp(r'class="title_jp_r">([^<]*)<').firstMatch(b)?.group(1) ?? '';
    final bc = RegExp(r'class="broadcast_r">([^<]*)<').firstMatch(b)?.group(1) ?? '';
    final tag = RegExp(r'class="type_a_r">([^<]*)<').firstMatch(b)?.group(1) ?? '';
    final staff = RegExp(r'class="staff_r">([\s\S]*?)</td>').firstMatch(b)?.group(1) ?? '';
    final cast = RegExp(r'class="cast_r">([\s\S]*?)</td>').firstMatch(b)?.group(1) ?? '';
    var weekday = 0;
    for (var i = 0; i < 7; i++) {
      if (bc.contains(const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][i])) {
        weekday = i + 1;
        break;
      }
    }
    out.add(Anime(
      id: idx,
      titleCn: cn.trim(),
      titleJp: jp.trim(),
      cover: cover.replaceFirst('http://', 'https://'),
      broadcast: bc.trim(),
      weekday: weekday,
      typeTag: tag.trim(),
      staff: _strip(staff),
      cast: _strip(cast),
    ));
  }
  return out;
}

class Source {
  final String name;
  final String base;
  /// 详情页地址模板，{id} 会被替换
  final String detailPath;
  /// 详情页里选集链接的正则
  final String episodeRegex;
  const Source(
    this.name,
    this.base, {
    this.detailPath = '/index.php/vod/detail/id/{id}.html',
    this.episodeRegex = r'/play/\d+_\d+_\d+\.html',
  });
}

const sources = <Source>[
  Source('Moonci', 'https://www.moonci.com',
      detailPath: '/anime/{id}.html',
      episodeRegex: r'/anime/\d+/play/\d+-\d+\.html'),
  Source('LMM', 'https://www.lmm85.com'),
];

class Hit {
  final String name;
  final int id;
  final String pic;
  final Source source;
  Hit(this.name, this.id, this.pic, this.source);
}

class Episode {
  final String label;
  final String url;
  Episode(this.label, this.url);
}

Future<List<Hit>> searchSources(String kw, List<String> logs) async {
  final enc = Uri.encodeComponent(kw);
  final results = <Hit>[];
  await Future.wait(sources.map((s) async {
    try {
      final r = await http.get(
        Uri.parse('${s.base}/index.php/ajax/suggest?mid=1&wd=$enc'),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 12));
      if (!r.body.trimLeft().startsWith('{')) {
        logs.add('${s.name}: HTTP ${r.statusCode}');
        return;
      }
      final list = (jsonDecode(r.body) as Map)['list'] as List? ?? [];
      logs.add('${s.name}: ${list.length}');
      for (final it in list) {
        results.add(Hit(
          (it['name'] ?? '').toString(),
          int.tryParse('${it['id']}') ?? 0,
          (it['pic'] ?? '').toString().replaceFirst('http://', 'https://'),
          s,
        ));
      }
    } catch (e) {
      logs.add('${s.name}: ${e.runtimeType}');
    }
  }));
  return results;
}

Future<List<Episode>> episodesOf(Hit hit) async {
  try {
    final detail = '${hit.source.base}${hit.source.detailPath.replaceAll('{id}', '${hit.id}')}';
    final r = await http.get(
      Uri.parse(detail),
      headers: {'User-Agent': _ua},
    ).timeout(const Duration(seconds: 15));
    final seen = <String>{};
    final out = <Episode>[];
    for (final m in RegExp(hit.source.episodeRegex).allMatches(r.body)) {
      final path = m.group(0)!;
      if (!seen.add(path)) continue;
      // 兼容 xxx_1_2.html / xxx/play/1-2.html 两种命名
      final nums = RegExp(r'(\d+)[._-](\d+)\.html').allMatches(path).toList();
      final last = nums.isEmpty ? null : nums.last;
      final line = last?.group(1) ?? '1';
      final ep = last?.group(2) ?? '${out.length + 1}';
      out.add(Episode(line == '1' ? '第$ep话' : '线路$line·第$ep话', '${hit.source.base}$path'));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/* ------------------------------- App ------------------------------- */

class SqwpApp extends StatelessWidget {
  const SqwpApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SQWPFun',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFEAF4E6),
        colorScheme: ColorScheme.fromSeed(seedColor: _ink),
        fontFamily: null,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  List<Anime> _catalog = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  List<Anime> _favorites = [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadFav();
  }

  Future<void> _load() async {
    try {
      final list = await fetchSeason();
      if (!mounted) return;
      setState(() {
        _catalog = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadFav() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('favorites');
    if (raw == null) return;
    final list = (jsonDecode(raw) as List)
        .map((e) => Anime.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (!mounted) return;
    setState(() => _favorites = list);
  }

  Future<void> _saveFav() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('favorites', jsonEncode(_favorites.map((e) => e.toJson()).toList()));
  }

  void _toggleFav(Anime a) {
    setState(() {
      final i = _favorites.indexWhere((e) => e.id == a.id);
      if (i >= 0) {
        _favorites.removeAt(i);
      } else {
        _favorites.add(a);
      }
    });
    _saveFav();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = const ['推荐', '时间表', '追番', '我的'];
    final pages = [
      RecommendPage(
        catalog: _catalog,
        loading: _loading,
        error: _error,
        query: _query,
        onQuery: (v) => setState(() => _query = v),
        onOpen: (a) => _openDetail(a),
        onWatch: (t) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WatchPage(title: t)),
        ),
      ),
      SchedulePage(catalog: _catalog, onOpen: (a) => _openDetail(a)),
      FavoritesPage(
        items: _favorites,
        onOpen: (a) => _openDetail(a),
      ),
      const MinePage(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          // 1.15 版同款背景渐变
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFEAF4E6), Color(0xFFF6F1E4), Color(0xFFE8EEF8)],
                ),
              ),
            ),
          ),
          Positioned.fill(child: pages[_tab]),
          // 底部液态玻璃胶囊导航
          Positioned(
            left: 14,
            right: 14,
            bottom: 14 + MediaQuery.of(context).padding.bottom * 0.4,
            child: GlassNavBar(
              tabs: tabs,
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(Anime a) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailPage(
        anime: a,
        isFav: _favorites.any((e) => e.id == a.id),
        onToggleFav: () => _toggleFav(a),
        onWatch: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WatchPage(title: a.title)),
        ),
      ),
    ));
  }
}

/* --------------------------- 液态玻璃导航栏 --------------------------- */

class GlassNavBar extends StatelessWidget {
  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;
  const GlassNavBar({super.key, required this.tabs, required this.index, required this.onChanged});

  static const _icons = [Icons.home_rounded, Icons.calendar_month_rounded, Icons.favorite_rounded, Icons.settings_rounded];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final tabW = w / tabs.length;
      return ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(34),
              border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 24, offset: const Offset(0, 8)),
              ],
            ),
            child: Stack(
              children: [
                // 选中胶囊：带渐变+内高光，模拟玻璃体
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  left: tabW * index + 6,
                  top: 6,
                  width: tabW - 12,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.85),
                          Colors.white.withValues(alpha: 0.45),
                        ],
                      ),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 4)),
                        BoxShadow(color: Colors.white.withValues(alpha: 0.6), blurRadius: 3),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: List.generate(tabs.length, (i) {
                    final active = i == index;
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(i),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_icons[i], size: 22, color: active ? _ink : _sub),
                            const SizedBox(height: 2),
                            Text(tabs[i],
                                style: TextStyle(
                                    fontSize: 11,
                                    color: active ? _ink : _sub,
                                    fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/* ------------------------------- 页面 ------------------------------- */

class RecommendPage extends StatelessWidget {
  final List<Anime> catalog;
  final bool loading;
  final String? error;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<Anime> onOpen;
  final ValueChanged<String> onWatch;

  const RecommendPage({
    super.key,
    required this.catalog,
    required this.loading,
    required this.error,
    required this.query,
    required this.onQuery,
    required this.onOpen,
    required this.onWatch,
  });

  @override
  Widget build(BuildContext context) {
    final season = currentSeason();
    final filtered = catalog.where((a) {
      if (query.isEmpty) return true;
      return a.titleCn.contains(query) || a.titleJp.contains(query) || a.cast.contains(query);
    }).toList();

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${seasonName(season)}新番',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _ink)),
                Text(query.isEmpty ? '共 ${catalog.length} 部 · 数据来自 yuc.wiki' : '匹配 ${filtered.length} 部',
                    style: const TextStyle(fontSize: 11, color: _sub)),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextField(
                    onChanged: onQuery,
                    decoration: const InputDecoration(
                      hintText: '搜番名 / 声优',
                      prefixIcon: Icon(Icons.search, size: 20),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('加载失败\n$error', textAlign: TextAlign.center, style: const TextStyle(color: _sub)),
                ),
              ),
            )
          else
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.58,
                ),
                itemCount: filtered.length,
                itemBuilder: (ctx, i) => PosterCard(anime: filtered[i], onTap: () => onOpen(filtered[i])),
              ),
            ),
        ],
      ),
    );
  }
}

class PosterCard extends StatelessWidget {
  final Anime anime;
  final VoidCallback onTap;
  const PosterCard({super.key, required this.anime, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: anime.cover,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: const Color(0x22000000)),
                    errorWidget: (_, __, ___) => Container(color: const Color(0x22000000)),
                  ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(anime.weekdayName, style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(anime.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _ink)),
        ],
      ),
    );
  }
}

class SchedulePage extends StatelessWidget {
  final List<Anime> catalog;
  final ValueChanged<Anime> onOpen;
  const SchedulePage({super.key, required this.catalog, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final groups = <int, List<Anime>>{};
    for (final a in catalog) {
      groups.putIfAbsent(a.weekday, () => []).add(a);
    }
    final keys = groups.keys.toList()..sort();
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
        children: [
          const Text('每周放送', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _ink)),
          const SizedBox(height: 8),
          ...keys.expand((k) => [
                Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 8),
                  child: Text(
                    (k >= 1 && k <= 7) ? const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][k - 1] : '未定档',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF2C4438)),
                  ),
                ),
                ...groups[k]!.map((a) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => onOpen(a),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 46,
                                  height: 64,
                                  child: CachedNetworkImage(imageUrl: a.cover, fit: BoxFit.cover),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14, color: _ink)),
                                    const SizedBox(height: 2),
                                    Text(
                                      [a.broadcast, a.typeTag].where((e) => e.isNotEmpty).join('  ·  '),
                                      style: const TextStyle(fontSize: 11, color: _sub),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )),
              ]),
        ],
      ),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  final List<Anime> items;
  final ValueChanged<Anime> onOpen;
  const FavoritesPage({super.key, required this.items, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('还没有追番', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _ink)),
              SizedBox(height: 6),
              Text('在番剧详情页点「追番」就会出现在这里', style: TextStyle(fontSize: 12, color: _sub)),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      bottom: false,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          childAspectRatio: 0.58,
        ),
        itemCount: items.length,
        itemBuilder: (ctx, i) => PosterCard(anime: items[i], onTap: () => onOpen(items[i])),
      ),
    );
  }
}

class MinePage extends StatelessWidget {
  const MinePage({super.key});
  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('我的', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _ink)),
            SizedBox(height: 6),
            Text('设置 · 同步 · 关于', style: TextStyle(fontSize: 13, color: _sub)),
          ],
        ),
      ),
    );
  }
}

/* ------------------------------ 详情页 ------------------------------ */

class DetailPage extends StatelessWidget {
  final Anime anime;
  final bool isFav;
  final VoidCallback onToggleFav;
  final VoidCallback onWatch;
  const DetailPage({
    super.key,
    required this.anime,
    required this.isFav,
    required this.onToggleFav,
    required this.onWatch,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: CachedNetworkImage(imageUrl: anime.cover, fit: BoxFit.cover)),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: 0.85),
                    const Color(0xF20B1510),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(anime.title,
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
                      if (anime.titleJp.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(anime.titleJp,
                              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.6))),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        [anime.weekdayName, anime.broadcast, anime.typeTag].where((e) => e.isNotEmpty).join('  ·  '),
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
                      ),
                      if (anime.staff.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(anime.staff,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, height: 1.5, color: Colors.white.withValues(alpha: 0.7))),
                        ),
                      if (anime.cast.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(anime.cast,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, height: 1.5, color: Colors.white.withValues(alpha: 0.6))),
                        ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: onWatch,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF7BDFA8),
                                foregroundColor: _green,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded, size: 20),
                              label: const Text('在线看', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onToggleFav,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                              ),
                              icon: Icon(isFav ? Icons.favorite : Icons.favorite_border, size: 18),
                              label: Text(isFav ? '已追' : '追番'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* --------------------------- 在线看 / 播放器 --------------------------- */

class WatchPage extends StatefulWidget {
  final String title;
  const WatchPage({super.key, required this.title});
  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  final List<String> _logs = [];
  final _kwCtrl = TextEditingController();
  List<Hit>? _hits;
  List<Episode>? _episodes;
  Hit? _picked;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _kwCtrl.text = widget.title;
    _search();
  }

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  /// 站点的番名和情报源的番名往往不一致：去季数、"第Xクール"、括注，再退到前 4 个字
  List<String> _variants(String title) {
    final out = <String>[];
    final stripped = title
        .replaceAll(RegExp(r'第[一二三四五六七八九十0-9]+[季期部]'), '')
        .replaceAll(RegExp(r'第\s*[0-9]+\s*クール'), '')
        .replaceAll(RegExp(r'Season\s*\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'[（(].*?[)）]'), '')
        .trim();
    if (stripped.isNotEmpty && stripped != title) out.add(stripped);
    final tokens = stripped
        .split(RegExp(r'[\s·・:：\-—/]+'))
        .where((e) => e.trim().length >= 2)
        .toList();
    if (tokens.length > 1) out.add(tokens.first);
    if (stripped.length > 4) out.add(stripped.substring(0, 4));
    return out.where((e) => e.trim().isNotEmpty && e.trim() != title).toList();
  }

  Future<void> _search() async {
    final kw = _kwCtrl.text.trim();
    if (kw.isEmpty) return;
    _logs.clear();
    setState(() {
      _loading = true;
      _hits = null;
    });
    final merged = <String, Hit>{};
    final queries = <String>[kw, ..._variants(kw)];
    for (final q in queries) {
      final hits = await searchSources(q, _logs);
      if (hits.isEmpty) continue;
      for (final h in hits) {
        merged.putIfAbsent('${h.source.name}-${h.id}', () => h);
      }
      if (merged.length >= 8) break;
    }
    if (!mounted) return;
    setState(() {
      _hits = merged.values.toList();
      _loading = false;
    });
  }

  Future<void> _open(Hit hit) async {
    setState(() {
      _loading = true;
      _picked = hit;
    });
    final eps = await episodesOf(hit);
    if (!mounted) return;
    setState(() {
      _episodes = eps;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final eps = _episodes;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1510),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          _picked == null ? '在线看 · ${widget.title}' : ((eps == null || eps.isEmpty) ? '没有解析到选集' : '选集 · ${_picked!.name}'),
          style: const TextStyle(fontSize: 14),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_episodes != null) {
              setState(() {
                _episodes = null;
                _picked = null;
              });
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF9ED9B3)))
          : (eps == null
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _kwCtrl,
                      style: const TextStyle(fontSize: 13),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '换个关键词再搜（站点番名可能和情报源不同）',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.arrow_forward, size: 18),
                          onPressed: _search,
                        ),
                        filled: true,
                        fillColor: Colors.white10,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_logs.join('   '), style: const TextStyle(fontSize: 10, color: Colors.white38)),
                    const SizedBox(height: 8),
                    ...(_hits ?? []).map((h) => Card(
                          color: Colors.white10,
                          child: ListTile(
                            leading: SizedBox(
                              width: 46,
                              height: 64,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(imageUrl: h.pic, fit: BoxFit.cover),
                              ),
                            ),
                            title: Text(h.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(h.source.name, style: const TextStyle(fontSize: 11)),
                            onTap: () => _open(h),
                          ),
                        )),
                  ],
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: eps.length,
                  itemBuilder: (ctx, i) => GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PlayerPage(title: _picked!.name, playPage: eps[i].url),
                    )),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(eps[i].label, style: const TextStyle(fontSize: 13, color: Colors.white)),
                    ),
                  ),
                )),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final String title;
  final String playPage;
  const PlayerPage({super.key, required this.title, required this.playPage});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final Player _player = Player();
  late final VideoController _vc = VideoController(_player);
  String? _mediaUrl;

  bool _isMedia(String u) {
    final l = u.toLowerCase();
    if (l.startsWith('blob:') || l.startsWith('data:')) return false;
    return l.contains('.m3u8') || l.contains('.mp4') || l.contains('type=m3u8') || l.contains('mime=video');
  }

  void _hit(String u) {
    if (_mediaUrl != null || !_isMedia(u)) return;
    setState(() => _mediaUrl = u);
    _player.open(Media(u));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        actions: [
          if (_mediaUrl != null)
            IconButton(
              icon: const Icon(Icons.language),
              tooltip: '切回网页',
              onPressed: () => setState(() => _mediaUrl = null),
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_mediaUrl != null)
            Video(controller: _vc)
          else
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.playPage)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                useShouldInterceptRequest: true,
                userAgent: _ua,
              ),
              shouldInterceptRequest: (controller, request) async {
                _hit(request.url.toString());
                return null;
              },
              onLoadStop: (controller, url) async {
                await controller.evaluateJavascript(source: '''
                  (function(){
                    if(window.__sqwp) return; window.__sqwp=1;
                    var f=window.fetch;
                    if(f){ window.fetch=function(u){ try{console.log('SQWP:'+u)}catch(e){}; return f.apply(this,arguments) }; }
                    var o=XMLHttpRequest.prototype.open;
                    XMLHttpRequest.prototype.open=function(m,u){ try{console.log('SQWP:'+u)}catch(e){}; return o.apply(this,arguments) };
                    setInterval(function(){
                      var v=document.querySelector('video');
                      if(v){ try{ v.muted=true; if(v.paused) v.play(); }catch(e){} }
                      var b=document.querySelector('.play-btn,.vjs-big-play-button,.dplayer-play-icon,.play');
                      if(b){ try{ b.click(); }catch(e){} }
                    }, 800);
                  })();
                ''');
              },
              onConsoleMessage: (controller, msg) {
                final m = msg.message;
                if (m.startsWith('SQWP:')) _hit(m.substring(5));
              },
            ),
          if (_mediaUrl == null)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Text('正在解析播放地址…', style: TextStyle(color: Colors.white54, fontSize: 11)),
              ),
            ),
        ],
      ),
    );
  }
}
