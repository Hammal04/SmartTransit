import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'services/auth_provider.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/driver_dashboard.dart';
import 'screens/passenger_dashboard.dart';

const String supabaseUrl = 'https://flcyfvmbgamfhukpcdjw.supabase.co';
const String supabaseAnonKey = 'sb_publishable_rzqsgp0ShsuOYWF4PejK5Q_OGf-ZC6u';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const SmartTransitApp());
}

class SmartTransitApp extends StatelessWidget {
  const SmartTransitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider()..checkLoginStatus(),
        ),
      ],
      child: MaterialApp(
        title: 'SmartTransit System',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
          ),
          fontFamily: 'Inter',
        ),
        home: const LoginScreen(),
        routes: {
          '/login': (context) => const LoginScreen(),
          '/signup': (context) => const SignupScreen(),
          '/admin': (context) => const AdminDashboard(),
          '/driver': (context) => const DriverDashboard(),
          '/passenger': (context) => const PassengerDashboard(),
        },
      ),
    );
  }
}