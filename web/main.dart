import 'dart:convert';
import 'dart:html';
import 'dart:math';

import 'package:skynet/skynet.dart';
import 'package:skynet/src/registry.dart';
import 'package:uuid/uuid.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:http/http.dart' as http;

FileID fileID;

const temporaryTrustedIDs = [
  'd74e7376255077b6174b8531f23b1c4f80031a0a82ead6ca27cdabde109c9cee',
];

void main() {
  String hash = window.location.hash;

  if (hash.contains('#')) hash = hash.substring(1);

  fileID = FileID(
    applicationID: 'skydb-chat-$hash', // ID of your application
    fileType: FileType.PublicUnencrypted,
    filename: 'chat.json', // Filename of the data you want to store
  );

  String portal = window.location.hostname;

  if (portal == 'localhost') portal = 'siasky.net';

  if (portal.contains('.hns.')) {
    portal = portal.split('.hns.')[1];
  }
  print('Portal $portal');

  SkynetConfig.host = portal;

  final FormElement form = querySelector('#loginForm');

  print(form);

  form.onSubmit.listen((event) {
    event.preventDefault();

    username = (querySelector('#usernameField') as InputElement).value;
    password = (querySelector('#passwordField') as InputElement).value;

    user = User(username, password);

    setInitialState();

    password = '';

    (querySelector('#msgField') as InputElement).focus();

    final FormElement form = querySelector('#msgForm');

    setStatus('Online');

    form.onSubmit.listen((event) {
      event.preventDefault();

      if (lockMsgSend) return false;

      print('msg');
      final String msg = (querySelector('#msgField') as InputElement).value;
      print(msg);
      setStatus('Sending message...');
      _sendMsg(msg);

      return false;
    });
    /*   querySelector('#msgField').onSubmit.listen((event) {
      print(event);
    }); */

    _startLoop();
    return false;
  });
}

void setStatus(String status) {
  querySelector('#status').setInnerHtml(status);
}

void setInitialState() {
  final html = '''
  ''';
  querySelector('#output').setInnerHtml('');

  querySelector('#main').style.display = 'block';
}

void setState() {
  String html = '';

  Map<String, String> users = {};

  for (final m in messages) {
    if (!users.containsKey(m.userId)) {
      users[m.userId] = m.username;
    }
    if (greyedOutMessageIds.contains(m.id)) {
      html +=
          '<div class="message"><em>[Sending...] <b>${m.username}</b>: ${m.msg}</em></div>';
    } else {
      String name = '<b>${m.username}</b>';

      if (temporaryTrustedIDs.contains(m.userId)) {
        name = '<b class="trust">✓ ${m.username}</b>';
      }

      String msgText = m.msg;

      if (msgText.length > 3000) {
        msgText = msgText.substring(0, 3000) +
            '... [cut down from ${msgText.length} to 3000 characters by your client]';
      }
      html +=
          '<div class="message">$name: $msgText <em class="time">${timeago.format(m.sendAt)}</em></div>';
    }
  }

  querySelector('#messages').setInnerHtml(html);

  String usersHtml = '<div><b>Users</b></div>';

  for (String userId in users.keys) {
    usersHtml +=
        '<div class="user">${users[userId]} (${userId.substring(0, 8)}...)</div>';
  }

  querySelector('#users').setInnerHtml(usersHtml);
}

User user;

final publicUser = User('open', 'source');

String username, password;

bool firstStart = false;

void _startLoop() async {
  print('_startLoop');
  while (true) {
    for (final userId in [
      'index',
      ...index.keys,
    ]) {
      // if ((userId == user.id) && firstStart) continue;

      if (!threads.contains(userId)) {
        updateUserId(userId);
        threads.add(userId);
        continue;
      }
    }

    await Future.delayed(Duration(seconds: 2));
  }
}

Future<void> updateUserId(String userId) async {
  print('Update $userId');

  try {
    final existing = await lookupRegistry(
        userId == 'index' ? publicUser : User.fromId(userId), fileID);
    if (existing == null) {
      if (userId == 'index') {
        print('Init Chat...');

        // firstStart = true;
        index[user.id] = DateTime.now().millisecondsSinceEpoch;
        final res = await setFile(
            publicUser,
            fileID,
            SkyFile(
              content: utf8.encode(
                json.encode(index),
              ),
              filename: fileID.filename,
              type: 'application/json',
            ));
        threads.remove(userId);
        return;
      } else {
        threads.remove(userId);
        return;
      }
    }

    // print('$userId ${existing.value.revision}');

    final skylink = String.fromCharCodes(existing.value.data);

    if (userSkylinkCache[userId] == skylink) {
      threads.remove(userId);
      return;
    }

    print('Downloading updated JSON...');

    // download the data in that Skylink
    final res = await http.get(Uri.https(SkynetConfig.host, '$skylink'));

    final metadata = json.decode(res.headers['skynet-file-metadata']);

    final file = SkyFile(
        content: res.bodyBytes,
        filename: metadata['filename'],
        type: res.headers['content-type']);

    final data = json.decode(file.asString);

    if (userId == 'index') {
      index = data.cast<String, int>();

      bool update = false;

      if (!index.containsKey(user.id)) {
        index[user.id] = DateTime.now().millisecondsSinceEpoch;
        update = true;
        // firstStart = true;
      }
      final now = DateTime.now().millisecondsSinceEpoch;

      final list = List.from(index.keys);

      for (final key in list) {
        int diff = now - index[key];

        if (diff > ((60 * (30 + Random().nextInt(30))) * 1000)) {
          print('Removing $key from index...');
          index.remove(key);
          update = true;
        }
      }

      if (update) {
        final res = await setFile(
            publicUser,
            fileID,
            SkyFile(
              content: utf8.encode(
                json.encode(index),
              ),
              filename: fileID.filename,
              type: 'application/json',
            ));
        print(res);
      }

      userSkylinkCache[userId] = skylink;

      setState();
    } else {
      bool firstOwnUser = (userId == user.id) && ownMessages.isEmpty;

      for (final item in data) {
        final msg = Message.fromJson(item, userId);

        if (greyedOutMessageIds.contains(msg.id)) {
          greyedOutMessageIds.remove(msg.id);
        }

        if (!messageIds.contains(msg.id)) {
          messages.add(msg);
          messageIds.add(msg.id);
        }

        if (firstOwnUser) ownMessages.add(msg);
      }

      userSkylinkCache[userId] = skylink;

      messages.sort((a, b) => b.sendAt.compareTo(a.sendAt));
      setState();
    }
  } catch (e) {
    print(e);
  }
  threads.remove(userId);
}

Set<String> threads = {};

Map<String, int> failCount = {};

Map<String, String> userSkylinkCache = {};

Map<String, int> index = {};

Set<String> messageIds = {};

Set<String> greyedOutMessageIds = {};

List<Message> messages = [];
List<Message> ownMessages = [];

bool lockMsgSend = false;

Future<void> _sendMsg(String message) async {
  lockMsgSend = true;

  final ie = (querySelector('#msgField') as InputElement);

  ie.value = '';

  try {
    final msg = Message(user.id, username, message);
    ownMessages.add(msg);
    messages.add(msg);
    messageIds.add(msg.id);
    greyedOutMessageIds.add(msg.id);

    messages.sort((a, b) => b.sendAt.compareTo(a.sendAt));

    setState();

    if (ownMessages.length > 32) {
      ownMessages.removeAt(0);
    }

    final res = await setFile(
        user,
        fileID,
        SkyFile(
          content: utf8.encode(
            json.encode(ownMessages),
          ),
          filename: fileID.filename,
          type: 'application/json',
        ));
    print(res);
    if (res == true) {
      ie.focus();

      firstStart = false;
    }

    setStatus('Online');

    // TODO setState(() {});
  } catch (e) {
    ie.value = message;
    setStatus('Error sending message: $e');
  }
  lockMsgSend = false;
}

class Message {
  String id;

  String userId;
  String username;

  String msg;

  DateTime sendAt;
  Message(this.userId, this.username, this.msg) {
    sendAt = DateTime.now();
    id = Uuid().v4();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'msg': msg,
        'sendAt': sendAt.millisecondsSinceEpoch,
      };

  Message.fromJson(Map m, this.userId) {
    id = m['id'] ?? '';
    username = m['username'] ?? '';
    msg = m['msg'] ?? '';
    sendAt = DateTime.fromMillisecondsSinceEpoch(m['sendAt'] ?? 0);
  }
}
