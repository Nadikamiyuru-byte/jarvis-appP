// JARVIS for Android (Flutter) - v1
// "Jarvis" wake word (Picovoice Porcupine) -> app opens -> speech_to_text -> Claude -> flutter_tts
// A foreground service (notification) keeps the app alive so it can hear the wake word.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

const claudeModel = 'claude-sonnet-5-5';
const systemPrompt =
    'You are JARVIS, a calm, witty, highly capable personal AI assistant on the user\'s phone. '
    'You are speaking out loud: reply in 1-3 short spoken sentences, no markdown, no lists, no emojis. '
    'Address the user as "sir" occasionally. The user may speak English or Sinhala or a mix; '
    'understand all of it but always reply in English.';

// ---- foreground service (only keeps the process alive; the logic runs in the app) ----
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(KeepAliveHandler());
}

class KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

void main() => runApp(const JarvisApp());

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const WithForegroundTask(child: JarvisHome()),
      );
}

enum JState { idle, listening, thinking, speaking }

class JarvisHome extends StatefulWidget {
  const JarvisHome({super.key});
  @override
  State<JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<JarvisHome> {
  final tts = FlutterTts();
  final speech = SpeechToText();
  PorcupineManager? _porcupine;
  final List<Map<String, String>> _history = [];

  String anthropicKey = '';
  String picoKey = '';
  String locale = 'en_US'; // switch to si_LK for Sinhala recognition
  JState state = JState.idle;
  String status = 'Starting...';
  String youSaid = '';
  String jarvisSaid = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    anthropicKey = prefs.getString('anthropic') ?? '';
    picoKey = prefs.getString('pico') ?? '';
    locale = prefs.getString('locale') ?? 'en_US';

    await [Permission.microphone, Permission.notification].request();
    // needed so the app can pop itself open when it hears "Jarvis" from the background
    if (!await FlutterForegroundTask.canDrawOverlays) {
      await FlutterForegroundTask.openSystemAlertWindowSettings();
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'jarvis_listening',
        channelName: 'Jarvis listening',
        channelDescription: 'Jarvis is listening for the wake word',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    if (!await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'Jarvis',
        notificationText: 'Say "Jarvis"',
        callback: startCallback,
      );
    }

    await tts.setLanguage('en-GB');
    await tts.setSpeechRate(0.5);
    await tts.awaitSpeakCompletion(true);
    await speech.initialize();

    if (anthropicKey.isEmpty || picoKey.isEmpty) {
      setState(() => status = 'Open settings and add your API keys');
      return;
    }
    await _startWake();
  }

  Future<void> _startWake() async {
    try {
      await _porcupine?.delete();
      _porcupine = await PorcupineManager.fromBuiltInKeywords(
        picoKey,
        [BuiltInKeyword.JARVIS],
        _onWake,
        errorCallback: (e) => setState(() => status = 'Wake word error: ${e.message}'),
      );
      await _porcupine!.start();
      setState(() {
        state = JState.idle;
        status = 'Say "Jarvis"';
      });
    } on PorcupineException catch (e) {
      setState(() => status = 'Picovoice error: ${e.message}');
    }
  }

  Future<void> _onWake(int keywordIndex) async {
    if (_busy) return;
    _busy = true;
    try {
      await _porcupine?.stop(); // free the mic for speech recognition
      FlutterForegroundTask.launchApp(); // bring Jarvis to the front
      setState(() {
        state = JState.speaking;
        status = 'Yes, sir?';
      });
      await tts.speak('Yes, sir?');

      setState(() {
        state = JState.listening;
        status = 'Listening...';
      });
      final text = await _listen();
      if (text.isNotEmpty) {
        setState(() {
          youSaid = text;
          state = JState.thinking;
          status = 'Thinking...';
        });
        final reply = await _askClaude(text);
        setState(() {
          jarvisSaid = reply;
          state = JState.speaking;
          status = 'Speaking...';
        });
        await tts.speak(reply);
      }
    } catch (e) {
      setState(() => status = 'Error: $e');
    } finally {
      _busy = false;
      await _porcupine?.start();
      if (mounted) {
        setState(() {
          state = JState.idle;
          status = 'Say "Jarvis"';
        });
      }
    }
  }

  Future<String> _listen() async {
    final c = Completer<String>();
    await speech.listen(
      localeId: locale,
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 2),
      onResult: (r) {
        if (r.finalResult && !c.isCompleted) c.complete(r.recognizedWords);
      },
    );
    final text = await c.future.timeout(const Duration(seconds: 20), onTimeout: () => '');
    await speech.stop();
    return text.trim();
  }

  Future<String> _askClaude(String text) async {
    _history.add({'role': 'user', 'content': text});
    try {
      final r = await http.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'x-api-key': anthropicKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': claudeModel,
          'max_tokens': 300,
          'system': systemPrompt,
          'messages': _history,
        }),
      );
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200) {
        _history.removeLast();
        return 'Claude returned an error, sir. Please check the API key.';
      }
      final reply = (j['content'] as List)
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String)
          .join(' ')
          .trim();
      _history.add({'role': 'assistant', 'content': reply});
      while (_history.length > 20) {
        _history.removeAt(0);
      }
      return reply;
    } catch (e) {
      _history.removeLast();
      return 'I could not reach the internet, sir.';
    }
  }

  Future<void> _openSettings() async {
    final a = TextEditingController(text: anthropicKey);
    final p = TextEditingController(text: picoKey);
    String loc = locale;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Settings'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: a, decoration: const InputDecoration(labelText: 'Anthropic API key')),
            TextField(controller: p, decoration: const InputDecoration(labelText: 'Picovoice AccessKey')),
            const SizedBox(height: 12),
            DropdownButton<String>(
              value: loc,
              items: const [
                DropdownMenuItem(value: 'en_US', child: Text('Listen: English')),
                DropdownMenuItem(value: 'si_LK', child: Text('Listen: Sinhala')),
              ],
              onChanged: (v) => setD(() => loc = v ?? 'en_US'),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('anthropic', a.text.trim());
                await prefs.setString('pico', p.text.trim());
                await prefs.setString('locale', loc);
                anthropicKey = a.text.trim();
                picoKey = p.text.trim();
                locale = loc;
                if (ctx.mounted) Navigator.pop(ctx);
                await _startWake();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Color get _orbColor => switch (state) {
        JState.idle => const Color(0xFF00B4D8),
        JState.listening => const Color(0xFF00FF9C),
        JState.thinking => const Color(0xFFFFB703),
        JState.speaking => const Color(0xFF48CAE4),
      };

  @override
  Widget build(BuildContext context) {
    final big = state != JState.idle;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('J.A.R.V.I.S', style: TextStyle(letterSpacing: 6)),
        centerTitle: true,
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
            width: big ? 200 : 140,
            height: big ? 200 : 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _orbColor.withOpacity(0.15),
              border: Border.all(color: _orbColor, width: 3),
              boxShadow: [BoxShadow(color: _orbColor.withOpacity(0.6), blurRadius: big ? 60 : 25, spreadRadius: big ? 10 : 2)],
            ),
          ),
          const SizedBox(height: 32),
          Text(status, style: TextStyle(color: _orbColor, fontSize: 18)),
          const SizedBox(height: 24),
          if (youSaid.isNotEmpty) Text('You: $youSaid', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          if (jarvisSaid.isNotEmpty) Text(jarvisSaid, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          const Spacer(),
          const Text('Wake word: "Jarvis"', style: TextStyle(color: Colors.white38)),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _porcupine?.delete();
    super.dispose();
  }
}
