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

class ClientMessage {
  late Uint8List messageBuffer;

  ClientMessage(ClientMessageType messageType, int dataSize){
    messageBuffer = Uint8List(8 + dataSize);

    var bufferView = ByteData.view(messageBuffer.buffer);
    bufferView.setUint32(0, messageType.index, Endian.little);
    bufferView.setUint32(4, dataSize, Endian.little);
  }

  ByteData get viewData => ByteData.sublistView(messageBuffer, 8, messageBuffer.length);
}

class ServerCommunicator extends InheritedWidget {
  final PersistentServerCommunicator communicatorService;
  const ServerCommunicator({super.key, required this.communicatorService, required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static ServerCommunicator of(BuildContext context) => context.getInheritedWidgetOfExactType<ServerCommunicator>()!;

  Stream<Uint8List> get messageStream => communicatorService.stream;
}

class PersistentServerCommunicator {
  late Future<Socket> server;
  late Stream<Uint8List> stream;

  PersistentServerCommunicator(String host) {
    server = Socket.connect(host, 4040);
    stream = startStream().asBroadcastStream();
  }

  Stream<Uint8List> startStream() async* {
    final socket = await server;
    var messageBuffer = BytesBuilder();

    await for(final Uint8List event in socket) {
      for(final int byte in event) {
        messageBuffer.addByte(byte);

        if(messageBuffer.length >= 8) {
          final messageView = ByteData.view(messageBuffer.toBytes().buffer);
          int messageDataSize = messageView.getUint32(4, Endian.little);

          if(messageDataSize == messageBuffer.length - 8) {
            yield messageBuffer.takeBytes();
          }
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