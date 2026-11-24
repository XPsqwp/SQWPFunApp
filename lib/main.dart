import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SqwpApp());
}

const _ua =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

class Source {
  final String name;
  final String base;
  const Source(this.name, this.base);
}

const sources = <Source>[
  Source('LMM', 'https://www.lmm85.com'),
  Source('Moonci', 'https://www.moonci.com'),
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

Future<List<Hit>> searchAll(String kw) async {
  final enc = Uri.encodeComponent(kw);
  final results = <Hit>[];
  await Future.wait(sources.map((s) async {
    try {
      final r = await http.get(
        Uri.parse('${s.base}/index.php/ajax/suggest?mid=1&wd=$enc'),
        headers: {'User-Agent': _ua, 'Referer': '${s.base}/'},
      ).timeout(const Duration(seconds: 12));
      final list = (jsonDecode(r.body) as Map)['list'] as List? ?? [];
      for (final it in list) {
        results.add(Hit(
          (it['name'] ?? '').toString(),
          int.tryParse('${it['id']}') ?? 0,
          (it['pic'] ?? '').toString().replaceFirst('http://', 'https://'),
          s,
        ));
      }
    } catch (_) {}
  }));
  return results;
}

Future<List<Episode>> episodes(Hit hit) async {
  try {
    final r = await http.get(
      Uri.parse('${hit.source.base}/index.php/vod/detail/id/${hit.id}.html'),
      headers: {'User-Agent': _ua, 'Referer': '${hit.source.base}/'},
    ).timeout(const Duration(seconds: 15));
    final re = RegExp('/play/${hit.id}_(\\d+)_(\\d+)\\.html');
    final seen = <String>{};
    final out = <Episode>[];
    for (final m in re.allMatches(r.body)) {
      final path = m.group(0)!;
      if (!seen.add(path)) continue;
      final line = m.group(1)!;
      final ep = m.group(2)!;
      out.add(Episode(
        line == '1' ? '第$ep话' : '线路$line·第$ep话',
        '${hit.source.base}$path',
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
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
  List<Hit> _hits = [];
  bool _loading = false;
  String? _err;

  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    setState(() {
      _loading = true;
      _err = null;
      _hits = [];
    });
    final hits = await searchAll(kw);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _hits = hits;
      if (hits.isEmpty) _err = '所有源都没搜到，换个关键词试试';
    });
  }

  Future<void> _open(Hit hit) async {
    final eps = await episodes(hit);
    if (!mounted) return;
    if (eps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${hit.source.name} 没有解析到选集')),
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
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: eps
                    .map((e) => ActionChip(
                          label: Text(e.label),
                          onPressed: () {
                            Navigator.pop(ctx);
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => PlayerPage(
                                  title: hit.name, playPage: e.url),
                            ));
                          },
                        ))
                    .toList(),
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
      appBar: AppBar(title: const Text('SQWPFun'), elevation: 0),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _ctrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜番名（LMM / Moonci 双源）',
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
                                  child: Text(h.source.name,
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

class PlayerPage extends StatefulWidget {
  final String title;
  final String playPage;
  const PlayerPage({super.key, required this.title, required this.playPage});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  InAppWebViewController? _web;
  final Player _player = Player();
  late final VideoController _vc = VideoController(_player);
  String? _mediaUrl;
  bool _playing = false;

  bool _isMedia(String u) {
    final l = u.toLowerCase();
    if (l.startsWith('blob:') || l.startsWith('data:')) return false;
    return l.contains('.m3u8') ||
        l.contains('.mp4') ||
        l.contains('type=m3u8') ||
        l.contains('mime=video');
  }

  void _hit(String u) {
    if (_mediaUrl != null || !_isMedia(u)) return;
    setState(() {
      _mediaUrl = u;
      _playing = true;
    });
    _player.open(Media(u));
  }

  @override
  void dispose() {
    _player.dispose();
    _web?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        actions: [
          if (_mediaUrl != null)
            IconButton(
              icon: const Icon(Icons.language),
              tooltip: '切回网页播放器',
              onPressed: () => setState(() {
                _mediaUrl = null;
                _playing = false;
              }),
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_playing)
            Video(controller: _vc)
          else
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.playPage)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                useShouldInterceptRequest: true,
                userAgent: _ua,
                transparentBackground: false,
              ),
              onWebViewCreated: (c) => _web = c,
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
          if (!_playing)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Text('正在解析播放地址…',
                    style: TextStyle(color: Colors.white70, fontSize: 11)),
              ),
            ),
        ],
      ),
    );
  }
}
