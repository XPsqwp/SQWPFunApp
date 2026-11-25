// 规则引擎：我们自己的实现（参考 Kazumi 的规则思路：搜索 → 详情 → 选集 → 交给播放器）
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';
import 'package:xpath/xpath.dart';

const kUA =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

class Rule {
  String name;
  String baseUrl;
  /// api | html
  String searchMode;
  /// 含 @keyword
  String searchUrl;
  /// API: $.list[*]   HTML: XPath
  String listPath;
  /// 条目内相对路径
  String namePath;
  String picPath;
  String linkPath;
  /// 详情页里选集：正则（匹配 href）或 XPath
  String chapterRegex;
  String chapterPath;
  String userAgent;
  String referer;
  bool enabled;

  Rule({
    required this.name,
    required this.baseUrl,
    this.searchMode = 'api',
    this.searchUrl = '',
    this.listPath = r'$.list[*]',
    this.namePath = r'$.name',
    this.picPath = r'$.pic',
    this.linkPath = '',
    this.chapterRegex = '',
    this.chapterPath = '',
    this.userAgent = '',
    this.referer = '',
    this.enabled = true,
  });

  String get ua => userAgent.isEmpty ? kUA : userAgent;

  Map<String, dynamic> toJson() => {
        'name': name,
        'baseUrl': baseUrl,
        'searchMode': searchMode,
        'searchUrl': searchUrl,
        'listPath': listPath,
        'namePath': namePath,
        'picPath': picPath,
        'linkPath': linkPath,
        'chapterRegex': chapterRegex,
        'chapterPath': chapterPath,
        'userAgent': userAgent,
        'referer': referer,
        'enabled': enabled,
      };

  static Rule fromJson(Map<String, dynamic> j) => Rule(
        name: (j['name'] ?? '未命名').toString(),
        baseUrl: (j['baseUrl'] ?? '').toString(),
        searchMode: (j['searchMode'] ?? 'api').toString(),
        searchUrl: (j['searchUrl'] ?? '').toString(),
        listPath: (j['listPath'] ?? r'$.list[*]').toString(),
        namePath: (j['namePath'] ?? r'$.name').toString(),
        picPath: (j['picPath'] ?? r'$.pic').toString(),
        linkPath: (j['linkPath'] ?? '').toString(),
        chapterRegex: (j['chapterRegex'] ?? '').toString(),
        chapterPath: (j['chapterPath'] ?? '').toString(),
        userAgent: (j['userAgent'] ?? '').toString(),
        referer: (j['referer'] ?? '').toString(),
        enabled: j['enabled'] as bool? ?? true,
      );
}

class Hit {
  final String name;
  final String pic;
  final String detailUrl;
  final Rule rule;
  Hit(this.name, this.pic, this.detailUrl, this.rule);
}

class Episode {
  final String label;
  final String url;
  Episode(this.label, this.url);
}

class RuleStore {
  static const _key = 'sqwp_rules_v1';

  static List<Rule> defaults() => [
        Rule(
          name: 'LMM',
          baseUrl: 'https://www.lmm85.com',
          searchUrl: 'https://www.lmm85.com/index.php/ajax/suggest?mid=1&wd=@keyword',
          listPath: r'$.list[*]',
          namePath: 'name',
          picPath: 'pic',
          linkPath: '/index.php/vod/detail/id/{id}.html',
          chapterRegex: r'/play/\d+_\d+_\d+\.html',
        ),
        Rule(
          name: 'Moonci',
          baseUrl: 'https://www.moonci.com',
          searchUrl: 'https://www.moonci.com/index.php/ajax/suggest?mid=1&wd=@keyword',
          listPath: r'$.list[*]',
          namePath: 'name',
          picPath: 'pic',
          linkPath: '/index.php/vod/detail/id/{id}.html',
          chapterRegex: r'/play/\d+_\d+_\d+\.html',
        ),
      ];

  static Future<List<Rule>> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) {
      final d = defaults();
      await save(d);
      return d;
    }
    return (jsonDecode(raw) as List)
        .map((e) => Rule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<Rule> rules) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(rules.map((e) => e.toJson()).toList()));
  }
}

class Engine {
  static String _enc(String s) => Uri.encodeComponent(s);

  static Map<String, String> _headers(Rule r) => {
        'User-Agent': r.ua,
        if (r.referer.isNotEmpty) 'Referer': r.referer,
      };

  static Future<List<Hit>> search(Rule rule, String kw) async {
    if (!rule.enabled || rule.searchUrl.isEmpty) return const [];
    final url = rule.searchUrl.replaceAll('@keyword', _enc(kw));
    final res = await http.get(Uri.parse(url), headers: _headers(rule)).timeout(const Duration(seconds: 12));
    if (rule.searchMode == 'html') return _searchHtml(rule, res.body);
    return _searchApi(rule, res.body);
  }

  static List<Hit> _searchApi(Rule rule, String body) {
    final out = <Hit>[];
    final data = jsonDecode(body);
    final list = _digJson(data, rule.listPath);
    if (list is! List) return out;
    for (final item in list) {
      if (item is! Map) continue;
      final name = _digField(item, rule.namePath).toString();
      final pic = _digField(item, rule.picPath).toString().replaceFirst('http://', 'https://');
      final id = _digField(item, 'id');
      var link = rule.linkPath;
      if (link.contains('{id}')) {
        link = link.replaceAll('{id}', '$id');
      } else if (link.contains('{link}')) {
        link = link.replaceAll('{link}', _digField(item, 'link').toString());
      }
      if (link.isEmpty) continue;
      final detail = link.startsWith('http') ? link : '${rule.baseUrl}$link';
      out.add(Hit(name, pic, detail, rule));
    }
    return out;
  }

  static List<Hit> _searchHtml(Rule rule, String body) {
    final out = <Hit>[];
    try {
      final doc = XmlDocument.parse(body);
      final nodes = _xpNodes(doc, rule.listPath);
      for (final n in nodes) {
        if (n is! XmlNode) continue;
        final name = _xpText(n, rule.namePath);
        var href = _xpText(n, rule.linkPath);
        if (href.isEmpty) {
          final linkNode = _xpNodes(n, rule.linkPath);
          if (linkNode.isNotEmpty && linkNode.first is XmlElement) {
            href = (linkNode.first as XmlElement).getAttribute('href') ?? '';
          }
        }
        final pic = _xpText(n, rule.picPath);
        if (href.isEmpty) continue;
        final detail = href.startsWith('http') ? href : '${rule.baseUrl}$href';
        out.add(Hit(name, pic.replaceFirst('http://', 'https://'), detail, rule));
      }
    } catch (_) {}
    return out;
  }

  static String _xpText(XmlNode node, String path) {
    if (path.isEmpty) return '';
    try {
      final r = _xpNodes(node, path);
      if (r.isEmpty) return '';
      final first = r.first;
      if (first is XmlAttribute) return first.value;
      if (first is XmlElement) return first.innerText.trim();
      return first.toString();
    } catch (_) {
      return '';
    }
  }

  /// 兼容 package:xpath 不同版本的返回类型
  static List<dynamic> _xpNodes(XmlNode ctx, String expr) {
    try {
      final r = XPath(expr).apply(ctx);
      if (r == null) return const [];
      final dyn = r as dynamic;
      try {
        final nodes = dyn.nodes;
        if (nodes is List) return nodes;
      } catch (_) {}
      if (r is List) return r;
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static dynamic _digJson(dynamic data, String path) {
    var p = path.trim();
    if (p.startsWith(r'$.')) p = p.substring(2);
    if (p.endsWith('[*]')) p = p.substring(0, p.length - 3);
    dynamic cur = data;
    for (final seg in p.split('.').where((e) => e.isNotEmpty)) {
      if (cur is Map) {
        cur = cur[seg];
      } else {
        return null;
      }
    }
    return cur;
  }

  static dynamic _digField(Map item, String path) {
    var p = path.trim();
    if (p.startsWith(r'$.')) p = p.substring(2);
    if (p.isEmpty) return '';
    dynamic cur = item;
    for (final seg in p.split('.')) {
      if (cur is Map) {
        cur = cur[seg];
      } else {
        return '';
      }
    }
    return cur ?? '';
  }

  static Future<List<Episode>> chapters(Hit hit) async {
    final res = await http.get(Uri.parse(hit.detailUrl), headers: _headers(hit.rule))
        .timeout(const Duration(seconds: 15));
    final body = res.body;
    final out = <Episode>[];
    if (hit.rule.chapterRegex.isNotEmpty) {
      final seen = <String>{};
      for (final m in RegExp(hit.rule.chapterRegex).allMatches(body)) {
        final href = m.group(0)!;
        if (!seen.add(href)) continue;
        final nums = RegExp(r'_(\d+)_(\d+)\.').firstMatch(href);
        final line = nums?.group(1) ?? '1';
        final ep = nums?.group(2) ?? '${out.length + 1}';
        out.add(Episode(line == '1' ? '第$ep话' : '线路$line·第$ep话',
            href.startsWith('http') ? href : '${hit.rule.baseUrl}$href'));
      }
      return out;
    }
    if (hit.rule.chapterPath.isNotEmpty) {
      try {
        final doc = XmlDocument.parse(body);
        final nodes = _xpNodes(doc, hit.rule.chapterPath);
        for (final n in nodes) {
          if (n is XmlElement) {
            final href = n.getAttribute('href') ?? '';
            if (href.isEmpty) continue;
            out.add(Episode(
              n.innerText.trim().isEmpty ? '第${out.length + 1}话' : n.innerText.trim(),
              href.startsWith('http') ? href : '${hit.rule.baseUrl}$href',
            ));
          }
        }
      } catch (_) {}
    }
    return out;
  }
}
