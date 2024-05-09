import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'network.dart';
import 'login_screen.dart' show LoginScreen;
import 'home_screen.dart' show HomeScreen;

void main() {
  Intl.systemLocale = 'sv';
  initializeDateFormatting(Intl.getCurrentLocale());

  String host = const String.fromEnvironment("host");
  var communicatorService = PersistentServerCommunicator(host);

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