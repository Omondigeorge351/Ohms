import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class NotificationService {
  static final _messaging = FirebaseMessaging.instance;
  static final _local = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(const InitializationSettings(android: android));
    FirebaseMessaging.onMessage.listen((RemoteMessage m) {
      if (m.notification != null) {
        _local.show(m.notification.hashCode, m.notification!.title, m.notification!.body,
          const NotificationDetails(android: AndroidNotificationDetails('ohms_channel', 'OHMS Chats', importance: Importance.max)));
      }
    });
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    String? token = await _messaging.getToken();
    var user = FirebaseAuth.instance.currentUser;
    if (user != null && token != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({'fcmToken': token}, SetOptions(merge: true));
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await NotificationService.init();
  runApp(OHMSApp());
}

class OHMSApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'OHMS', debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.deepPurple, useMaterial3: true),
      home: AuthGate());
  }
}

class AuthGate extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder(stream: FirebaseAuth.instance.authStateChanges(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return Scaffold(body: Center(child: CircularProgressIndicator()));
        if (snap.hasData) {
          return FutureBuilder(
            future: FirebaseFirestore.instance.collection('users').doc(snap.data!.uid).get(),
            builder: (ctx, userSnap) {
              if (!userSnap.hasData) return Scaffold(body: Center(child: CircularProgressIndicator()));
              if (!userSnap.data!.exists || userSnap.data!.data()!['name'] == null) return ProfileSetupScreen();
              return ChatListScreen();
            },
          );
        }
        return PhoneLoginScreen();
      });
  }
}

class PhoneLoginScreen extends StatefulWidget {
  @override
  _PhoneLoginScreenState createState() => _PhoneLoginScreenState();
}
class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final phoneController = TextEditingController();
  bool loading = false;
  void login() async {
    setState(() => loading = true);
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phoneController.text.trim(),
      verificationCompleted: (cred) async => await FirebaseAuth.instance.signInWithCredential(cred),
      verificationFailed: (e) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message!))); },
      codeSent: (verId, _) { setState(() => loading = false); Navigator.push(context, MaterialPageRoute(builder: (_) => OTPScreen(verificationId: verId))); },
      codeAutoRetrievalTimeout: (verId) {},
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Padding(padding: EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text("OHMS", style: TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
        SizedBox(height: 30),
        TextField(controller: phoneController, keyboardType: TextInputType.phone, decoration: InputDecoration(hintText: "+254712345678", labelText: "Phone Number", border: OutlineInputBorder(), prefixIcon: Icon(Icons.phone))),
        SizedBox(height: 20),
        loading ? CircularProgressIndicator() : SizedBox(width: double.infinity, child: ElevatedButton(onPressed: login, child: Text("Get OTP"))),
      ])));
  }
}

class OTPScreen extends StatefulWidget {
  final String verificationId;
  OTPScreen({required this.verificationId});
  @override
  _OTPScreenState createState() => _OTPScreenState();
}
class _OTPScreenState extends State<OTPScreen> {
  final otpController = TextEditingController();
  void verify() async {
    try {
      var cred = PhoneAuthProvider.credential(verificationId: widget.verificationId, smsCode: otpController.text.trim());
      await FirebaseAuth.instance.signInWithCredential(cred);
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => ProfileSetupScreen()), (r) => false);
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Wrong OTP"))); }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text("Enter OTP")), body: Padding(padding: EdgeInsets.all(24),
      child: Column(children: [
        TextField(controller: otpController, decoration: InputDecoration(labelText: "6-digit OTP", border: OutlineInputBorder())),
        SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(onPressed: verify, child: Text("Verify"))),
      ])));
  }
}

class ProfileSetupScreen extends StatefulWidget {
  @override
  _ProfileSetupScreenState createState() => _ProfileSetupScreenState();
}
class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final nameController = TextEditingController();
  File? imageFile;
  bool saving = false;
  final picker = ImagePicker();
  Future<void> pickImage() async { var p = await picker.pickImage(source: ImageSource.gallery); if (p != null) setState(() => imageFile = File(p.path)); }
  Future<void> saveProfile() async {
    if (nameController.text.trim().isEmpty) return;
    setState(() => saving = true);
    var user = FirebaseAuth.instance.currentUser!;
    String? photoUrl;
    if (imageFile != null) {
      var ref = FirebaseStorage.instance.ref().child('profile_pics/${user.uid}.jpg');
      await ref.putFile(imageFile!);
      photoUrl = await ref.getDownloadURL();
    }
    String? token = await FirebaseMessaging.instance.getToken();
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'phone': user.phoneNumber, 'name': nameController.text.trim(), 'photoUrl': photoUrl, 'fcmToken': token, 'createdAt': FieldValue.serverTimestamp()
    }, SetOptions(merge: true));
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => ChatListScreen()), (r) => false);
    setState(() => saving = false);
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text("Setup Profile")), body: Padding(padding: EdgeInsets.all(24),
      child: Column(children: [
        GestureDetector(onTap: pickImage, child: CircleAvatar(radius: 50, backgroundImage: imageFile != null ? FileImage(imageFile!) : null, child: imageFile == null ? Icon(Icons.camera_alt, size: 40) : null)),
        SizedBox(height: 30),
        TextField(controller: nameController, decoration: InputDecoration(labelText: "Your Name", border: OutlineInputBorder())),
        SizedBox(height: 20),
        saving ? CircularProgressIndicator() : SizedBox(width: double.infinity, child: ElevatedButton(onPressed: saveProfile, child: Text("Save & Enter OHMS"))),
      ])));
  }
}

class ChatListScreen extends StatefulWidget {
  @override
  _ChatListScreenState createState() => _ChatListScreenState();
}
class _ChatListScreenState extends State<ChatListScreen> {
  List<Contact> phoneContacts = [];
  bool loading = true;
  @override
  void initState() { super.initState(); loadContacts(); }
  Future<void> loadContacts() async {
    await Permission.contacts.request();
    if (await FlutterContacts.requestPermission()) {
      phoneContacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: true);
    }
    setState(() => loading = false);
  }
  Future<void> startChat(Contact contact) async {
    String myId = FirebaseAuth.instance.currentUser!.uid;
    String phone = contact.phones.isNotEmpty ? contact.phones.first.number : "";
    String cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    var userQuery = await FirebaseFirestore.instance.collection('users').where('phone', isGreaterThanOrEqualTo: cleanPhone.substring(cleanPhone.length - 9)).get();
    if (userQuery.docs.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${contact.displayName} not on OHMS yet"))); return; }
    var otherUser = userQuery.docs.first;
    String otherId = otherUser.id;
    String chatId = myId.hashCode <= otherId.hashCode ? '${myId}_$otherId' : '${otherId}_$myId';
    var chatDoc = await FirebaseFirestore.instance.collection('chats').doc(chatId).get();
    if (!chatDoc.exists) {
      await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
        'name': contact.displayName, 'participants': [myId, otherId], 'lastMessage': 'Started chat', 'createdAt': FieldValue.serverTimestamp()
      });
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, name: contact.displayName)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("OHMS"), actions: [IconButton(icon: Icon(Icons.logout), onPressed: () => FirebaseAuth.instance.signOut())]),
      body: loading ? Center(child: CircularProgressIndicator()) :
      StreamBuilder(stream: FirebaseFirestore.instance.collection('chats').where('participants', arrayContains: FirebaseAuth.instance.currentUser!.uid).snapshots(),
        builder: (ctx, AsyncSnapshot chatSnap) {
          return ListView.builder(itemCount: phoneContacts.length, itemBuilder: (ctx, i) {
            var c = phoneContacts[i];
            if (c.phones.isEmpty) return SizedBox();
            return ListTile(
              leading: CircleAvatar(child: Text(c.displayName[0])),
              title: Text(c.displayName),
              subtitle: Text(c.phones.first.number),
              trailing: Icon(Icons.chat_bubble),
              onTap: () => startChat(c),
            );
          });
        }),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String chatId, name;
  ChatScreen({required this.chatId, required this.name});
  @override
  _ChatScreenState createState() => _ChatScreenState();
}
class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _auth = FirebaseAuth.instance;
  void send() {
    if (_controller.text.trim().isEmpty) return;
    FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').add({
      'text': _controller.text, 'senderId': _auth.currentUser!.uid, 'time': FieldValue.serverTimestamp()
    });
    FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({'lastMessage': _controller.text});
    _controller.clear();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(widget.name)),
      body: Column(children: [
        Expanded(child: StreamBuilder(stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').orderBy('time').snapshots(),
          builder: (ctx, AsyncSnapshot snap) {
            if (!snap.hasData) return Center(child: CircularProgressIndicator());
            var msgs = snap.data.docs;
            return ListView.builder(itemCount: msgs.length, itemBuilder: (ctx, i) {
              bool isMe = msgs[i]['senderId'] == _auth.currentUser!.uid;
              return Align(alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(margin: EdgeInsets.all(6), padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(color: isMe ? Colors.deepPurple[200] : Colors.grey[300], borderRadius: BorderRadius.circular(12)),
                  child: Text(msgs[i]['text'])));
            });
          })),
        Row(children: [Expanded(child: Padding(padding: EdgeInsets.all(8), child: TextField(controller: _controller, decoration: InputDecoration(hintText: "Type in OHMS...")))), IconButton(icon: Icon(Icons.send), onPressed: send)])
      ]));
  }
}