import 'dart:convert';
import 'dart:io';

import 'package:googleapis/calendar/v3.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class GoogleOAuthStore {
  static const scopes = [CalendarApi.calendarEventsScope];

  static Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _clientFile() async {
    return File(p.join((await _dir()).path, 'google_oauth_client'));
  }

  static Future<File> _tokenFile() async {
    return File(p.join((await _dir()).path, 'google_oauth_tokens.json'));
  }

  static Future<({String id, String secret})> readClient() async {
    try {
      final f = await _clientFile();
      if (!await f.exists()) {
        return (id: '', secret: '');
      }
      final lines = (await f.readAsString()).split('\n');
      return (
        id: lines.isEmpty ? '' : lines[0].trim(),
        secret: lines.length < 2 ? '' : lines[1].trim(),
      );
    } catch (_) {
      return (id: '', secret: '');
    }
  }

  static Future<void> writeClient({
    required String id,
    required String secret,
  }) async {
    final f = await _clientFile();
    await f.writeAsString('${id.trim()}\n${secret.trim()}\n', flush: true);
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }

  static Future<bool> isSignedIn() async {
    try {
      final f = await _tokenFile();
      if (!await f.exists()) {
        return false;
      }
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (json['refreshToken'] as String?)?.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> signOut() async {
    final f = await _tokenFile();
    if (await f.exists()) {
      await f.delete();
    }
  }

  static Future<AccessCredentials?> _readCreds() async {
    final f = await _tokenFile();
    if (!await f.exists()) {
      return null;
    }
    final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final token = json['accessToken'];
    if (token is! Map<String, dynamic>) {
      return null;
    }
    return AccessCredentials.fromJson({
      ...json,
      'accessToken': token,
    });
  }

  static Future<void> _writeCreds(AccessCredentials creds) async {
    final f = await _tokenFile();
    await f.writeAsString(
      jsonEncode({
        'accessToken': creds.accessToken.toJson(),
        'refreshToken': creds.refreshToken,
        'idToken': creds.idToken,
        'scopes': creds.scopes,
      }),
      flush: true,
    );
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }

  static Future<ClientId> _clientId() async {
    final c = await readClient();
    if (c.id.isEmpty || c.secret.isEmpty) {
      throw Exception(
        'Add a Google Desktop OAuth client ID and secret in Settings.',
      );
    }
    return ClientId(c.id, c.secret);
  }

  static Future<void> signIn() async {
    final id = await _clientId();
    final client = http.Client();
    try {
      final creds = await obtainAccessCredentialsViaUserConsent(
        id,
        scopes,
        client,
        (url) {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        },
      );
      if (creds.refreshToken == null || creds.refreshToken!.isEmpty) {
        throw Exception(
          'Google did not return a refresh token. Remove OpenPendant from '
          'https://myaccount.google.com/permissions and sign in again.',
        );
      }
      await _writeCreds(creds);
    } finally {
      client.close();
    }
  }

  static Future<AutoRefreshingAuthClient> authorizedClient() async {
    final id = await _clientId();
    final stored = await _readCreds();
    final refresh = stored?.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw Exception('Sign in with Google in Settings first.');
    }
    return clientViaRefreshToken(id, refresh, scopes);
  }
}
