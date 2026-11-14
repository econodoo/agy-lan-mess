import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_client/main.dart';
import 'package:mesh_client/state/mesh_app_controller.dart';

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
}
