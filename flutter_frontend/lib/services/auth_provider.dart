import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../models/models.dart' as model;
/// ─────────────────────────────────────────────────────────────────────────
/// SCHEMA ASSUMPTIONS (adjust `_profilesTable` / column names to match yours)
///
///   public.profiles
///     id             uuid  primary key  references auth.users(id)
///     name           text
///     email          text
///     role           text   -- 'Admin' | 'Driver' | 'Passenger'
///     wallet_balance numeric default 0
///
/// Row Level Security should allow a user to select/update their own row
/// (id = auth.uid()), and Admins to select/update all rows.
/// ─────────────────────────────────────────────────────────────────────────
class AuthProvider extends ChangeNotifier {
static const String _profilesTable = 'users';
  final SupabaseClient _supabase = Supabase.instance.client;

  model.User? _currentUser; 
  bool _isLoading = false;
  String? _errorMessage;

  model.User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  AuthProvider() {
    // Keep local state in sync if the session is refreshed/revoked elsewhere
    // (e.g. token refresh failure, or sign-out triggered from another tab).
    _supabase.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedOut && _currentUser != null) {
        debugPrint('[RBAC][authStateChange] Session ended externally — clearing local user.');
        _currentUser = null;
        notifyListeners();
      }
    });
  }

  // ── Restore session from Supabase's persisted session on app launch ───────
  Future<bool> checkLoginStatus() async {
    _isLoading = true;
    notifyListeners();

    try {
      final session = _supabase.auth.currentSession;
      debugPrint('[RBAC][checkLoginStatus] session=${session != null ? "present" : "absent"}');

      if (session == null) {
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final profile = await _fetchProfile(session.user.id);
      if (profile == null) {
        debugPrint('[RBAC][checkLoginStatus] No profile row for session user — clearing stale session.');
        await _clearSession();
        _isLoading = false;
        notifyListeners();
        return false;
      }

      _currentUser = profile;
      debugPrint('[RBAC][checkLoginStatus] Restored → id=${_currentUser!.id} '
          'role=${_currentUser!.role} email=${_currentUser!.email}');

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[RBAC][checkLoginStatus] ERROR: $e — clearing stale session.');
      await _clearSession();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // ── Passenger self-registration (only role allowed via the app) ────────────
  // Admin and Driver accounts must be created via seed data or the Admin panel
  // (see ApiService.hireDriver, which uses an Edge Function with elevated
  // privileges since the client key cannot create other users' accounts).
  Future<bool> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    debugPrint('[RBAC][signUp] Registering Passenger: email=$email');

    try {
      final authRes = await _supabase.auth.signUp(
        email: email.trim(),
        password: password,
        data: {'name': name},
      );

      final newUser = authRes.user;
      if (newUser == null) {
        _isLoading = false;
        _errorMessage = 'Registration failed.';
        notifyListeners();
        return false;
      }

      // role is NOT taken from client input — always 'Passenger' for self-registration
    await _supabase.from(_profilesTable).insert({
  'name': name,
  'email': email.trim(),
  'password': '',
  'role_id': 3,
  'wallet_balance': 0,
});

      debugPrint('[RBAC][signUp] Registration successful.');
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _isLoading = false;
      _errorMessage = e.message;
      debugPrint('[RBAC][signUp] AUTH FAILED: ${e.message}');
      notifyListeners();
      return false;
   } catch (e, stackTrace) {
  _isLoading = false;

  debugPrint("========== SIGNUP ERROR ==========");
  debugPrint(e.toString());
  debugPrintStack(stackTrace: stackTrace);

  _errorMessage = e.toString();

  notifyListeners();
  return false;
}
  }

  // ── Login — works for Admin, Driver, and Passenger ────────────────────────
  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    debugPrint('[RBAC][login] Attempting login for email=$email');

    try {
      final authRes = await _supabase.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );

      final authUser = authRes.user;
      if (authUser == null) {
        _isLoading = false;
        _errorMessage = 'Invalid email or password.';
        notifyListeners();
        return false;
      }

      final profile = await _fetchProfile(authUser.id);
      if (profile == null) {
        debugPrint('[RBAC][login] No profile row found for authenticated user.');
        await _supabase.auth.signOut();
        _isLoading = false;
        _errorMessage = 'Account is not fully set up. Contact an administrator.';
        notifyListeners();
        return false;
      }

      _currentUser = profile;
      debugPrint('[RBAC][login] _currentUser.role="${_currentUser!.role}" '
          '→ will navigate to ${_currentUser!.role} dashboard');

      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
  _isLoading = false;

  debugPrint('================ AUTH ERROR ================');
  debugPrint(e.message);

  _errorMessage = e.message;

  notifyListeners();
  return false;

} catch (e, stackTrace) {
  _isLoading = false;

  debugPrint('================ LOGIN ERROR ================');
  debugPrint('ERROR: $e');
  debugPrintStack(stackTrace: stackTrace);

  _errorMessage = e.toString();

  notifyListeners();
  return false;

    }
  }

  // ── Update wallet balance locally after a payment ─────────────────────────
  void updateLocalBalance(double newBalance) {
    if (_currentUser != null) {
      _currentUser = _currentUser!.copyWith(walletBalance: newBalance);
      notifyListeners();

      // Fire-and-forget persistence to keep this method's signature/behavior
      // (synchronous, non-blocking) identical to the previous implementation.
      _supabase
          .from(_profilesTable)
          .update({'wallet_balance': newBalance})
          .eq('id', _currentUser!.id)
          .catchError((e) {
        debugPrint('[RBAC][updateLocalBalance] ERROR persisting balance: $e');
        return <String, dynamic>{};
      });
    }
  }

  // ── Forgot password — sends reset request via Supabase Auth ───────────────
  Future<Map<String, dynamic>> requestPasswordReset(String email) async {
  try {
    await _supabase.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: 'smarttransit://reset-password',
    );

    debugPrint('[Auth][forgotPassword] Reset email requested for $email');

    return {
      'status': 'success',
      'message': 'If this email is registered, a reset link has been sent.',
    };
  } catch (e) {
    debugPrint('[Auth][forgotPassword] ERROR: $e');

    return {
      'status': 'error',
      'message': 'Unable to send reset email. Please try again.',
    };
  }
}

  // ── Logout ────────────────────────────────────────────────────────────────
  Future<void> logout() async {
    debugPrint('[RBAC][logout] Logging out: email=${_currentUser?.email} role=${_currentUser?.role}');
    await _clearSession();
    _currentUser = null;
    _errorMessage = null;
    notifyListeners();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────
Future<model.User?> _fetchProfile(String userId) async {
  final email = _supabase.auth.currentUser?.email;

  if (email == null) {
    debugPrint("No email found");
    return null;
  }

  debugPrint("Searching for email: $email");

  final data = await _supabase
      .from('users')
      .select()
      .eq('email', email)
      .maybeSingle();

  debugPrint("Database returned: $data");

  if (data == null) {
    debugPrint("No user found in users table.");
    return null;
  }

  return model.User.fromJson(data);
}

  Future<void> _clearSession() async {
    try {
      await _supabase.auth.signOut();
    } catch (e) {
      debugPrint('[RBAC][_clearSession] ERROR: $e');
    }
  }
}
