import 'network.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class LoginHandler extends StatefulWidget {
  const LoginHandler({super.key});

  @override
  State<StatefulWidget> createState() => _LoginHandlerState();
}

class _LoginHandlerState extends State<LoginHandler> with SendNetworkMessageHelper {
  String enteredPassword = '';
  String loginResult = '';

  void attemptLogin() {
    setState(() {
      loginResult = 'kontaktar server';
    });

    enteredPassword = enteredPassword.trim();
    var message = ClientMessage(ClientMessageType.login, enteredPassword.length + 1);

    for(var index = 0; index < enteredPassword.length; ++index){
      message.viewData.setUint8(index, enteredPassword.codeUnitAt(index));
    }

    sendNetworkMessage(message);
  }

  void listenForLoginResponse() async {
    final serverCommunicator = ServerCommunicator.of(context);
    await for(final (messageType, messageData) in serverCommunicator.messageStream){
      if (messageType == ServerMessageType.loginResponse.index) {
        final messageView = ByteData.view(messageData.buffer);
        final loginSuccess = messageView.getUint8(0) == 1;

        if(loginSuccess){
          Navigator.popAndPushNamed(context, '/home');
          break;
        }
        else{
          setState(() {
            loginResult = 'inloggning misslyckades';
          });
        }
      }
    }
  }

  @override void initState() {
    super.initState();
    listenForLoginResponse();
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
        Text(loginResult)
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