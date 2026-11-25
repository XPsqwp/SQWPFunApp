import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// 本地 HLS 代理：负责 ①补 Referer/UA ②丢掉广告分片 ③把分片地址改成本地代理
class HlsProxy {
  static HttpServer? _srv;
  static int _port = 0;

  /// 广告分片特征（命中即丢弃）
  static const adWords = <String>[
    '/ad/', '/ads/', '/adv/', 'advert', 'guanggao', '/gg/', 'preroll', 'midroll', 'popunder',
  ];

  static Future<int> _ensure() async {
    if (_srv != null) return _port;
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _srv!.port;
    _srv!.listen(_handle, onError: (_) {});
    return _port;
  }

  static Future<String> wrap(String url, {String referer = '', String ua = ''}) async {
    final port = await _ensure();
    return 'http://127.0.0.1:$port/p'
        '?u=${Uri.encodeComponent(url)}'
        '&r=${Uri.encodeComponent(referer)}'
        '&a=${Uri.encodeComponent(ua)}';
  }

  static String _wrapped(String url, String referer, String ua) => 'http://127.0.0.1:$_port/p'
      '?u=${Uri.encodeComponent(url)}'
      '&r=${Uri.encodeComponent(referer)}'
      '&a=${Uri.encodeComponent(ua)}';

  static bool isAd(String url) {
    final l = url.toLowerCase();
    return adWords.any(l.contains);
  }

  static Future<void> _handle(HttpRequest req) async {
    var u = '', r = '', ua = '';
    try {
      u = Uri.decodeComponent(req.uri.queryParameters['u'] ?? '');
      r = Uri.decodeComponent(req.uri.queryParameters['r'] ?? '');
      ua = Uri.decodeComponent(req.uri.queryParameters['a'] ?? '');
      if (u.isEmpty) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      final headers = <String, String>{
        'User-Agent': ua.isEmpty ? 'Mozilla/5.0' : ua,
        if (r.isNotEmpty) 'Referer': r,
      };
      final res = await http
          .get(Uri.parse(u), headers: headers)
          .timeout(const Duration(seconds: 20));
      final ct = res.headers['content-type'] ?? '';
      final text = utf8.decode(res.bodyBytes, allowMalformed: true);
      final isM3u8 = u.contains('.m3u8') ||
          ct.contains('mpegurl') ||
          text.trimLeft().startsWith('#EXTM3U');
      if (isM3u8) {
        final out = _rewrite(text, Uri.parse(u), r, ua);
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write(out);
      } else {
        req.response.headers.contentType = ContentType.parse(
            ct.isEmpty ? 'application/octet-stream' : ct.split(';').first);
        req.response.add(res.bodyBytes);
      }
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 重写 playlist：丢广告分片、补全相对地址、所有地址走本地代理
  static String _rewrite(String m3u8, Uri base, String referer, String ua) {
    final lines = const LineSplitter().convert(m3u8);
    final out = <String>[];
    for (final raw in lines) {
      final l = raw.trim();
      if (l.isEmpty) {
        out.add(raw);
        continue;
      }
      if (l.startsWith('#')) {
        if (l.startsWith('#EXT-X-CUE-OUT') || l.startsWith('#EXT-X-CUE-IN')) continue;
        if (l.contains('URI="')) {
          out.add(l.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
            final abs = base.resolve(m.group(1)!).toString();
            return 'URI="${_wrapped(abs, referer, ua)}"';
          }));
          continue;
        }
        out.add(raw);
        continue;
      }
      final abs = base.resolve(l).toString();
      if (isAd(abs)) continue;
      out.add(_wrapped(abs, referer, ua));
    }
    return out.join('\n');
  }
}
