import 'dart:convert';
import 'dart:html';
import 'dart:math';

import 'package:skynet/skynet.dart';
import 'package:skynet/src/registry.dart';
import 'package:uuid/uuid.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:http/http.dart' as http;

FileID fileID;

FileID archiveFileID;

const temporaryTrustedIDs = [
  'd74e7376255077b6174b8531f23b1c4f80031a0a82ead6ca27cdabde109c9cee',
];

void main() {
  Storage localStorage = window.localStorage;

  String hash = window.location.hash;

  if (hash.contains('#')) hash = hash.substring(1);

  window.onHashChange.listen((event) {
    window.location.reload();
  });

  fileID = FileID(
    applicationID: 'skydb-chat-$hash', // ID of your application
    fileType: FileType.PublicUnencrypted,
    filename: 'chat.json', // Filename of the data you want to store
  );

  archiveFileID = FileID(
    applicationID: 'skydb-chat-$hash', // ID of your application
    fileType: FileType.PublicUnencrypted,
    filename: 'archive.json', // Filename of the data you want to store
  );

  String portal = window.location.hostname;

  if (portal == 'localhost') portal = 'siasky.net';

  if (portal.contains('.hns.')) {
    portal = portal.split('.hns.')[1];
  }
  print('Portal $portal');

  SkynetConfig.host = portal;

  try {
    if (localStorage.containsKey('login')) {
      final entry = localStorage['login'];
      final data = json.decode(entry);

      username = data['username'];
      user = User.fromSeed(data['seed'].cast<int>());

      setInitialState();
      return;
    }
  } catch (e) {
    print(e);
  }

  final FormElement form = querySelector('#loginForm');

  print(form);

  form.onSubmit.listen((event) {
    event.preventDefault();

    username = (querySelector('#usernameField') as InputElement).value;
    password = (querySelector('#passwordField') as InputElement).value;

    final bool stayLoggedIn =
        (querySelector('#stayField') as CheckboxInputElement).checked;

    user = User(username, password, keepSeed: stayLoggedIn);

    if (stayLoggedIn) {
      localStorage['login'] = json.encode(
        {
          'username': username,
          'seed': user.seed,
        },
      );
      user.seed = null;
    }

    setInitialState();

    password = '';

    return false;
  });
}

void setStatus(String status) {
  querySelector('#status').setInnerHtml(status);
}

void setInitialState() {
  querySelector('#output').setInnerHtml('');

  querySelector('#main').style.display = 'block';

  (querySelector('#msgField') as InputElement).focus();

  (querySelector('#logout-button') as ButtonElement).onClick.listen((event) {
    window.localStorage.remove('login');
    window.location.reload();
  });

  final FormElement form = querySelector('#msgForm');

  setStatus('Online');

  form.onSubmit.listen((event) {
    event.preventDefault();

    if (lockMsgSend) return false;

    print('msg');
    final String msg = (querySelector('#msgField') as InputElement).value;
    print(msg);
    if (ownMessages.isEmpty) {
      setStatus(
          'Sending message... (The first message with your new account can take up to 1 min)');
    } else {
      setStatus('Sending message...');
    }
    _sendMsg(msg);

    return false;
  });

  _startLoop();
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
      String name = '${m.username}';
      name = escapeHtml(name);

      String richName = '$name (${m.userId})';

      name = '<b title="${richName}">${name}</b>';

      if (temporaryTrustedIDs.contains(m.userId)) {
        name = '<b class="trust" title="${richName}">✓ ${m.username}</b>';
      }

      String msgText = m.msg;
      msgText = escapeHtml(msgText);

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
    final cl = index.containsKey(userId) ? 'user' : 'archived-user';
    usersHtml +=
        '<div class="$cl">${escapeHtml(users[userId])} (${userId.substring(0, 8)}...)</div>';
  }

  querySelector('#users').setInnerHtml(usersHtml);
}

String escapeHtml(String potentialHtml) {
  return potentialHtml.replaceAll('<', "&lt;").replaceAll('>', "&gt;");
}

User user;

final publicUser = User('open', 'source');

String username, password;

bool firstStart = false;

void _startLoop() async {
  print('_startLoop');

  // threads.add('archive');

  // loadArchive(loadUserIDs: true);

  while (true) {
    refreshCount++;

    if (refreshCount % 300 == 0) {
      cleaningFlow();
    }
    for (final userId in [
      'index',
      ...index.keys,
      'archive',
    ]) {
      // if ((userId == user.id) && firstStart) continue;

      if (!threads.contains(userId)) {
        /*        if (userId == 'archive') {
          loadArchive();
        } else { */
        updateUserId(userId);
        /*    } */
        threads.add(userId);
        continue;
      }
    }

    await Future.delayed(Duration(seconds: 3));
  }
}

int refreshCount = 0;

/* Future<void> loadArchive({bool loadUserIDs = false}) async {
  print('Load archive');
  try {
    final archiveRes = await getFile(publicUser, archiveFileID);

    archive = json.decode(archiveRes.asString ?? '{}');

    if (loadUserIDs) {
      // TODO updateUserId

      for (final id in archive.keys) {
        updateUserId(id);
      }
    }
  } catch (e) {
    print(e);
  }
  threads.remove('archive');
} */

Future<void> updateUserId(String userId) async {
  try {
    // print('> $userId');
    if (refreshCount < 6) {
      if (userId == 'archive') {
        print('Skip archive');
        await Future.delayed(Duration(milliseconds: 500));
        threads.remove(userId);
        return;
      }
    }

    final existing = await lookupRegistry(
        ['index', 'archive'].contains(userId)
            ? publicUser
            : User.fromId(userId),
        userId == 'archive' ? archiveFileID : fileID);
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

    print('Downloading updated JSON... $userId');

    // download the data in that Skylink
    final res = await http.get(Uri.https(SkynetConfig.host, '$skylink'));

    final metadata = json.decode(res.headers['skynet-file-metadata']);

    final file = SkyFile(
        content: res.bodyBytes,
        filename: metadata['filename'],
        type: res.headers['content-type']);

    final data = json.decode(file.asString);
    if (userId == 'archive') {
      final aMap = (data as Map).cast<String, int>();

      for (final key in aMap.keys) {
        if (!archive.containsKey(key)) {
          archive[key] = aMap[key];

          if (!index.containsKey(key)) {
            updateUserId(key);
          }
        }
      }
      userSkylinkCache[userId] = skylink;
      cleaningFlow();
    } else if (userId == 'index') {
      index = data.cast<String, int>();
/* 
      bool update = false;
      bool updateArchive = false; */

      if (!index.containsKey(user.id)) {
        index[user.id] = DateTime.now().millisecondsSinceEpoch;
        /*  update = true; */

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
/*       final now = DateTime.now().millisecondsSinceEpoch;

      final list = List.from(index.keys);

      if (refreshCount > 30) {
        for (final key in list) {
          int diff = now - index[key];

          if (diff > ((600 + Random().nextInt(600)) * 1000)) {
            print('Found old user!');

            final lastMessage = messages.firstWhere(
                (element) => element.userId == key,
                orElse: () => null);

            if (lastMessage != null) {
              if (now - lastMessage.sendAt.millisecondsSinceEpoch <
                  1000 * 60 * 10) {
                print('Last message: In time!');
                index[key] = lastMessage.sendAt.millisecondsSinceEpoch;
                continue;
              }
            }
            print('Removing $key from index...');
            index.remove(key);
            archive[key] = now;

            update = true;
            updateArchive = true;
          }
        }
      } */

/*       if (updateArchive) {
        final res = await setFile(
            publicUser,
            archiveFileID,
            SkyFile(
              content: utf8.encode(
                json.encode(archive),
              ),
              filename: archiveFileID.filename,
              type: 'application/json',
            ));
        print(res);
      } */

      userSkylinkCache[userId] = skylink;

      setState();
      cleaningFlow();
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
  } catch (e, st) {
    print('! $userId');
    print(e);
    print(st);
  }
  threads.remove(userId);
}

bool cleaningFlowRunning = false;

Future<void> cleaningFlow() async {
  if (cleaningFlowRunning) return;
  cleaningFlowRunning = true;
  try {
    print('Cleaning flow!');

    bool update = false;
    bool updateArchive = false;

    final now = DateTime.now().millisecondsSinceEpoch;

    final list = List.from(index.keys);

    if (refreshCount > 5) {
      for (final key in list) {
        if (key == user.id) continue;

        int diff = now - index[key];

        if (diff > ((600 + Random().nextInt(600)) * 1000)) {
          print('Found old user!');

          final lastMessage = messages.firstWhere(
              (element) => element.userId == key,
              orElse: () => null);

          if (lastMessage != null) {
            if (now - lastMessage.sendAt.millisecondsSinceEpoch <
                1000 * 60 * 10) {
              print('Last message: In time!');
              index[key] = lastMessage.sendAt.millisecondsSinceEpoch;
              continue;
            }
          }
          print('Removing $key from index...');
          index.remove(key);
          archive[key] = now;

          update = true;
          updateArchive = true;
        }
      }
    }

    if (updateArchive) {
      print('Cleaning flow updateArchive');
      final res = await setFile(
          publicUser,
          archiveFileID,
          SkyFile(
            content: utf8.encode(
              json.encode(archive),
            ),
            filename: archiveFileID.filename,
            type: 'application/json',
          ));
      print(res);
    }

    if (update) {
      print('Cleaning flow update');
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
  } catch (e, st) {
    print(e);
    print(st);
  }
  print('Cleaning flow done.');
  cleaningFlowRunning = false;
}

Set<String> threads = {};

Map<String, int> failCount = {};

Map<String, String> userSkylinkCache = {};

Map<String, int> index = {};

Map<String, int> archive = {};

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
