import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(
    ChangeNotifierProvider(create: (_) => AppState(), child: const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) => MaterialApp(
        title: 'Akbot Car',
        debugShowCheckedModeBanner: false,
        themeMode: appState.themeMode,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: const PermissionScreen(),
      ),
    );
  }
}

// PERMISSION SCREEN — FIXES FIRST LAUNCH
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});
  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (statuses.values.every((s) => s.isGranted)) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Allow all permissions to continue'),
          action: SnackBarAction(
            label: 'OPEN SETTINGS',
            onPressed: openAppSettings,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text('Setting up Bluetooth...'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _requestPermissions,
              child: const Text('RETRY'),
            ),
          ],
        ),
      ),
    );
  }
}

class AppState with ChangeNotifier {
  ThemeMode _theme = ThemeMode.light;
  String? _selectedMac;
  bool _isConnected = false;

  final Map<String, String> press = {
    'f': 'f',
    'b': 'b',
    'l': 'l',
    'r': 'r',
    '1': '1',
    '2': '2',
    '3': '3',
    '4': '4',
  };
  final Map<String, String> release = {
    'f': 's',
    'b': 's',
    'l': 's',
    'r': 's',
    '1': 's',
    '2': 's',
    '3': 's',
    '4': 's',
  };

  ThemeMode get themeMode => _theme;
  String? get selectedMac => _selectedMac;
  bool get isConnected => _isConnected;

  AppState() {
    _load();
  }

  void setConnected(bool value) {
    _isConnected = value;
    notifyListeners();
  }

  void setDevice(String mac) {
    _selectedMac = mac;
    _save();
    notifyListeners();
  }

  void disconnect() {
    _selectedMac = null;
    _isConnected = false;
    _save();
    notifyListeners();
  }

  void toggleTheme() {
    _theme = _theme == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    _save();
    notifyListeners();
  }

  void setChar(String k, String p, String r) {
    press[k] = p;
    release[k] = r;
    _save();
    notifyListeners();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _theme = ThemeMode.values[p.getInt('theme') ?? 0];
    _selectedMac = p.getString('car_mac');
    press.forEach((k, _) => press[k] = p.getString('p_$k') ?? press[k]!);
    release.forEach((k, _) => release[k] = p.getString('r_$k') ?? release[k]!);
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    p.setInt('theme', _theme.index);
    if (_selectedMac != null) p.setString('car_mac', _selectedMac!);
    press.forEach((k, v) => p.setString('p_$k', v));
    release.forEach((k, v) => p.setString('r_$k', v));
  }
}

class HomePage extends StatefulWidget {
  // FIXED: THESE 3 LINES WERE MISSING!
  static BluetoothConnection? connection;
  static Timer? heartbeat;
  static Timer? reconnectTimer;

  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final bt = FlutterBluetoothSerial.instance;
  List<BluetoothDevice> devices = [];
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    HomePage.heartbeat?.cancel();
    HomePage.reconnectTimer?.cancel();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    await bt.requestEnable();
    await _loadBonded();
    final app = Provider.of<AppState>(context, listen: false);
    if (app.selectedMac != null) {
      _connect(app.selectedMac!);
    }
  }

  Future<void> _loadBonded() async {
    try {
      final bonded = await bt.getBondedDevices();
      setState(() => devices = bonded.toList());
    } catch (e) {
      // Silent
    }
  }

  void _startHeartbeat() {
    HomePage.heartbeat?.cancel();
    HomePage.heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
      if (HomePage.connection?.isConnected ?? false) {
        try {
          HomePage.connection!.output.add(Uint8List.fromList(utf8.encode('k')));
        } catch (_) {}
      }
    });
  }

  void _connect(String address) async {
    try {
      HomePage.connection?.close();
      HomePage.connection = await BluetoothConnection.toAddress(
        address,
      ).timeout(const Duration(seconds: 10));

      Provider.of<AppState>(context, listen: false).setDevice(address);
      Provider.of<AppState>(context, listen: false).setConnected(true);
      _startHeartbeat();

      _connSub?.cancel();
      _connSub = HomePage.connection!.input!.listen(
        (_) {},
        onDone: _onDisconnect,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('CONNECTED!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      Provider.of<AppState>(context, listen: false).setConnected(false);
      _startAutoReconnect(address);
    }
    setState(() {});
  }

  void _onDisconnect() {
    HomePage.connection = null;
    HomePage.heartbeat?.cancel();
    Provider.of<AppState>(context, listen: false).setConnected(false);
    final mac = Provider.of<AppState>(context, listen: false).selectedMac;
    if (mac != null) _startAutoReconnect(mac);
    setState(() {});
  }

  void _startAutoReconnect(String address) {
    HomePage.reconnectTimer?.cancel();
    HomePage.reconnectTimer = Timer.periodic(const Duration(seconds: 3), (
      timer,
    ) {
      if (!(HomePage.connection?.isConnected ?? false)) {
        _connect(address);
      } else {
        timer.cancel();
      }
    });
  }

  void _send(String data) {
    if (HomePage.connection?.isConnected ?? false) {
      try {
        HomePage.connection!.output.add(Uint8List.fromList(utf8.encode(data)));
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Akbot Car',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showSettings(app),
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.33,
              child: GridView.count(
                crossAxisCount: 2,
                padding: const EdgeInsets.all(14),
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.3,
                children: ['1', '2', '3', '4']
                    .map(
                      (k) => CtrlBtn(
                        label: k,
                        press: app.press[k]!,
                        release: app.release[k]!,
                        onSend: _send,
                      ),
                    )
                    .toList(),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    BigArrow(
                      icon: Icons.arrow_upward,
                      press: app.press['f']!,
                      release: app.release['f']!,
                      onSend: _send,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        BigArrow(
                          icon: Icons.arrow_back,
                          press: app.press['l']!,
                          release: app.release['l']!,
                          onSend: _send,
                        ),
                        const SizedBox(width: 50),
                        BigArrow(
                          icon: Icons.arrow_forward,
                          press: app.press['r']!,
                          release: app.press['r']!,
                          onSend: _send,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    BigArrow(
                      icon: Icons.arrow_downward,
                      press: app.press['b']!,
                      release: app.release['b']!,
                      onSend: _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings(AppState app) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'SELECT YOUR CAR',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Devices'),
              onPressed: () async {
                setState(() => devices.clear());
                await _loadBonded();
              },
            ),
            const SizedBox(height: 20),
            ...devices.map(
              (d) => Card(
                color: app.selectedMac == d.address && app.isConnected
                    ? Colors.green[50]
                    : null,
                child: ListTile(
                  leading: Icon(
                    app.selectedMac == d.address && app.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                    color: app.selectedMac == d.address && app.isConnected
                        ? Colors.green
                        : null,
                  ),
                  title: Text(d.name ?? 'Unknown'),
                  subtitle: Text(d.address),
                  trailing: app.selectedMac == d.address && app.isConnected
                      ? const Chip(
                          label: Text('LIVE'),
                          backgroundColor: Colors.green,
                        )
                      : OutlinedButton(
                          child: const Text('CONNECT'),
                          onPressed: () => _connect(d.address),
                        ),
                ),
              ),
            ),
            const Divider(height: 40),
            ...['f', 'b', 'l', 'r', '1', '2', '3', '4'].map(
              (k) => ListTile(
                title: Text('Button $k'),
                subtitle: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(labelText: 'Press'),
                        controller: TextEditingController(text: app.press[k]),
                        onChanged: (v) => app.setChar(
                          k,
                          v.isEmpty ? ' ' : v,
                          app.release[k]!,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(labelText: 'Release'),
                        controller: TextEditingController(text: app.release[k]),
                        onChanged: (v) =>
                            app.setChar(k, app.press[k]!, v.isEmpty ? ' ' : v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Dark Mode'),
              value: app.themeMode == ThemeMode.dark,
              onChanged: (_) => app.toggleTheme(),
            ),
          ],
        ),
      ),
    );
  }
}

class CtrlBtn extends StatelessWidget {
  final String label;
  final String press, release;
  final Function(String) onSend;
  const CtrlBtn({
    super.key,
    required this.label,
    required this.press,
    required this.release,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onSend(press),
      onTapUp: (_) => onSend(release),
      onTapCancel: () => onSend(release),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.blueAccent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class BigArrow extends StatelessWidget {
  final IconData icon;
  final String press, release;
  final Function(String) onSend;
  const BigArrow({
    super.key,
    required this.icon,
    required this.press,
    required this.release,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onSend(press),
      onTapUp: (_) => onSend(release),
      onTapCancel: () => onSend(release),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.blue[700],
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
        ),
        child: Icon(icon, size: 36, color: Colors.white),
      ),
    );
  }
}
