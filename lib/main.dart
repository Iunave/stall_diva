import 'package:flutter/material.dart';

import 'network.dart';
import 'login_screen.dart' show LoginScreen;
import 'home_screen.dart' show HomeScreen;

void main() {
  var communicatorService = PersistentServerCommunicator('stall-diva.se');

  runApp(
    MaterialApp(
      title: 'stall diva schemaplanerare',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.lightBlue
        ),
      ),
      routes: {
        '/': (_) {
          return ServerCommunicator(
              communicatorService: communicatorService,
              child: const LoginScreen(),
          );
        },
        '/home': (_) {
          return ServerCommunicator(
              communicatorService: communicatorService,
              child: const HomeScreen(),
          );
        },
      }
    )
  );
}