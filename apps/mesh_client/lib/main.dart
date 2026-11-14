import 'package:flutter/material.dart';

import 'state/mesh_app_controller.dart';
import 'ui/mesh_home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MeshAppController();
  await controller.init();
  runApp(AgyMeshApp(controller: controller));
}

class AgyMeshApp extends StatelessWidget {
  final MeshAppController controller;

  const AgyMeshApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AGY LAN Mesh',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF38BDF8),
          brightness: Brightness.dark,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0284C7),
          brightness: Brightness.light,
        ),
      ),
      home: MeshHomePage(controller: controller),
    );
  }
}
