import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'network.dart';
import 'login_screen.dart';
import 'home_screen.dart';

void main() async {
  const String host = 'ws://stall-diva.se';
  final Uri serverUrl = Uri.parse(host);

  var wsServer = WebSocketChannel.connect(serverUrl);
  await wsServer.ready;

  wsServer.stream.listen((message) {
    message.
  });

  var communicatorService = PersistentServerCommunicator(host);

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