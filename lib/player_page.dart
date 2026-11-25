import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _ua =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

class PlayerPage extends StatefulWidget {
  final String title;
  final String playPage;
  final String userAgent;
  final String referer;
  const PlayerPage({
    super.key,
    required this.title,
    required this.playPage,
    this.userAgent = '',
    this.referer = '',
  });
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
                userAgent: widget.userAgent.isEmpty ? _ua : widget.userAgent,
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
