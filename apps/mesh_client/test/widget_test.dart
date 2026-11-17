import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_client/main.dart';
import 'package:mesh_client/state/mesh_app_controller.dart';
import 'package:mesh_client/ui/widgets/markdown_message_view.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

void main() {
  testWidgets('Renders AGY LAN Mesh multi-session console cleanly',
      (WidgetTester tester) async {
    final controller = MeshAppController();
    await tester.pumpWidget(AgyMeshApp(controller: controller));
    await tester.pump();

    expect(find.text('AGY LAN Mesh'), findsOneWidget);
    expect(
      find.textContaining('Work Across Any Computer Using Your Central Brain'),
      findsOneWidget,
    );
  });

  testWidgets('Renders screenshot-ready Session Summary Brag Card with stats',
      (WidgetTester tester) async {
    const summary = SessionCompletionSummary(
      issue: 'Systemd worker crashing every 30s on arch-box',
      findings: 'Missing WorkingDirectory and restrictive MemoryMax=64M',
      actionsTaken: 'Updated unit override, ran daemon-reload, verified active',
      activeDurationMs: 28400,
      sessionSpanMs: 45000,
      turnsCount: 2,
      toolCallsCount: 6,
      inputTokens: 12400,
      outputTokens: 1600,
      thinkingTokens: 2000,
      modelLabel: 'Gemini 4 Carbon (Medium)',
      targetNodeName: 'arch-box',
      workspacePath: '/etc/systemd/system',
      generatedAt: '2026-11-17T11:00:00Z',
    );
    final msg = SessionMessage(
      id: 'sum-1',
      role: 'summary',
      text: summary.toMarkdown(sessionTitle: 'Worker Crash Fix'),
      timestamp: '2026-11-17T11:00:00Z',
      completionSummary: summary,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubbleCard(
              message: msg,
              sessionTitle: 'Worker Crash Fix',
            ),
          ),
        ),
      ),
    );

    expect(
      find.textContaining('SESSION COMPLETED  •  AGY LAN MESH'),
      findsOneWidget,
    );
    expect(find.text('Worker Crash Fix'), findsOneWidget);
    expect(
      find.text('Systemd worker crashing every 30s on arch-box'),
      findsOneWidget,
    );
    expect(find.text('28.4s'), findsOneWidget);
    expect(find.text('16.0k'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });
}
