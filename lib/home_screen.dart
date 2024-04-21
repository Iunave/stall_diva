import 'network.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';

const weekdays = [
  'Måndag',
  'Tisdag',
  'Onsdag',
  'Torsdag',
  'Fredag',
  'Lördag',
  'Söndag',
];

enum DayHandlerID{
  pasture,
  stableIn,
  stableOut,
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
    await for(final ServerMessage message in serverCommunicator.messageStream){
      if(!mounted) break;

      if (message.type == ServerMessageType.sentHandlerName.index && message.viewData.getUint64(0, Endian.little) == widget.dayKey) {
        var stringBuilder = StringBuffer();
        for(int index = message.headerSize + 8; index < message.messageSize - 2; index += 2){ //dont read the null char
          stringBuilder.writeCharCode(message.viewMessage.getUint16(index, Endian.little));
        }

        final String newHandler = stringBuilder.toString();
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

  @override void didUpdateWidget(covariant EditableDayHandler oldWidget) {
    super.didUpdateWidget(oldWidget);

    if(oldWidget.dayKey != widget.dayKey){
      requestServerHandlerName();
    }
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

class PastureTable extends StatelessWidget {
  final int weekNumber;
  const PastureTable({super.key, required this.weekNumber});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                    day: ((weekNumber - 1) * 7) + index,
                    dayId: DayHandlerID.pasture
                );
              })
          ),
        ],
      ),
    );
  }
}

class StableTable extends StatelessWidget {
  final int weekNumber;
  const StableTable({super.key, required this.weekNumber});

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
          day: ((weekNumber - 1) * 7) + index - 1,
          dayId: id,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Table(
        border: TableBorder.all(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
              children: List<Widget>.generate(8, (index) {
                if(index == 0) {
                  return const Center(
                    child: Text(
                      'veckodag',
                      style: TextStyle(
                        fontStyle: FontStyle.italic
                      ),
                    )
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
  int viewingWeekNumber = Jiffy.now().weekOfYear;

  void changeSubScreenSelected(Set<int> newSelection) {
    if(newSelection.first != subScreenSelected){
      setState(() {
        subScreenSelected = newSelection.first;
      });
    }
  }

  void changeViewingWeekNumber(int newWeekNumber) {
    if(newWeekNumber != viewingWeekNumber && newWeekNumber >= 1 && newWeekNumber <= 53) {
      setState(() {
        viewingWeekNumber = newWeekNumber;
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
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  onPressed: () => changeViewingWeekNumber(viewingWeekNumber - 1),
                  icon: const Icon(Icons.arrow_back)
              ),
              Padding(
                padding: const EdgeInsets.all(36.0),
                child: Text(
                  'PASSLISTA V.$viewingWeekNumber',
                  style: const TextStyle(
                      fontSize: 28.0
                  ),
                ),
              ),
              IconButton(
                  onPressed: () => changeViewingWeekNumber(viewingWeekNumber + 1),
                  icon: const Icon(Icons.arrow_forward)
              ),
            ],
          ),
          switch(subScreenSelected){
            0 => StableTable(weekNumber: viewingWeekNumber),
            1 => PastureTable(weekNumber: viewingWeekNumber),
            _ => throw UnimplementedError(),
          }
        ],
      ),
    );
  }
}
