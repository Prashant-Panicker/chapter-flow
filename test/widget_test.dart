// This is a basic Flutter widget test.
//
// Note: Full app testing requires mocking Hive, flutter_secure_storage, and
// InAppWebView. For now, this test is minimal.
// TODO: Add comprehensive tests with proper mocking.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chapterflow/main.dart';

void main() {
  setUp(() {
    // Every tab is mounted by the IndexedStack at launch, and each one reads
    // preferences from initState.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('ChapterFlowApp widget builds', (tester) async {
    await tester.pumpWidget(const ChapterFlowApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

