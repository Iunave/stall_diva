import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';

import 'network.dart';

enum DayHandlerID {
  pasture,
  stableIn,
  stableOut,
}

class EditableDayHandler extends StatefulWidget {
  final Jiffy date;
  final DayHandlerID handlerId;
  const EditableDayHandler({super.key, required this.date, required this.handlerId});

  int get handlerKey => handlerId.index | (date.dayOfYear << 16) | (date.year << 32);

  @override
  State<StatefulWidget> createState() => _EditableDayHandlerState();
}

class _EditableDayHandlerState extends State<EditableDayHandler> with SendNetworkMessageHelper {
  var textController = TextEditingController();

  void requestServerHandlerName() async {
    var message = ClientMessage(ClientMessageType.getHandler, 8);
    message.viewData.setUint64(0, widget.handlerKey, Endian.little);

    sendNetworkMessage(message);
  }

  void listenForServerHandlerName() async {
    final serverCommunicator = ServerCommunicator.of(context);
    await for(final ServerMessage message in serverCommunicator.messageStream){
      if(!mounted) break;

      if (message.type == ServerMessageType.sentHandlerName.index && message.viewData.getUint64(0, Endian.little) == widget.handlerKey) {
        var stringBuilder = StringBuffer();
        for(int index = message.headerSize + 8; index < message.messageSize - 2; index += 2) { //dont read the null char
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
    message.viewData.setUint64(0, widget.handlerKey, Endian.little);

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

    if(oldWidget.handlerKey != widget.handlerKey){
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
          maxLines: null,
          textAlign: TextAlign.center,
          controller: textController,
          onChanged: onUserChangedHandlerName,
        ),
      ),
    );
  }
}

abstract class TableBase extends StatelessWidget {
  final Jiffy startDate;
  const TableBase({super.key, required this.startDate});

  String getDayName(int offset) {
    const weekdays = [
      'Måndag',
      'Tisdag',
      'Onsdag',
      'Torsdag',
      'Fredag',
      'Lördag',
      'Söndag',
    ];

    final Jiffy offsetDate = startDate.add(days: offset);
    return weekdays[offsetDate.dayOfWeek - 1];
  }
}

class PastureTable extends TableBase {
  const PastureTable({super.key, required super.startDate});

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
                child: Text(getDayName(index)),
              );
            })
          ),
          TableRow(
            children: List<Widget>.generate(7, (index){
              return EditableDayHandler(
                  date: startDate.add(days: index),
                  handlerId: DayHandlerID.pasture
              );
            })
          ),
        ],
      ),
    );
  }
}

class StableTable extends TableBase {
  const StableTable({super.key, required super.startDate});

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
          date: startDate.add(days: index - 1),
          handlerId: id,
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
                    child: Text(getDayName(index - 1))
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
  late Jiffy viewingDate;

  _HomeScreenState() {
    viewingDate = Jiffy.now().toLocal();
    viewingDate = viewingDate.subtract(days: viewingDate.dayOfWeek - 1); //floor to monday
  }

  void changeSubScreenSelected(Set<int> newSelection) {
    if(newSelection.first != subScreenSelected){
      setState(() {
        subScreenSelected = newSelection.first;
      });
    }
  }

  void nextWeekNumber() {
    setState(() {
      viewingDate = viewingDate.add(days: 7);
    });
  }

  void prevWeekNumber() {
    setState(() {
      viewingDate = viewingDate.subtract(days: 7);
    });
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
                  onPressed: prevWeekNumber,
                  icon: const Icon(Icons.arrow_back)
              ),
              Padding(
                padding: const EdgeInsets.all(36.0),
                child: Text(
                  'PASSLISTA ${viewingDate.year} V.${viewingDate.weekOfYear}',
                  style: const TextStyle(
                      fontSize: 28.0
                  ),
                ),
              ),
              IconButton(
                  onPressed: nextWeekNumber,
                  icon: const Icon(Icons.arrow_forward)
              ),
            ],
          ),
          switch(subScreenSelected){
            0 => StableTable(startDate: viewingDate,),
            1 => PastureTable(startDate: viewingDate,),
            _ => throw UnimplementedError(),
          }
        ],
      ),
    );
  }
}
