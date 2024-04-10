import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';

void main() {
  Future<Socket> server = Socket.connect('81.228.254.204', 4040);

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
                  server: server,
                  child: const LoginScreen()
              );
            },
            '/home': (_) {
              return ServerCommunicator(
                  server: server,
                  child: const HomeScreen()
              );
            },
          }
      )
  );
}

const int endOfTransmissionBlock = 23;

enum ClientMessageType {
  login
}

enum ServerMessageType {
  loginResponse
}

class BlockListener {
  static var messageBuffer = Uint8List(0);

  static StreamSubscription<Uint8List> listen({required Socket socket, required void Function(Uint8List block) recieveBlock}){
    return socket.listen((event) {
      for(final byte in event) {
        if(byte == endOfTransmissionBlock) {
          recieveBlock(messageBuffer);
          messageBuffer = Uint8List(0);
        }
        else {
          var grownBuffer = Uint8List(messageBuffer.length + 1);
          grownBuffer.setAll(0, messageBuffer);
          grownBuffer.last = byte;

          messageBuffer = grownBuffer;
        }
      }
    });
  }
}

class ClientMessage {
  late Uint8List messageBuffer;

  ClientMessage(ClientMessageType messageType, int dataSize){
    messageBuffer = Uint8List(dataSize + 2);

    var bufferView = ByteData.view(messageBuffer.buffer);
    bufferView.setUint8(0, messageType.index);
    bufferView.setUint8(messageBuffer.length - 1, endOfTransmissionBlock);
  }

  ByteData get view => ByteData.sublistView(messageBuffer, 1, messageBuffer.length - 1);
}

class ServerCommunicator extends InheritedWidget {
  final Future<Socket> server;

  const ServerCommunicator({super.key, required super.child, required this.server});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static ServerCommunicator of(BuildContext context) => context.getInheritedWidgetOfExactType<ServerCommunicator>()!;
}

class LoginHandler extends StatefulWidget {
  const LoginHandler({super.key});

  @override
  State<StatefulWidget> createState() => _LoginHandlerState();
}

class _LoginHandlerState extends State<LoginHandler> {
  String enteredPassword = '';
  String loginResult = '';
  StreamSubscription<Uint8List>? listener;

  @override void initState() {
    super.initState();

    ServerCommunicator.of(context).server
    .then((socket) {
      listener = BlockListener.listen(
        socket: socket,
        recieveBlock: (message) {
          var messageView = ByteData.view(message.buffer);
          if (messageView.getUint8(0) == ServerMessageType.loginResponse.index) {
            var loginSuccess = messageView.getUint8(1) == 1;

            setState(() {
              loginResult = loginSuccess ? 'välkommen' : 'inloggning misslyckades';
            });

            if (loginSuccess) {
              Navigator.popAndPushNamed(context, '/home');
            }
          }
        }
      );
    });
  }

  @override void dispose() {
    listener?.cancel();
    super.dispose();
  }

  void attemptLogin() {
    ServerCommunicator.of(context).server
    .then((serverSocket){
        var message = ClientMessage(ClientMessageType.login, enteredPassword.length);

        for(var index = 0; index < enteredPassword.length; ++index){
          message.view.setUint8(index, enteredPassword.codeUnitAt(index));
        }

        serverSocket.add(message.messageBuffer);
    })
    .catchError((err) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
    });

    setState(() {
      loginResult = 'kontaktar server';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      verticalDirection: VerticalDirection.down,
      children: [
        TextField(
          decoration: const InputDecoration(
              labelText: 'lösenord',
              border: OutlineInputBorder()
          ),
          autofocus: true,
          onChanged: (inPassword) => enteredPassword = inPassword,
        ),
        Container(height: 16),
        ElevatedButton(
            onPressed: attemptLogin,
            child: const Text('logga in')
        ),
        if(loginResult != '') Text(loginResult)
      ],
    );
  }
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
            leading: Image.asset('images/flutter.png'),
            title: const Text('Stall Diva'),
        ),
        body: const Center(
            child: SizedBox(
              width: 250,
              child: LoginHandler(),
            )
        )
    );
  }
}

class EditableDayHandler extends StatefulWidget {
  const EditableDayHandler({super.key});

  @override
  State<StatefulWidget> createState() => _EditableDayHandlerState();
}

class _EditableDayHandlerState extends State<EditableDayHandler> {
  var controller = TextEditingController();

  @override void initState() {
    super.initState();
  }

  @override void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64.0,
      child: Center(
        child: TextField(
          decoration: null,
          textAlign: TextAlign.center,
          controller: controller,
        ),
      ),
    );
  }
}

class PastureScreen extends StatelessWidget {
  const PastureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.all(32.0),
            child: Text(
              'PASSLISTA',
              style: TextStyle(
                fontSize: 28,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Table(
              border: TableBorder.all(),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                const TableRow(
                  children: [
                    Center(child: Text('Måndag')),
                    Center(child: Text('Tisdag')),
                    Center(child: Text('Onsdag')),
                    Center(child: Text('Torsdag')),
                    Center(child: Text('Fredag')),
                    Center(child: Text('Lördag')),
                    Center(child: Text('Söndag')),
                  ]
                ),
                TableRow(
                  children: List<Widget>.filled(7, const EditableDayHandler())
                ),
              ],
            ),
          )
        ],
      )
    );
  }
}

class StableScreen extends StatelessWidget {
  const StableScreen({super.key});

  List<Widget> createTableRowWidgets(String responsibility){
    return List<Widget>.generate(8, (index) {
      if(index == 0) {
        return Center(
            child: Text(
              responsibility,
              style: const TextStyle(
                  fontStyle: FontStyle.italic
              ),
            )
        );
      }
      else {
        return const EditableDayHandler();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.all(32.0),
            child: Text(
              'PASSLISTA',
              style: TextStyle(
                fontSize: 28,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Table(
              border: TableBorder.all(),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                const TableRow(
                    children: [
                      Center(child: Text('V.32')),
                      Center(child: Text('Måndag')),
                      Center(child: Text('Tisdag')),
                      Center(child: Text('Onsdag')),
                      Center(child: Text('Torsdag')),
                      Center(child: Text('Fredag')),
                      Center(child: Text('Lördag')),
                      Center(child: Text('Söndag')),
                    ]
                ),
                TableRow(
                  children: createTableRowWidgets('INTAG')
                ),
                TableRow(
                  children: createTableRowWidgets('UTSLÄPP')
                ),
              ],
            ),
          )
        ],
      )
    );
  }
}


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<StatefulWidget> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int subScreenSelected = 0;

  void changeSubScreenSelected(Set<int> newSelection) {
    if(newSelection.first != subScreenSelected){
      setState(() {
        subScreenSelected = newSelection.first;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Image.asset('images/flutter.png'),
        title: const Text('Stall Diva'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: SegmentedButton(
              segments: const [
                ButtonSegment(
                    value: 0,
                    label: Text('Stallet')
                ),
                ButtonSegment(
                    value: 1,
                    label: Text('Lösdriften')
                ),
              ],
              selected: {subScreenSelected},
              onSelectionChanged: changeSubScreenSelected,
            ),
          ),
        ],
      ),
      body: switch(subScreenSelected){
        0 => const StableScreen(),
        1 => const PastureScreen(),
        _ => throw UnimplementedError(),
      },
    );
  }
}
