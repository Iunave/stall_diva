import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

const int endOfTransmissionBlock = 23;

enum ClientMessageType {
  login,
  getHandler,
  setHandler,
}

enum ServerMessageType {
  loginResponse,
  sentHandlerName,
}

typedef ServerStream = Stream<(int, Uint8List)>;

class ClientMessage {
  late Uint8List messageBuffer;

  ClientMessage(ClientMessageType messageType, int dataSize){
    messageBuffer = Uint8List(dataSize + 2);

    var bufferView = ByteData.view(messageBuffer.buffer);
    bufferView.setUint8(0, messageType.index);
    bufferView.setUint8(messageBuffer.length - 1, endOfTransmissionBlock);
  }

  ByteData get viewData => ByteData.sublistView(messageBuffer, 1, messageBuffer.length - 1);
}

class ServerCommunicator extends InheritedWidget {
  final PersistentServerCommunicator communicatorService;
  const ServerCommunicator({super.key, required this.communicatorService, required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static ServerCommunicator of(BuildContext context) => context.getInheritedWidgetOfExactType<ServerCommunicator>()!;

  ServerStream get messageStream => communicatorService.stream;
}

class PersistentServerCommunicator {
  late Future<Socket> server;
  late ServerStream stream;

  PersistentServerCommunicator(String host) {
    server = Socket.connect(host, 4040);
    stream = startStream()
        .map((event) => (event.first, event.sublist(1)))
        .asBroadcastStream();
  }

  Stream<Uint8List> startStream() async* {
    final socket = await server;
    var messageBuffer = BytesBuilder();
    await for (final event in socket) {
      for (final byte in event) {
        if (byte == endOfTransmissionBlock) {
          yield messageBuffer.takeBytes();
        }
        else {
          messageBuffer.addByte(byte);
        }
      }
    }
  }
}

mixin SendNetworkMessageHelper<T extends StatefulWidget> on State<T> {
  void sendNetworkMessage(ClientMessage message) async {
    try {
      final socket = await ServerCommunicator.of(context).communicatorService.server;
      socket.add(message.messageBuffer);
    }
    catch(err) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
      }
    }
  }
}