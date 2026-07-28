import 'dart:convert';

/// Unwraps the value returned by [InAppWebViewController.evaluateJavascript].
///
/// Platforms differ:
/// - some return the raw JS value
/// - some return a JSON-encoded string (so a JS string is double-quoted)
/// - our extract script itself returns JSON.stringify(...), so we may need
///   one or two decode passes to get a Map.
Map<String, dynamic> parseExtractResult(dynamic raw) {
  if (raw == null) {
    throw const FormatException('Empty extract result from page');
  }

  dynamic value = raw;

  // Peel string wrappers until we have a Map or can decode JSON object text.
  for (var i = 0; i < 3; i++) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is! String) {
      value = value.toString();
    }
    final String s = value.trim();
    if (s.isEmpty || s == 'null' || s == 'undefined') {
      throw const FormatException('Empty extract result from page');
    }
    // Strip surrounding quotes from a JSON string literal if present.
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        value = jsonDecode(s);
        continue;
      } catch (_) {
        // fall through to object decode
      }
    }
    if (s.startsWith('{')) {
      value = jsonDecode(s);
      continue;
    }
    // Last resort: treat as failure
    throw FormatException('Could not parse extract result: ${s.length > 120 ? s.substring(0, 120) : s}');
  }

  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw const FormatException('Extract result was not a JSON object');
}
