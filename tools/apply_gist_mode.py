#!/usr/bin/env python3
from pathlib import Path

gist_const = Path("lib/services/gist_system_prompt.inc.dart").read_text()
path = Path("lib/services/translation_service.dart")
text = path.read_text()

enum_block = """
/// How chapter text is rendered by the translator.
enum TranslationMode {
  /// Full paragraph-by-paragraph literary translation.
  full,

  /// Condensed narrative: events, dialogue, and context kept; filler cut.
  gist,
}

"""

if "enum TranslationMode" not in text:
    text = text.replace(
        "const String _systemPrompt =",
        enum_block + "const String _systemPrompt =",
        1,
    )

marker = "    'only the translated text.';\n\nconst String _glossarySystemPrompt ="
if "_gistSystemPrompt" not in text:
    if marker not in text:
        raise SystemExit("glossary marker missing")
    text = text.replace(
        marker,
        "    'only the translated text.';\n\n" + gist_const + "const String _glossarySystemPrompt =",
        1,
    )

old_ctor = """  TranslationService({required String apiKey})
      : _dio = Dio(BaseOptions(
          baseUrl: 'https://api.moonshot.ai/v1',
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 30),
          // Streaming keeps the connection alive with continuous data,
          // so a longer receiveTimeout is safe as a backstop.
          receiveTimeout: const Duration(minutes: 10),
        ));

  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  static Future<void> _translationQueue = Future<void>.value();
  static final Map<String, String> _titleCache = <String, String>{};
  static const String model = 'kimi-k2.6';
"""

new_ctor = """  TranslationService({
    required String apiKey,
    this.mode = TranslationMode.full,
  }) : _dio = Dio(BaseOptions(
          baseUrl: 'https://api.moonshot.ai/v1',
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 30),
          // Streaming keeps the connection alive with continuous data,
          // so a longer receiveTimeout is safe as a backstop.
          receiveTimeout: const Duration(minutes: 10),
        ));

  final TranslationMode mode;
  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  static Future<void> _translationQueue = Future<void>.value();
  static final Map<String, String> _titleCache = <String, String>{};
  static const String model = 'kimi-k2.6';
"""

if "this.mode = TranslationMode.full" not in text:
    if old_ctor not in text:
        raise SystemExit("old ctor not found")
    text = text.replace(old_ctor, new_ctor, 1)

old_user = """    prompt
      ..writeln(
        'Translate the following novel text into English. Keep paragraph '
        'breaks.',
      )
      ..writeln()
      ..write(chunk);

    final response = await _dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: _cancelToken,
      data: {
        'model': model,
        // Thinking stays disabled for the live stream so tokens appear
        // immediately. Temperature must be 0.6 when thinking is off.
        'temperature': 0.6,
        'stream': true,
        'thinking': {'type': 'disabled'},
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': prompt.toString()},
        ],
      },"""

new_user = """    final isGist = mode == TranslationMode.gist;
    prompt
      ..writeln(
        isGist
            ? 'Produce a condensed English version of the following novel '
                'text. Keep event order, meaningful dialogue, and context; '
                'cut pure filler. Keep paragraph breaks where scenes or '
                'speakers change.'
            : 'Translate the following novel text into English. Keep paragraph '
                'breaks.',
      )
      ..writeln()
      ..write(chunk);

    final response = await _dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: _cancelToken,
      data: {
        'model': model,
        // Thinking stays disabled for the live stream so tokens appear
        // immediately. Temperature must be 0.6 when thinking is off.
        'temperature': 0.6,
        'stream': true,
        'thinking': {'type': 'disabled'},
        'messages': [
          {
            'role': 'system',
            'content': isGist ? _gistSystemPrompt : _systemPrompt,
          },
          {'role': 'user', 'content': prompt.toString()},
        ],
      },"""

if "isGist ? _gistSystemPrompt" not in text:
    if old_user not in text:
        raise SystemExit("old user prompt block not found")
    text = text.replace(old_user, new_user, 1)

path.write_text(text)
print("translation patched", path.stat().st_size)

rpath = Path("lib/screens/reader_screen.dart")
rtext = rpath.read_text()
old = "    return TranslationService(apiKey: key);\n  }\n"
new = (
    "    final gist = await StorageService.instance.getGistMode();\n"
    "    return TranslationService(\n"
    "      apiKey: key,\n"
    "      mode: gist ? TranslationMode.gist : TranslationMode.full,\n"
    "    );\n"
    "  }\n"
)
if "TranslationMode.gist" not in rtext:
    if old not in rtext:
        raise SystemExit("reader return not found")
    rtext = rtext.replace(old, new, 1)
rpath.write_text(rtext)
print("reader patched", rpath.stat().st_size)
