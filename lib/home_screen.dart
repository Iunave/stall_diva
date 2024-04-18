import 'network.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';

enum DayHandlerID{
  pasture,
  stableIn,
  stableOut,
}

const weekdays = [
  'Måndag',
  'Tisdag',
  'Onsdag',
  'Torsdag',
  'Fredag',
  'Lördag',
  'Söndag',
];

int weekNumber(){
  return (Jiffy.now().dayOfYear ~/ 7) + 1;
}

class EditableDayHandler extends StatefulWidget {
  final int day;
  final DayHandlerID dayId;
  const EditableDayHandler({super.key, required this.day, required this.dayId});

  int get dayKey => day | (dayId.index << 62);

  @override
  State<StatefulWidget> createState() => _EditableDayHandlerState();
}

class _EditableDayHandlerState extends State<EditableDayHandler> with SendNetworkMessageHelper {
  var textController = TextEditingController();

  void requestServerHandlerName() async {
    var message = ClientMessage(ClientMessageType.getHandler, 8);
    message.viewData.setUint64(0, widget.dayKey, Endian.little);

    sendNetworkMessage(message);
  }

  void listenForServerHandlerName() async {
    final serverCommunicator = ServerCommunicator.of(context);
    await for(final (messageType, messageData) in serverCommunicator.messageStream){
      if(!mounted) break;

      final messageView = ByteData.view(messageData.buffer);
      if (messageType == ServerMessageType.sentHandlerName.index && messageView.getUint64(0, Endian.little) == widget.dayKey) {
        var stringBuilder = StringBuffer();
        for(var index = 8; index < messageView.lengthInBytes - 2; index += 2){
          stringBuilder.writeCharCode(messageView.getUint16(index, Endian.little));
        }

        final newHandler = stringBuilder.toString();
        if(textController.text != newHandler){
          setState(() {
            textController.value = TextEditingValue(
                text: newHandler,
                selection: TextSelection.fromPosition(TextPosition(offset: newHandler.length))
            );
          });
        }
      }
    }
  }

  void onUserChangedHandlerName(String name) async {
    var message = ClientMessage(ClientMessageType.setHandler, 8 + ((name.length + 1) * 2));
    message.viewData.setUint64(0, widget.dayKey, Endian.little);

    for(var index = 0; index < name.length; ++index){
      message.viewData.setUint16(8 + (index * 2), name.codeUnitAt(index), Endian.little);
    }

    sendNetworkMessage(message);
  }

  @override void initState(){
    super.initState();
    listenForServerHandlerName();
    requestServerHandlerName();
  }

  @override void dispose() {
    textController.dispose();
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
          controller: textController,
          onChanged: onUserChangedHandlerName,
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
            Padding(
              padding: const EdgeInsets.all(32.0),
              child: Text(
                'PASSLISTA V.${weekNumber()}',
                style: const TextStyle(
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
                  TableRow(
                      children: List<Widget>.generate(7, (index) {
                        return Center(
                          child: Text(weekdays[index]),
                        );
                      })
                  ),
                  TableRow(
                      children: List<Widget>.generate(7, (index){
                        return EditableDayHandler(
                            day: index,
                            dayId: DayHandlerID.pasture
                        );
                      })
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

  List<Widget> createTableRowWidgets(String responsibility, DayHandlerID id){
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
        return EditableDayHandler(
          day: index - 1,
          dayId: id,
        );
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
                  TableRow(
                      children: List<Widget>.generate(8, (index) {
                        if(index == 0) {
                          return Center(
                              child: Text('V.${weekNumber()}')
                          );
                        }
                        else {
                          return Center(
                              child: Text(weekdays[index - 1])
                          );
                        }
                      })
                  ),
                  TableRow(
                      children: createTableRowWidgets('INTAG', DayHandlerID.stableIn)
                  ),
                  TableRow(
                      children: createTableRowWidgets('UTSLÄPP', DayHandlerID.stableOut)
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
