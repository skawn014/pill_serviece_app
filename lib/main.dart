import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  Future.delayed(const Duration(seconds: 10), () async {
    await schedulePillNotification(
      999,
      '게보린정',
      DateTime.now().hour,
      DateTime.now().minute + 1,
    );
  });
  runApp(const MedicationApp());
}

// ──────────────────────────────────────────
// 전역 글씨 크기 설정
// ──────────────────────────────────────────
final fontSizeNotifier = ValueNotifier<double>(1.0); // 0.85 / 1.0 / 1.15

// 전역 약 목록 (온보딩에서 등록한 약이 메인화면에 반영됨)
final globalMedications = ValueNotifier<List<Medication>>([
  Medication(name: "게보린", mealTiming: "식후", mealTime: "아침", dose: 1, time: "08:30"),
  Medication(name: "캐롤에프", mealTiming: "식후", mealTime: "점심", dose: 1, time: "13:00"),
  Medication(name: "알러지약", mealTiming: "식전", mealTime: "저녁", dose: 1, time: "18:30"),
]);

// ──────────────────────────────────────────
// 앱 루트
// ──────────────────────────────────────────
class MedicationApp extends StatelessWidget {
  const MedicationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: fontSizeNotifier,
      builder: (context, scale, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: '알약 매니저',
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('ko', 'KR')],
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
            useMaterial3: true,
            textTheme: TextTheme(
              bodyLarge: TextStyle(fontSize: 16 * scale),
              bodyMedium: TextStyle(fontSize: 14 * scale),
              bodySmall: TextStyle(fontSize: 12 * scale),
            ),
          ),
          home: const LoginScreen(),
        );
      },
    );
  }
}

// ──────────────────────────────────────────
// 모델
// ──────────────────────────────────────────
class Medication {
  final String name;
  final String mealTiming;
  final String mealTime;
  final int dose;
  final String time;
  final bool isTaken;

  Medication({
    required this.name,
    required this.mealTiming,
    required this.mealTime,
    required this.dose,
    required this.time,
    this.isTaken = false,
  });

  Medication copyWith({
    String? name,
    String? mealTiming,
    String? mealTime,
    int? dose,
    String? time,
    bool? isTaken,
  }) =>
      Medication(
        name: name ?? this.name,
        mealTiming: mealTiming ?? this.mealTiming,
        mealTime: mealTime ?? this.mealTime,
        dose: dose ?? this.dose,
        time: time ?? this.time,
        isTaken: isTaken ?? this.isTaken,
      );
}

// ──────────────────────────────────────────
// 서버 IP 설정
// ──────────────────────────────────────────
const String _baseUrl = 'http://192.168.0.25:5000';

// ──────────────────────────────────────────
// 로컬 알림 서비스
// ──────────────────────────────────────────
final FlutterLocalNotificationsPlugin _notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Seoul'));
  const AndroidInitializationSettings android =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notificationsPlugin.initialize(
    const InitializationSettings(android: android),
  );
  await _notificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> schedulePillNotification(int id, String pillName, int hour, int minute) async {
  final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
  tz.TZDateTime scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
  if (scheduled.isBefore(now)) scheduled = scheduled.add(const Duration(days: 1));

  await _notificationsPlugin.zonedSchedule(
    id,
    '💊 복약 알림',
    '$pillName 을(를) 복용할 시간입니다!',
    scheduled,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'pill_channel', '복약 알림',
        importance: Importance.max,
        priority: Priority.high,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

Future<void> cancelAllNotifications() async {
  await _notificationsPlugin.cancelAll();
}

void scheduleAllNotifications(List<Medication> meds) async {
  await cancelAllNotifications();
  for (int i = 0; i < meds.length; i++) {
    final parts = meds[i].time.split(':');
    if (parts.length == 2) {
      final hour = int.tryParse(parts[0]) ?? 0;
      final minute = int.tryParse(parts[1]) ?? 0;
      await schedulePillNotification(i, meds[i].name, hour, minute);
    }
  }
}

// ──────────────────────────────────────────
// AI 인식 서비스 (실제 백엔드 연동)
// ──────────────────────────────────────────
class PillRecognitionService {
  static Future<PillRecognitionResult> recognize(String pillName) async {
    final picker = ImagePicker();
    final XFile? photo = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1280,
    );
    if (photo == null) return PillRecognitionResult(name: null, confidence: 0.0);

    final uri = Uri.parse('$_baseUrl/verify_pill');
    final request = http.MultipartRequest('POST', uri);
    request.fields['pill_name'] = pillName;
    request.files.add(await http.MultipartFile.fromPath('image', photo.path));

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final body = await streamed.stream.bytesToString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (streamed.statusCode != 200) return PillRecognitionResult(name: null, confidence: 0.0);
      final bool match = json['match'] == true;
      final double conf = (json['confidence'] as num?)?.toDouble() ?? 0.0;
      final String? detected = json['detected_name'] as String?;
      return PillRecognitionResult(name: match ? pillName : detected, confidence: conf);
    } catch (e) {
      return PillRecognitionResult(name: null, confidence: 0.0);
    }
  }
}

class PillRecognitionResult {
  final String? name;
  final double confidence;
  PillRecognitionResult({required this.name, required this.confidence});
  bool get isSuccess => name != null && confidence >= 0.7;
}

// ──────────────────────────────────────────
// 로그인 화면
// ──────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isObscured = true;

  @override
  Widget build(BuildContext context) {
    final s = fontSizeNotifier.value;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.medication, size: 90, color: Colors.blueAccent),
              const SizedBox(height: 24),
              Text("알약 매니저",
                  style: TextStyle(fontSize: 28 * s, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("내 약을 안전하게 관리해요",
                  style: TextStyle(fontSize: 15 * s, color: Colors.grey)),
              const SizedBox(height: 50),
              TextField(
                style: TextStyle(fontSize: 17 * s),
                decoration: InputDecoration(
                  hintText: '아이디',
                  hintStyle: TextStyle(fontSize: 16 * s),
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.person_outline, size: 26),
                  contentPadding:
                  const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                obscureText: _isObscured,
                style: TextStyle(fontSize: 17 * s),
                decoration: InputDecoration(
                  hintText: '비밀번호',
                  hintStyle: TextStyle(fontSize: 16 * s),
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.lock_outline, size: 26),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _isObscured ? Icons.visibility_off : Icons.visibility,
                        color: Colors.grey, size: 24),
                    onPressed: () =>
                        setState(() => _isObscured = !_isObscured),
                  ),
                  contentPadding:
                  const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton(
                  onPressed: () => Navigator.pushReplacement(context,
                      MaterialPageRoute(builder: (_) => const HomeScreen())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text("로그인",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18 * s,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("아직 계정이 없으신가요?",
                      style: TextStyle(fontSize: 15 * s, color: Colors.black45)),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const SignUpScreen())),
                    child: Text("회원가입",
                        style: TextStyle(
                            fontSize: 15 * s,
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────
// 홈 (하단 네비게이션)
// ──────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final List<Widget> _pages = const [MyMedicationPage(), CheckPillPage()];

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.logout, color: Colors.redAccent, size: 52),
        title: const Text("로그아웃 할까요?",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        content: const Text("로그아웃하면 로그인 화면으로 돌아가요.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Colors.black54)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text("취소", style: TextStyle(fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
            ),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text("로그아웃",
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("알약 매니저",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            iconSize: 28,
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()));
              } else if (value == 'support') {
                Navigator.push(context,
                    MaterialPageRoute(
                        builder: (_) => const CustomerSupportScreen()));
              } else if (value == 'logout') {
                _showLogoutDialog();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  Icon(Icons.settings, color: Colors.black54, size: 22),
                  SizedBox(width: 12),
                  Text("환경 설정", style: TextStyle(fontSize: 16)),
                ]),
              ),
              const PopupMenuItem(
                value: 'support',
                child: Row(children: [
                  Icon(Icons.headset_mic_outlined,
                      color: Colors.blueAccent, size: 22),
                  SizedBox(width: 12),
                  Text("고객센터", style: TextStyle(fontSize: 16)),
                ]),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, color: Colors.redAccent, size: 22),
                  SizedBox(width: 12),
                  Text("로그아웃",
                      style:
                      TextStyle(color: Colors.redAccent, fontSize: 16)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        selectedFontSize: 14,
        unselectedFontSize: 13,
        iconSize: 28,
        selectedItemColor: Colors.blueAccent,
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        elevation: 12,
        items: const [
          BottomNavigationBarItem(
            icon: Padding(
                padding: EdgeInsets.only(bottom: 3),
                child: Icon(Icons.medication)),
            label: "내 약 관리",
          ),
          BottomNavigationBarItem(
            icon: Padding(
                padding: EdgeInsets.only(bottom: 3),
                child: Icon(Icons.camera_alt_outlined)),
            label: "약 확인하기",
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────
// 공통: 촬영 & 인식 다이얼로그 믹스인
// ──────────────────────────────────────────
mixin PillRecognitionMixin<T extends StatefulWidget> on State<T> {
  bool isRecognizing = false;

  Future<void> startRecognitionFor(String expectedName, VoidCallback onMatch) async {
    setState(() => isRecognizing = true);
    try {
      final result = await PillRecognitionService.recognize(expectedName);
      if (!mounted) return;
      setState(() => isRecognizing = false);

      if (!result.isSuccess) {
        showFailDialog(() => startRecognitionFor(expectedName, onMatch));
        return;
      }

      final isMatch = result.name!.trim().toLowerCase() ==
          expectedName.trim().toLowerCase();

      if (isMatch) {
        showMatchDialog(expectedName, result.confidence, onMatch);
      } else {
        showMismatchDialog(
            expectedName, () => startRecognitionFor(expectedName, onMatch));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => isRecognizing = false);
      showFailDialog(() => startRecognitionFor(expectedName, onMatch));
    }
  }

  void showMatchDialog(String name, double confidence, VoidCallback onConfirm) {
    final pct = (confidence * 100).toStringAsFixed(0);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(Icons.verified, color: Colors.green, size: 56),
        title: const Text("약이 일치해요!",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 21)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle,
                          color: Colors.green, size: 16),
                      const SizedBox(width: 6),
                      Text("일치율 $pct%",
                          style: TextStyle(
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text("입력한 약 이름과 촬영한 약이 일치해요!",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.5)),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("닫기", style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onConfirm();
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("복약 완료",
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  void showMismatchDialog(String name, VoidCallback onRetry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.redAccent, size: 56),
        title: const Text("이 약이 아닌 것 같아요",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 21)),
        content: Text("'$name'과(와) 촬영한 약이 달라요.\n약을 다시 확인해주세요!",
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.7, fontSize: 15)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("닫기", style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onRetry();
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("다시 촬영",
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  void showFailDialog(VoidCallback onRetry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(Icons.camera_alt_outlined,
            color: Colors.orangeAccent, size: 56),
        title: const Text("인식하지 못했어요",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 21)),
        content: const Text("밝은 곳에서 약을 평평하게 놓고\n다시 촬영해보세요.",
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.6, fontSize: 15)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("닫기", style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onRetry();
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text("다시 촬영",
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget buildRecognizingOverlay() {
    if (!isRecognizing) return const SizedBox.shrink();
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text("약을 확인하는 중이에요...",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text("잠깐만 기다려주세요",
                style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────
// 탭 1: 내 약 관리
// ──────────────────────────────────────────
class MyMedicationPage extends StatefulWidget {
  const MyMedicationPage({super.key});
  @override
  State<MyMedicationPage> createState() => _MyMedicationPageState();
}

class _MyMedicationPageState extends State<MyMedicationPage>
    with PillRecognitionMixin {
  List<Medication> get _medications => globalMedications.value;

  int get _takenCount => _medications.where((m) => m.isTaken).length;
  bool get _allTaken =>
      _medications.isNotEmpty && _takenCount == _medications.length;

  List<Medication> _byMealTime(String mealTime) =>
      _medications.where((m) => m.mealTime == mealTime).toList();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildProgressCard(),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("오늘의 복약 목록",
                      style: TextStyle(
                          fontSize: 19, fontWeight: FontWeight.bold)),
                  TextButton.icon(
                    onPressed: _goToAddScreen,
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text("약 추가", style: TextStyle(fontSize: 15)),
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.blueAccent),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text("카드를 탭 → 촬영 확인 / 길게 누르면 수정·삭제",
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              if (_medications.isEmpty)
                _buildEmptyState()
              else ...[
                _buildSection("아침", Colors.orangeAccent, Icons.wb_sunny_outlined),
                _buildSection("점심", Colors.blueAccent, Icons.wb_cloudy_outlined),
                _buildSection("저녁", Colors.purpleAccent, Icons.nightlight_outlined),
              ],
              const SizedBox(height: 30),
            ],
          ),
        ),
        buildRecognizingOverlay(),
      ],
    );
  }

  // ── 아침 / 점심 / 저녁 섹션 ──
  Widget _buildSection(String mealTime, Color color, IconData icon) {
    final meds = _byMealTime(mealTime);
    if (meds.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10, top: 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color, size: 15),
              ),
              const SizedBox(width: 8),
              Text(mealTime,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
        ...meds.map((med) {
          final index = _medications.indexOf(med);
          return _buildMedicationCard(med, index, color);
        }),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildProgressCard() {
    final total = _medications.length;
    final taken = _takenCount;
    final progress = total == 0 ? 0.0 : taken / total;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _allTaken
              ? [Colors.green.shade400, Colors.green.shade600]
              : [Colors.blueAccent, Colors.blue.shade700],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: (_allTaken ? Colors.green : Colors.blueAccent)
                .withValues(alpha: 0.3),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_allTaken ? "오늘 복약 완료!" : "오늘의 복약 현황",
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              Text("$taken / $total",
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.3),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            total == 0
                ? "등록된 약이 없어요"
                : _allTaken
                ? "모든 약을 챙겨드셨어요! 건강하세요"
                : "아직 ${total - taken}개를 복용하지 않았어요",
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildMedicationCard(Medication med, int index, Color sectionColor) {
    return GestureDetector(
      // 탭: 촬영 확인
      onTap: () {
        if (med.isTaken) {
          _showAlreadyTakenDialog(med, index);
        } else {
          startRecognitionFor(med.name, () {
            final updated = List<Medication>.from(_medications);
            updated[index] = med.copyWith(isTaken: true);
            setState(() => globalMedications.value = updated);
scheduleAllNotifications(updated);
            _checkAllTaken();
          });
        }
      },
      // 길게 누르기: 수정 / 삭제
      onLongPress: () => _showActionSheet(index),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: med.isTaken ? 0.5 : 1.0,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: sectionColor.withValues(alpha: 0.15),
                child: Icon(
                  med.isTaken ? Icons.check : Icons.medication,
                  color: med.isTaken ? Colors.green : sectionColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(med.name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          decoration:
                          med.isTaken ? TextDecoration.lineThrough : null,
                          color: med.isTaken ? Colors.grey : Colors.black,
                        )),
                    const SizedBox(height: 3),
                    Text(
                      "${med.mealTiming} · ${med.dose}정 · ${med.time}",
                      style: TextStyle(
                        fontSize: 13,
                        color: med.isTaken ? Colors.grey[400] : Colors.grey[600],
                        decoration:
                        med.isTaken ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (!med.isTaken)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.camera_alt_outlined,
                                size: 11, color: Colors.grey[400]),
                            const SizedBox(width: 3),
                            Text("탭해서 촬영 확인",
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey[400])),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // 수동 체크 버튼
              GestureDetector(
                onTap: () => _toggleTaken(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: med.isTaken ? Colors.green : Colors.grey[200],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check,
                      color: med.isTaken ? Colors.white : Colors.grey,
                      size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAlreadyTakenDialog(Medication med, int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text("이미 복용 완료한 약이에요",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: Text("'${med.name}'은(는) 오늘 이미 복용 완료했어요.\n다시 촬영하시겠어요?",
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text("취소", style: TextStyle(fontSize: 15)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              startRecognitionFor(med.name, () {
                final updated = List<Medication>.from(_medications);
                updated[index] = med.copyWith(isTaken: true);
                setState(() => globalMedications.value = updated);
scheduleAllNotifications(updated);
              });
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text("다시 촬영",
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  void _toggleTaken(int index) {
    final med = _medications[index];
    final updated = List<Medication>.from(_medications);
    updated[index] = med.copyWith(isTaken: !med.isTaken);
    setState(() => globalMedications.value = updated);
scheduleAllNotifications(updated);
    _checkAllTaken();
  }

  void _checkAllTaken() {
    if (_allTaken) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("오늘 복약을 모두 완료했어요!",
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(Icons.medication_outlined, size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            const Text("등록된 약이 없어요.\n오른쪽 위 '약 추가' 버튼을 눌러보세요!",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  void _showActionSheet(int index) {
    final med = _medications[index];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(med.name,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.black54)),
            const SizedBox(height: 20),
            _sheetButton(
              icon: Icons.edit,
              iconColor: Colors.blueAccent,
              bgColor: const Color(0xFFE3F0FF),
              label: "수정하기",
              sub: "약 정보를 변경해요",
              onTap: () async {
                Navigator.pop(context);
                final updated = await Navigator.push<Medication>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => AddMedicationScreen(existing: med)),
                );
                if (updated != null) {
                  final list = List<Medication>.from(_medications);
                  list[index] = updated;
                  setState(() => globalMedications.value = list);
                }
              },
            ),
            const SizedBox(height: 12),
            _sheetButton(
              icon: Icons.delete_outline,
              iconColor: Colors.redAccent,
              bgColor: const Color(0xFFFFEBEE),
              label: "삭제하기",
              sub: "목록에서 제거해요",
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirm(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetButton({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String label,
    required String sub,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            CircleAvatar(
                backgroundColor: bgColor,
                radius: 22,
                child: Icon(icon, color: iconColor, size: 22)),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                Text(sub,
                    style:
                    const TextStyle(fontSize: 13, color: Colors.black45)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirm(int index) {
    final med = _medications[index];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("약을 삭제할까요?",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Text("'${med.name}'을(를) 목록에서 삭제해요.",
            style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소",
                style: TextStyle(color: Colors.grey, fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final updated = List<Medication>.from(_medications);
              updated.removeAt(index);
              setState(() => globalMedications.value = updated);
scheduleAllNotifications(updated);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text("삭제",
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  void _goToAddScreen() async {
    final newMed = await Navigator.push<Medication>(
      context,
      MaterialPageRoute(builder: (_) => const AddMedicationScreen()),
    );
    if (newMed != null) {
      final updated = List<Medication>.from(_medications)..add(newMed);
      setState(() => globalMedications.value = updated);
scheduleAllNotifications(updated);
    }
  }
}

// ──────────────────────────────────────────
// 탭 2: 약 확인하기
// ──────────────────────────────────────────
class CheckPillPage extends StatefulWidget {
  const CheckPillPage({super.key});
  @override
  State<CheckPillPage> createState() => _CheckPillPageState();
}

class _CheckPillPageState extends State<CheckPillPage>
    with PillRecognitionMixin {
  final TextEditingController _nameController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Colors.blueAccent.withValues(alpha: 0.25)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: Colors.blueAccent, size: 22),
                        SizedBox(width: 8),
                        Text("이렇게 사용해요",
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.blueAccent)),
                      ],
                    ),
                    SizedBox(height: 12),
                    _StepRow(number: "1", text: "먹으려는 약 이름을 아래에 입력해요"),
                    SizedBox(height: 8),
                    _StepRow(number: "2", text: "카메라 버튼을 눌러 약을 촬영해요"),
                    SizedBox(height: 8),
                    _StepRow(number: "3", text: "입력한 약과 일치하는지 확인해줘요"),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              const Text("약 이름 입력",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                style: const TextStyle(fontSize: 18),
                decoration: InputDecoration(
                  hintText: "예) 게보린, 타이레놀",
                  hintStyle: const TextStyle(fontSize: 16),
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  prefixIcon:
                  const Icon(Icons.medication_outlined, size: 26),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear, color: Colors.grey, size: 22),
                    onPressed: () => _nameController.clear(),
                  ),
                  contentPadding:
                  const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                height: 62,
                child: ElevatedButton.icon(
                  onPressed: isRecognizing
                      ? null
                      : () {
                    final name = _nameController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(
                        content: Text("약 이름을 먼저 입력해주세요!",
                            style: TextStyle(fontSize: 15)),
                        backgroundColor: Colors.orangeAccent,
                      ));
                      return;
                    }
                    startRecognitionFor(name, () {});
                  },
                  icon: const Icon(Icons.camera_alt, size: 26),
                  label: const Text("촬영해서 확인하기",
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[300],
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ),
        ),
        buildRecognizingOverlay(),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final String number;
  final String text;
  const _StepRow({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
              color: Colors.blueAccent, shape: BoxShape.circle),
          child: Center(
            child: Text(number,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
          ),
        ),
        const SizedBox(width: 10),
        Text(text, style: const TextStyle(fontSize: 14, color: Colors.black87)),
      ],
    );
  }
}

// ──────────────────────────────────────────
// 약 추가 / 수정 화면
// ──────────────────────────────────────────
class AddMedicationScreen extends StatefulWidget {
  final Medication? existing;
  const AddMedicationScreen({super.key, this.existing});
  @override
  State<AddMedicationScreen> createState() => _AddMedicationScreenState();
}

class _AddMedicationScreenState extends State<AddMedicationScreen> {
  late TextEditingController _nameController;
  late String _mealTime;
  late String _mealTiming;
  late int _dose;


  final Map<String, Color> _mealColors = {
    "아침": Colors.orangeAccent,
    "점심": Colors.blueAccent,
    "저녁": Colors.purpleAccent,
  };

  late TextEditingController _hourController;
  late TextEditingController _minuteController;
  bool _isAm = true;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _nameController = TextEditingController(text: ex?.name ?? '');
    _mealTime = ex?.mealTime ?? '아침';
    _mealTiming = ex?.mealTiming ?? '식후';
    _dose = ex?.dose ?? 1;
    if (ex != null) {
      final p = ex.time.split(':');
      final h = int.parse(p[0]);
      final m = int.parse(p[1]);
      _isAm = h < 12;
      final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
      _hourController = TextEditingController(text: h12.toString());
      _minuteController = TextEditingController(text: m.toString().padLeft(2, '0'));
    } else {
      _hourController = TextEditingController(text: '8');
      _minuteController = TextEditingController(text: '00');
      _isAm = true;
    }
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("약 이름을 입력해주세요!")));
      return;
    }

    // 시간 유효성 검사
    final hourText = _hourController.text.trim();
    final minuteText = _minuteController.text.trim();
    if (hourText.isEmpty || minuteText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("복용 시간을 입력해주세요!")));
      return;
    }
    final hour = int.tryParse(hourText);
    final minute = int.tryParse(minuteText);
    if (hour == null || hour < 1 || hour > 12) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("시간은 1~12 사이로 입력해주세요!")));
      return;
    }
    if (minute == null || minute < 0 || minute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("분은 0~59 사이로 입력해주세요!")));
      return;
    }

    // 24시간으로 변환
    int hour24 = hour;
    if (_isAm && hour == 12) hour24 = 0;
    if (!_isAm && hour != 12) hour24 = hour + 12;

    final timeStr =
        "${hour24.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}";
    Navigator.pop(
      context,
      Medication(
          name: name,
          mealTiming: _mealTiming,
          mealTime: _mealTime,
          dose: _dose,
          time: timeStr),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(isEdit ? "약 수정하기" : "약 추가하기",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label("약 이름"),
            TextField(
              controller: _nameController,
              style: const TextStyle(fontSize: 17),
              decoration: InputDecoration(
                hintText: '예) 타이레놀, 게보린',
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                contentPadding:
                const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
              ),
            ),
            const SizedBox(height: 26),
            _label("복용 시간대"),
            Row(
              children: ["아침", "점심", "저녁"].map((t) {
                final sel = _mealTime == t;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _mealTime = t),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: sel ? _mealColors[t] : Colors.grey[100],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(t,
                              style: TextStyle(
                                  color: sel ? Colors.white : Colors.black54,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 26),
            _label("식사 기준"),
            Row(
              children: ["식전", "식후"].map((t) {
                final sel = _mealTiming == t;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _mealTiming = t),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: sel ? Colors.blueAccent : Colors.grey[100],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(t,
                              style: TextStyle(
                                  color: sel ? Colors.white : Colors.black54,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 26),
            _label("복용량"),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () {
                    if (_dose > 1) setState(() => _dose--);
                  },
                  icon: const Icon(Icons.remove_circle_outline),
                  color: Colors.blueAccent,
                  iconSize: 38,
                ),
                const SizedBox(width: 12),
                Text("$_dose 정",
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: () => setState(() => _dose++),
                  icon: const Icon(Icons.add_circle_outline),
                  color: Colors.blueAccent,
                  iconSize: 38,
                ),
              ],
            ),
            const SizedBox(height: 26),
            _label("복용 시간"),
            // 오전/오후 선택
            Row(
              children: ["오전", "오후"].map((label) {
                final isAm = label == "오전";
                final selected = _isAm == isAm;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _isAm = isAm),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: selected ? Colors.blueAccent : Colors.grey[100],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(label,
                              style: TextStyle(
                                  color: selected ? Colors.white : Colors.black54,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            // 시 / 분 입력
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hourController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      hintText: "8",
                      labelText: "시 (1~12)",
                      labelStyle: const TextStyle(fontSize: 13),
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text(":",
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: TextField(
                    controller: _minuteController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      hintText: "00",
                      labelText: "분 (0~59)",
                      labelStyle: const TextStyle(fontSize: 13),
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 38),
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                  isEdit ? Colors.orangeAccent : Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(isEdit ? "수정 완료" : "저장하기",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text,
        style:
        const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
  );
}

// ──────────────────────────────────────────
// 환경설정
// ──────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isMedicationAlarmOn = true;
  bool _isSoundOn = true;
  bool _isVibrationOn = true;

  final List<_FontSizeOption> _fontOptions = [
    _FontSizeOption(label: "작게", scale: 0.85),
    _FontSizeOption(label: "보통", scale: 1.0),
    _FontSizeOption(label: "크게", scale: 1.15),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text("환경설정",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 글씨 크기 ──
            _sectionHeader("글씨 크기"),
            _settingsCard(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("앱 전체 글씨 크기를 조절해요",
                        style:
                        TextStyle(fontSize: 13, color: Colors.black45)),
                    const SizedBox(height: 14),
                    ValueListenableBuilder<double>(
                      valueListenable: fontSizeNotifier,
                      builder: (context, scale, _) => Row(
                        children: _fontOptions.map((opt) {
                          final isSelected = scale == opt.scale;
                          return Expanded(
                            child: Padding(
                              padding:
                              const EdgeInsets.symmetric(horizontal: 4),
                              child: GestureDetector(
                                onTap: () =>
                                fontSizeNotifier.value = opt.scale,
                                child: AnimatedContainer(
                                  duration:
                                  const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.blueAccent
                                        : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Center(
                                    child: Text(opt.label,
                                        style: TextStyle(
                                            color: isSelected
                                                ? Colors.white
                                                : Colors.black54,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15 * opt.scale)),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 22),

            // ── 알림 ──
            _sectionHeader("알림"),
            _settingsCard(children: [
              _switchTile(
                icon: Icons.alarm,
                iconColor: Colors.blueAccent,
                title: "복약 알림",
                subtitle: "설정한 복용 시간에 알림을 보내드려요",
                value: _isMedicationAlarmOn,
                onChanged: (v) => setState(() => _isMedicationAlarmOn = v),
              ),
              if (_isMedicationAlarmOn) ...[
                const Divider(height: 1, indent: 62),
                _switchTile(
                  icon: Icons.volume_up_outlined,
                  iconColor: Colors.orangeAccent,
                  title: "알림음",
                  subtitle: "알림 소리를 켜거나 꺼요",
                  value: _isSoundOn,
                  onChanged: (v) => setState(() => _isSoundOn = v),
                ),
                const Divider(height: 1, indent: 62),
                _switchTile(
                  icon: Icons.vibration,
                  iconColor: Colors.purpleAccent,
                  title: "진동",
                  subtitle: "알림 진동을 켜거나 꺼요",
                  value: _isVibrationOn,
                  onChanged: (v) => setState(() => _isVibrationOn = v),
                ),
              ],
            ]),
            const SizedBox(height: 22),

            // ── 정보 ──
            _sectionHeader("정보"),
            _settingsCard(children: [
              _arrowTile(
                icon: Icons.shield_outlined,
                iconColor: Colors.teal,
                title: "개인정보 처리방침",
                onTap: _showPrivacyPolicy,
              ),
              const Divider(height: 1, indent: 62),
              _arrowTile(
                icon: Icons.info_outline,
                iconColor: Colors.grey,
                title: "앱 버전",
                trailing: const Text("v1.0.0",
                    style: TextStyle(color: Colors.grey, fontSize: 14)),
                onTap: null,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: Text(title,
        style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black54)),
  );

  Widget _settingsCard({required List<Widget> children}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2)),
      ],
    ),
    child: Column(children: children),
  );

  Widget _switchTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            CircleAvatar(
                radius: 20,
                backgroundColor: iconColor.withValues(alpha: 0.12),
                child: Icon(icon, color: iconColor, size: 20)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  Text(subtitle,
                      style:
                      const TextStyle(fontSize: 12, color: Colors.black45)),
                ],
              ),
            ),
            Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: Colors.blueAccent),
          ],
        ),
      );

  Widget _arrowTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    Widget? trailing,
    required VoidCallback? onTap,
  }) =>
      ListTile(
        onTap: onTap,
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
            radius: 20,
            backgroundColor: iconColor.withValues(alpha: 0.12),
            child: Icon(icon, color: iconColor, size: 20)),
        title: Text(title,
            style:
            const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        trailing: trailing ??
            const Icon(Icons.chevron_right, color: Colors.black38, size: 24),
      );

  void _showPrivacyPolicy() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("개인정보 처리방침",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("수집 항목",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 6),
              Text("복약 정보, 기기 정보 (알림 목적)",
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 14),
              Text("수집 목적",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 6),
              Text("복약 알림 및 서비스 개선", style: TextStyle(fontSize: 14)),
              SizedBox(height: 14),
              Text("보유 기간",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 6),
              Text("회원 탈퇴 시 즉시 삭제", style: TextStyle(fontSize: 14)),
              SizedBox(height: 14),
              Text("제3자 제공",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 6),
              Text("외부 제공 없음", style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: const Text("확인",
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

class _FontSizeOption {
  final String label;
  final double scale;
  const _FontSizeOption({required this.label, required this.scale});
}

// ──────────────────────────────────────────
// 고객센터
// ──────────────────────────────────────────
class CustomerSupportScreen extends StatefulWidget {
  const CustomerSupportScreen({super.key});
  @override
  State<CustomerSupportScreen> createState() =>
      _CustomerSupportScreenState();
}

class _CustomerSupportScreenState extends State<CustomerSupportScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  String _selectedCategory = "앱 오류";
  bool _isSubmitted = false;

  final List<String> _categories = ["앱 오류", "약 인식 문제", "복약 알림", "계정 문의", "기타"];

  void _submit() {
    if (_titleController.text.trim().isEmpty ||
        _contentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("제목과 문의 내용을 모두 입력해주세요!")));
      return;
    }
    setState(() => _isSubmitted = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("고객센터",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isSubmitted ? _buildSuccessView() : _buildFormView(),
    );
  }

  Widget _buildFormView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.blueAccent.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.headset_mic_outlined,
                    color: Colors.blueAccent, size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("무엇이든 물어보세요!",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      SizedBox(height: 3),
                      Text("빠르게 답변드릴게요",
                          style: TextStyle(
                              fontSize: 13, color: Colors.black54)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          const Text("문의 유형",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _categories.map((cat) {
              final sel = _selectedCategory == cat;
              return GestureDetector(
                onTap: () => setState(() => _selectedCategory = cat),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? Colors.blueAccent : Colors.grey[100],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(cat,
                      style: TextStyle(
                          color: sel ? Colors.white : Colors.black54,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 22),
          const Text("제목",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: "문의 제목을 입력해주세요",
              filled: true,
              fillColor: Colors.grey[100],
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              contentPadding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
            ),
          ),
          const SizedBox(height: 20),
          const Text("문의 내용",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _contentController,
            maxLines: 6,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: "불편하신 점이나 궁금한 점을 적어주세요",
              filled: true,
              fillColor: Colors.grey[100],
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.all(14),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: const Text("문의 보내기",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                  color: Colors.green.shade50, shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 56),
            ),
            const SizedBox(height: 24),
            const Text("문의가 접수되었어요!",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text("빠른 시일 내에 답변드릴게요.\n이용해주셔서 감사해요",
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15, color: Colors.black54, height: 1.6)),
            const SizedBox(height: 36),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                child: const Text("홈으로 돌아가기",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────
// 회원가입 화면 → 온보딩으로 연결
// ──────────────────────────────────────────
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _idController        = TextEditingController();
  final _pwController        = TextEditingController();
  final _pwConfirmController = TextEditingController();
  bool _isObscured1 = true;
  bool _isObscured2 = true;
  bool _isIdChecked = false; // 중복 확인 여부

  // 아이디: 영문+숫자 조합 4~20자
  bool get _isIdValid =>
      RegExp(r'^(?=.*[a-zA-Z])(?=.*[0-9])[a-zA-Z0-9]{4,20}$')
          .hasMatch(_idController.text.trim());

  // 비밀번호: 영문+숫자 조합 8자리 이상
  bool get _isPwValid =>
      RegExp(r'^(?=.*[a-zA-Z])(?=.*[0-9])[a-zA-Z0-9]{8,}$')
          .hasMatch(_pwController.text);

  bool get _isPwMatch =>
      _pwController.text == _pwConfirmController.text &&
          _pwConfirmController.text.isNotEmpty;

  // ── 중복 확인 (Mock - 백엔드 연동 전)
  Future<void> _checkDuplicate() async {
    if (_idController.text.trim().isEmpty) {
      _snack("아이디를 먼저 입력해주세요!"); return;
    }
    if (!_isIdValid) {
      _snack("아이디 형식을 확인해주세요!"); return;
    }
    // TODO: 백엔드 연동 시 실제 중복 확인 API 호출
    // final response = await http.get(Uri.parse('서버URL/check-id?id=${_idController.text}'));
    // final isDuplicate = jsonDecode(response.body)['isDuplicate'];
    await Future.delayed(const Duration(milliseconds: 500)); // Mock 딜레이
    setState(() => _isIdChecked = true);
    _snack("사용 가능한 아이디예요! ✅");
  }

  void _next() {
    final pw = _pwController.text;
    final pwc = _pwConfirmController.text;

    if (!_isIdChecked) { _snack("아이디 중복 확인을 해주세요!"); return; }
    if (!_isPwValid) { _snack("비밀번호는 영문+숫자 8자리 이상이어야 해요!"); return; }
    if (pw != pwc) { _snack("비밀번호가 일치하지 않아요!"); return; }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg, style: const TextStyle(fontSize: 15))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black54),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("회원가입",
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text("계정 정보를 입력해주세요.",
                  style: TextStyle(fontSize: 16, color: Colors.black45)),
              const SizedBox(height: 40),

              _label("아이디"),
              // 아이디 입력 + 중복 확인 버튼
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _idController,
                      onChanged: (_) => setState(() => _isIdChecked = false),
                      style: const TextStyle(fontSize: 17),
                      decoration: InputDecoration(
                        hintText: "영문+숫자 조합 4~20자",
                        hintStyle: const TextStyle(fontSize: 14),
                        filled: true,
                        fillColor: Colors.grey[100],
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                        prefixIcon: const Icon(Icons.person_outline, size: 22),
                        suffixIcon: _idController.text.isNotEmpty
                            ? Icon(
                          _isIdValid ? Icons.check_circle : Icons.cancel,
                          color: _isIdValid ? Colors.green : Colors.redAccent,
                          size: 20,
                        )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 18, horizontal: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 58,
                    child: ElevatedButton(
                      onPressed: _checkDuplicate,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isIdChecked
                            ? Colors.green
                            : Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(
                        _isIdChecked ? "확인완료" : "중복확인",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
              // 아이디 형식 안내
              if (_idController.text.isNotEmpty && !_isIdValid)
                const Padding(
                  padding: EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    "영문과 숫자를 모두 포함해서 4~20자로 입력해주세요",
                    style: TextStyle(fontSize: 12, color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 22),

              _label("비밀번호"),
              _field(
                controller: _pwController,
                hint: "영문+숫자 조합 8자리 이상",
                icon: Icons.lock_outline,
                obscure: _isObscured1,
                suffixIcon: IconButton(
                  icon: Icon(_isObscured1 ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey),
                  onPressed: () => setState(() => _isObscured1 = !_isObscured1),
                ),
              ),
              // 비밀번호 형식 안내
              if (_pwController.text.isNotEmpty && !_isPwValid)
                const Padding(
                  padding: EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    "영문과 숫자를 모두 포함해서 8자리 이상 입력해주세요",
                    style: TextStyle(fontSize: 12, color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 22),

              _label("비밀번호 확인"),
              _field(
                controller: _pwConfirmController,
                hint: "비밀번호를 다시 입력해주세요",
                icon: Icons.lock_outline,
                obscure: _isObscured2,
                suffixIcon: IconButton(
                  icon: Icon(_isObscured2 ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey),
                  onPressed: () => setState(() => _isObscured2 = !_isObscured2),
                ),
              ),
              // 비밀번호 일치 안내
              if (_pwConfirmController.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    _isPwMatch ? "비밀번호가 일치해요 ✅" : "비밀번호가 일치하지 않아요",
                    style: TextStyle(
                      fontSize: 12,
                      color: _isPwMatch ? Colors.green : Colors.redAccent,
                    ),
                  ),
                ),
              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text("다음",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
  );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffixIcon,
  }) =>
      TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontSize: 17),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 15),
          filled: true,
          fillColor: Colors.grey[100],
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
          prefixIcon: Icon(icon, size: 22),
          suffixIcon: suffixIcon,
          contentPadding:
          const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        ),
      );
}

// ──────────────────────────────────────────
// 온보딩 화면 (회원가입 후 최초 1회)
// ──────────────────────────────────────────
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;
  final int _totalSteps = 3;

  // 1단계
  final _nameController = TextEditingController();
  DateTime? _birthDate;

  // 2단계
  final List<Medication> _onboardingMeds = [];

  void _nextStep() {
    if (_currentStep == 0) {
      if (_nameController.text.trim().isEmpty) {
        _snack("이름을 입력해주세요!"); return;
      }
      if (_birthDate == null) {
        _snack("생년월일을 선택해주세요!"); return;
      }
    }
    if (_currentStep < _totalSteps - 1) {
      setState(() => _currentStep++);
      _pageController.nextPage(
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _pageController.previousPage(
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg, style: const TextStyle(fontSize: 15))));
  }

  void _finish() {
    // 온보딩에서 등록한 약 전역 저장
    if (_onboardingMeds.isNotEmpty) {
      globalMedications.value = List.from(_onboardingMeds);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("회원가입이 완료됐어요! 로그인해주세요 😊",
            style: TextStyle(fontSize: 15)),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
    );
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(1960, 1, 1),
      firstDate: DateTime(1920),
      lastDate: now,
      locale: const Locale('ko', 'KR'),
      helpText: "생년월일 선택",
      cancelText: "취소",
      confirmText: "확인",
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Colors.blueAccent),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  String get _birthDateText {
    if (_birthDate == null) return "생년월일을 선택해주세요";
    return "${_birthDate!.year}년 ${_birthDate!.month}월 ${_birthDate!.day}일";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // ── 진행 바 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_currentStep > 0)
                        GestureDetector(
                          onTap: _prevStep,
                          child: const Icon(Icons.arrow_back_ios,
                              size: 20, color: Colors.black54),
                        )
                      else
                        const SizedBox(width: 20),
                      Text("${_currentStep + 1} / $_totalSteps",
                          style: const TextStyle(
                              fontSize: 14, color: Colors.black45)),
                      const SizedBox(width: 20),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: List.generate(_totalSteps, (i) => Expanded(
                      child: Container(
                        height: 5,
                        margin: EdgeInsets.only(right: i < _totalSteps - 1 ? 6 : 0),
                        decoration: BoxDecoration(
                          color: i <= _currentStep
                              ? Colors.blueAccent
                              : Colors.grey[200],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    )),
                  ),
                ],
              ),
            ),

            // ── 페이지 ──
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [_buildStep1(), _buildStep2(), _buildStep3()],
              ),
            ),

            // ── 하단 버튼 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton(
                  onPressed: _currentStep == _totalSteps - 1 ? _finish : _nextStep,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(
                    _currentStep == _totalSteps - 1 ? "시작하기!" : "다음",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 1단계: 이름 & 생년월일 ──
  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("👋", style: TextStyle(fontSize: 48)),
          const SizedBox(height: 16),
          const Text("처음 뵙겠습니다!",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Text("기본 정보를 알려주세요.\n약 복용 관리에 활용돼요.",
              style: TextStyle(fontSize: 15, color: Colors.black54, height: 1.6)),
          const SizedBox(height: 36),

          _fieldLabel("이름"),
          TextField(
            controller: _nameController,
            style: const TextStyle(fontSize: 17),
            decoration: InputDecoration(
              hintText: "예) 홍길동",
              filled: true,
              fillColor: Colors.grey[100],
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              prefixIcon: const Icon(Icons.person_outline, size: 22),
              contentPadding:
              const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            ),
          ),
          const SizedBox(height: 24),

          _fieldLabel("생년월일"),
          GestureDetector(
            onTap: _pickBirthDate,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cake_outlined,
                      size: 22, color: Colors.black45),
                  const SizedBox(width: 14),
                  Text(
                    _birthDateText,
                    style: TextStyle(
                      fontSize: 17,
                      color: _birthDate == null
                          ? Colors.black38
                          : Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.calendar_month_outlined,
                      size: 20, color: Colors.blueAccent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 2단계: 약 등록 ──
  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("💊", style: TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              const Text("복용 중인 약을\n등록해주세요",
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text("지금 드시고 있는 약을 추가해주세요.\n나중에도 추가하거나 수정할 수 있어요.",
                  style: TextStyle(
                      fontSize: 15, color: Colors.black54, height: 1.6)),
              const SizedBox(height: 16),
            ],
          ),
        ),
        Expanded(
          child: _onboardingMeds.isEmpty
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.medication_outlined,
                    size: 52, color: Colors.grey[300]),
                const SizedBox(height: 14),
                const Text("아직 등록된 약이 없어요.\n아래 버튼으로 추가해보세요!",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Colors.grey)),
              ],
            ),
          )
              : ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _onboardingMeds.length,
            itemBuilder: (context, i) {
              final med = _onboardingMeds[i];
              final colors = [
                Colors.orangeAccent, Colors.blueAccent,
                Colors.purpleAccent, Colors.teal, Colors.pinkAccent
              ];
              final color = colors[i % colors.length];
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 8,
                        offset: const Offset(0, 2))
                  ],
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: color.withValues(alpha: 0.15),
                      child: Icon(Icons.medication, color: color, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(med.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          Text(
                              "${med.mealTime} ${med.mealTiming} · ${med.dose}정 · ${med.time}",
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[600])),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          setState(() => _onboardingMeds.removeAt(i)),
                      icon: const Icon(Icons.close,
                          color: Colors.black26, size: 20),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () async {
                final newMed = await Navigator.push<Medication>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AddMedicationScreen()),
                );
                if (newMed != null) {
                  setState(() => _onboardingMeds.add(newMed));
                }
              },
              icon: const Icon(Icons.add, size: 22),
              label: const Text("약 추가하기", style: TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.blueAccent,
                side: const BorderSide(color: Colors.blueAccent, width: 1.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 3단계: 완료 요약 ──
  Widget _buildStep3() {
    final name = _nameController.text.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("🎉", style: TextStyle(fontSize: 48)),
          const SizedBox(height: 16),
          Text("$name 님,\n준비 완료예요!",
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.bold, height: 1.3)),
          const SizedBox(height: 12),
          const Text("이제 알약 매니저를 시작할 수 있어요.\n약은 언제든지 추가하거나 수정할 수 있어요.",
              style: TextStyle(fontSize: 15, color: Colors.black54, height: 1.6)),
          const SizedBox(height: 32),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Colors.blueAccent.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("등록 정보 요약",
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent)),
                const SizedBox(height: 16),
                _summaryRow(Icons.person_outline, "이름", name),
                const SizedBox(height: 10),
                _summaryRow(Icons.cake_outlined, "생년월일", _birthDateText),
                const SizedBox(height: 10),
                _summaryRow(
                  Icons.medication_outlined,
                  "등록된 약",
                  _onboardingMeds.isEmpty
                      ? "없음 (나중에 추가 가능)"
                      : "${_onboardingMeds.length}개",
                ),
                if (_onboardingMeds.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  ..._onboardingMeds.map((m) => Padding(
                    padding: const EdgeInsets.only(left: 32, top: 5),
                    child: Row(
                      children: [
                        const Icon(Icons.circle,
                            size: 6, color: Colors.blueAccent),
                        const SizedBox(width: 8),
                        Text(
                            "${m.name}  ·  ${m.mealTime} ${m.mealTiming}  ·  ${m.time}",
                            style: const TextStyle(
                                fontSize: 14, color: Colors.black54)),
                      ],
                    ),
                  )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
  );

  Widget _summaryRow(IconData icon, String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: Colors.blueAccent),
      const SizedBox(width: 10),
      Text("$label  ",
          style: const TextStyle(fontSize: 14, color: Colors.black45)),
      Expanded(
        child: Text(value,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black87)),
      ),
    ],
  );
}