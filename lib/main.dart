import 'dart:io';
import 'package:flutter/material.dart';

import 'network.dart';
import 'login_screen.dart';
import 'home_screen.dart';

void main() {
  var serverCommunicator = PersistentServerCommunicator(Socket.connect('81.228.254.204', 4040));

  runApp(
      MaterialApp(
          title: 'stall diva chemaplanerare',
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
                  communicatorService: serverCommunicator,
                  child: const LoginScreen()
              );
            },
            '/home': (_) {
              return ServerCommunicator(
                  communicatorService: serverCommunicator,
                  child: const HomeScreen()
              );
            },
          }
      )
  );
}