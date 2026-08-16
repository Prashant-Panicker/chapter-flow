import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/chapter.dart';
import '../services/extraction_js.dart';
import '../services/js_result.dart';
import '../services/storage_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/reader_nav_bar.dart';

enum ReaderViewMode { english, bilingual, source }

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.url,
    required this.pageTitle,
    required this.bodyText,
    required this.webViewController,
    this.bookTitle,
    this.chapterTitle,
    this.chapterNumber,
    this.prevUrl,
    this.nextUrl,
    this.tocUrl,
  });

  final String url;
  final String pageTitle;
  final String bodyText;
  final String? bookTitle;
  final String? chapterTitle;
  final String? chapterNumber;
  final String? prevUrl;
  final String? nextUrl;
  final String? tocUrl;
  final InAppWebViewController webViewController;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}
